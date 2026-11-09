#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-LiveText {
    param([string] $Path)
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $reader = [IO.StreamReader]::new($stream)
        try { $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "LocalMIPScanner-restart-$([guid]::NewGuid().ToString('N'))"
$root = Join-Path $fixture 'root'
$nested = Join-Path $root 'wide'
$logs = Join-Path $fixture 'logs'
$config = Join-Path $fixture 'config'
$state = Join-Path $fixture 'state'
$scanner = Join-Path $PSScriptRoot '../Invoke-LocalMIPScanner.ps1'
$process = $null
try {
    foreach ($path in $nested, $config) { [void][IO.Directory]::CreateDirectory($path) }
    Set-Content -LiteralPath "$config\extensions.json" -Value '[".txt"]'
    Set-Content -LiteralPath "$config\exclusions.json" -Value '[]'
    Set-Content -LiteralPath "$config\performance.json" -Value '{"batchSize":1,"pauseMilliseconds":250}'
    @{
        enabled = $true; rescanIntervalDays = 30; detectModifiedFiles = $true
        detectDeletedFiles = $true; forceFullScan = $false; maxFileSizeMB = 1
        stateDirectory = $state
    } | ConvertTo-Json | Set-Content -LiteralPath "$config\incremental.json"
    Set-Content -LiteralPath "$root\committed.txt" -Value 'sample'
    foreach ($i in 1..100) { Set-Content -LiteralPath "$nested\part-$i.txt" -Value 'sample' }

    $params = @{ Root = $root; ConfigDirectory = $config; LogDirectory = $logs }
    $quote = { param($Value) "'" + $Value.Replace("'", "''") + "'" }
    $command = '& {0} -Root {1} -ConfigDirectory {2} -LogDirectory {3} -Continuous -MaxSeconds 1 -IdleSeconds 1' -f
        (& $quote $scanner), (& $quote $root), (& $quote $config), (& $quote $logs)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start = @{
        FilePath = Join-Path $PSHOME 'pwsh.exe'
        ArgumentList = '-NoProfile', '-EncodedCommand', $encoded
        WindowStyle = 'Hidden'
        RedirectStandardError = "$fixture\stderr.txt"
        PassThru = $true
    }
    $process = Start-Process @start

    # Wait for audit events from the second directory after the first checkpoint.
    # The wide directory takes more than 20 seconds.
    $observed = $false
    $deadline = [datetime]::UtcNow.AddSeconds(45)
    while (-not $process.HasExited -and [datetime]::UtcNow -lt $deadline) {
        if ([IO.Directory]::Exists($logs)) {
            foreach ($file in [IO.Directory]::EnumerateFiles($logs, '*.jsonl')) {
                if ((Read-LiveText $file).Contains('part-')) { $observed = $true; break }
            }
        }
        if ($observed) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $observed) { throw "Scanner never reached the second directory. $(Get-Content -LiteralPath "$fixture\stderr.txt" -Raw)" }
    $process.Kill()
    if (-not $process.WaitForExit(10000)) { throw 'Scanner did not terminate.' }

    $journal = Join-Path $state 'inventory.active.jsonl'
    $checkpoints = @([IO.File]::ReadLines($journal) | Where-Object { $_ -match '"kind":"checkpoint"' })
    if ($checkpoints.Count -ne 1) { throw "Expected one durable checkpoint, got $($checkpoints.Count)." }
    Set-Content -LiteralPath "$config\performance.json" -Value '{"batchSize":100,"pauseMilliseconds":0}'
    $result = & $scanner @params
    if ($result.resumedDirectories -ne 1 -or $result.directoriesCompleted -ne 1 -or
        $result.newFiles -ne 100 -or -not $result.generationComplete) {
        throw "Unexpected restart result: $($result | ConvertTo-Json -Compress)"
    }
    $next = & $scanner @params
    if ($next.unchangedFiles -ne 101) { throw 'Restart did not consolidate all 101 files.' }
    'PASS: terminated a separate scanner process mid-directory and resumed from its durable checkpoint'
} finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
