#Requires -Version 7.2
param([ValidateRange(100, 100000)] [int] $FileCount = 3000)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fixture = Join-Path ([IO.Path]::GetTempPath()) "LocalMIPScanner-measure-$([guid]::NewGuid().ToString('N'))"
$root = Join-Path $fixture 'root'
$config = Join-Path $fixture 'config'
$state = Join-Path $fixture 'state'
$logs = Join-Path $fixture 'logs'
$scanner = Join-Path $PSScriptRoot '../Invoke-LocalMIPScanner.ps1'
try {
    [void][IO.Directory]::CreateDirectory($config)
    foreach ($name in 'extensions', 'performance') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../Config/$name.json") -Destination $config
    }
    Set-Content -LiteralPath "$config\exclusions.json" -Value '[]'
    for ($i = 0; $i -lt $FileCount; $i++) {
        $directory = Join-Path $root ("dir-" + [int][Math]::Floor($i / 100))
        [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory "sample-$i.txt"), 'synthetic sample')
    }
    $settings = @{
        enabled = $false; rescanIntervalDays = 30; detectModifiedFiles = $true
        detectDeletedFiles = $true; forceFullScan = $false; maxFileSizeMB = 1
        stateDirectory = $state
    }
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        foreach ($mode in 'M1', 'M2.1 inicial', 'M2.1 sin cambios') {
            $settings.enabled = $mode -ne 'M1'
            $settings | ConvertTo-Json | Set-Content -LiteralPath "$config\incremental.json"
            $process.Refresh()
            $cpuStart = $process.TotalProcessorTime
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $result = & $scanner -Root $root -ConfigDirectory $config -LogDirectory $logs
            $timer.Stop()
            $process.Refresh()
            $expectedUnchanged = if ($mode -eq 'M2.1 sin cambios') { $FileCount } else { 0 }
            if ($result.inventoried -ne $FileCount -or $result.errors -ne 0 -or
                $result.unchangedFiles -ne $expectedUnchanged) { throw "Unexpected inventory for $mode." }
            $stateBytes = 0
            if ([IO.Directory]::Exists($state)) {
                $stateBytes = (Get-ChildItem -LiteralPath $state -File | Measure-Object -Property Length -Sum).Sum
            }
            [pscustomobject]@{
                Mode = $mode; Files = $FileCount; WallMs = $timer.ElapsedMilliseconds
                CpuMs = [Math]::Round(($process.TotalProcessorTime - $cpuStart).TotalMilliseconds)
                ProcessPeakMiB = [Math]::Round($process.PeakWorkingSet64 / 1MB, 1)
                StateLoadMs = $result.stateLoadMilliseconds; StateSaveMs = $result.stateSaveMilliseconds
                LogBytes = (Get-Item -LiteralPath $result.logFile).Length; StateBytes = $stateBytes
            }
        }
    } finally { $process.Dispose() }
} finally {
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
