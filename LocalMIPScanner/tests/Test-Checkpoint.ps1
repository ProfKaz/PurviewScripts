#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -cne $Actual) { throw "$Message expected [$Expected], received [$Actual]." }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    try { $null = & $Action } catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching $Pattern."
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "LocalMIPScanner-M21-$([guid]::NewGuid().ToString('N'))"
$root = Join-Path $fixture 'root'
$config = Join-Path $fixture 'config'
$logs = Join-Path $fixture 'logs'
$state = Join-Path $fixture 'state'
$index = Join-Path $state 'inventory.index.jsonl'
$backup = Join-Path $state 'inventory.index.backup'
$journal = Join-Path $state 'inventory.active.jsonl'
$scanner = Join-Path $PSScriptRoot '../Invoke-LocalMIPScanner.ps1'
$params = @{ Root = $root; ConfigDirectory = $config; LogDirectory = $logs }
try {
    $child = Join-Path $root 'nested'
    foreach ($path in $child, $config, $state) { [void][IO.Directory]::CreateDirectory($path) }
    Set-Content -LiteralPath "$config\extensions.json" -Value '[".txt"]'
    Set-Content -LiteralPath "$config\exclusions.json" -Value '[]'
    Set-Content -LiteralPath "$config\performance.json" -Value '{"batchSize":100,"pauseMilliseconds":0}'
    @{
        enabled = $true; rescanIntervalDays = 30; detectModifiedFiles = $true
        detectDeletedFiles = $true; forceFullScan = $false; maxFileSizeMB = 1
        stateDirectory = $state
    } | ConvertTo-Json | Set-Content -LiteralPath "$config\incremental.json"
    $old = "$root\legacy.txt"
    Set-Content -LiteralPath $old -Value 'legacy'
    Set-Content -LiteralPath "$child\child.txt" -Value 'child'
    $file = Get-Item -LiteralPath $old
    $legacy = Join-Path $state 'inventory-state.jsonl'
    @{
        schemaVersion = 1; path = $old; sizeBytes = $file.Length
        lastWriteUtc = $file.LastWriteTimeUtc.ToString('o'); lastDiscoveredUtc = [datetime]::UtcNow.ToString('o')
        lastContentScannedUtc = $null; status = 'PendingClassification'
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $legacy
    $legacyHash = (Get-FileHash -LiteralPath $legacy).Hash
    $documentHash = (Get-FileHash -LiteralPath $old).Hash

    $partial = & $scanner @params -MaxDirectories 1
    Assert-Equal 1 $partial.unchangedFiles 'Migrated M2 timestamp and length'
    Assert-Equal $false $partial.generationComplete 'First slice is incomplete'
    $baselineHash = (Get-FileHash -LiteralPath $index).Hash
    $checkpointed = [IO.File]::ReadAllText($journal)
    Assert-Throws { & $scanner @params -Root $child } '*journal scope changed*'
    Assert-Equal $checkpointed ([IO.File]::ReadAllText($journal)) 'Scope mismatch leaves journal intact'

    $locked = [IO.File]::Open("$state\inventory.lock", 'Open', 'ReadWrite', 'None')
    try {
        Assert-Throws { & $scanner @params } '*inventory.lock*'
    } finally { $locked.Dispose() }

    # A syntactically valid modification of a checkpoint must still be rejected.
    $altered = $checkpointed.Replace('"failed":false', '"failed":true')
    [IO.File]::WriteAllText($journal, $altered)
    Assert-Throws { & $scanner @params } '*checkpoint checksum*'
    Assert-Equal $baselineHash (Get-FileHash -LiteralPath $index).Hash 'Journal corruption leaves primary intact'
    [IO.File]::WriteAllText($journal, $checkpointed)

    # Simulate an abandoned directory with a complete observation and a torn final record.
    $phantom = "$child\phantom.txt"
    $begin = @{ kind = 'begin'; path = $child } | ConvertTo-Json -Compress
    $observation = @{
        kind = 'seen'; path = $phantom; item = @{
            schemaVersion = 1; path = $phantom; sizeBytes = 0
            lastWriteUtc = $file.LastWriteTimeUtc.ToString('o'); lastDiscoveredUtc = [datetime]::UtcNow.ToString('o')
            lastContentScannedUtc = $null; status = 'PendingClassification'
        }
    } | ConvertTo-Json -Depth 4 -Compress
    [IO.File]::AppendAllText($journal, "$begin" + [char]10 + "$observation" + [char]10 + '{"kind":"checkp')

    # Hold the primary without delete sharing. The new snapshot and backup are prepared,
    # but the final rename fails after the journal end was durably written.
    $locked = [IO.File]::Open($index, 'Open', 'Read', 'Read')
    try {
        Assert-Throws { & $scanner @params } '*Move*'
    } finally { $locked.Dispose() }
    $sealed = [IO.File]::ReadAllText($journal)
    $last = @($sealed.TrimEnd().Split([char]10) | ConvertFrom-Json)[-1]
    Assert-Equal 'end' $last.kind 'End survives failed publication'
    Assert-Equal $baselineHash (Get-FileHash -LiteralPath $index).Hash 'Failed rename preserves primary'
    Assert-Equal $baselineHash (Get-FileHash -LiteralPath $backup).Hash 'Backup prepared before final rename'

    $consolidated = & $scanner @params
    Assert-Equal 0 $consolidated.directoriesCompleted 'Sealed journal replay skips enumeration'
    Assert-Equal 2 $consolidated.resumedDirectories 'Replayed both checkpoints'
    Assert-Equal $partial.generation $consolidated.generation 'Resume uses original generation'
    Assert-Equal $true $consolidated.generationComplete 'Retry consolidated'
    Assert-Equal $false ([IO.File]::Exists($journal)) 'Retired journal'
    Assert-Equal $false ([IO.File]::ReadAllText($index).Contains('phantom.txt')) 'Abandoned observation discarded'
    Assert-Equal $baselineHash (Get-FileHash -LiteralPath $backup).Hash 'Exactly the prior snapshot was kept'
    $publishedHash = (Get-FileHash -LiteralPath $index).Hash

    # Simulate termination after publishing the index and before deleting the sealed journal.
    [IO.File]::WriteAllText($journal, $sealed)
    $next = & $scanner @params
    Assert-Equal 2 $next.unchangedFiles 'Published generation not replayed'
    Assert-Equal $false ($next.generation -eq $partial.generation) 'Started a fresh generation'
    Assert-Equal $publishedHash (Get-FileHash -LiteralPath $backup).Hash 'Backup advanced exactly one generation'
    Assert-Equal 1 @(Get-ChildItem -LiteralPath $state -Filter '*.backup').Count 'Only one backup'

    $candidate = [IO.File]::ReadAllText($index)
    [IO.File]::WriteAllText($index, $candidate.Replace('legacy.txt', 'broken.txt'))
    $recovered = & $scanner @params -MaxDirectories 1
    Assert-Equal $true $recovered.recoveredIndex 'Recovered checksum-corrupt primary'
    Assert-Equal $publishedHash (Get-FileHash -LiteralPath $index).Hash 'Restored validated backup'
    Assert-Equal $publishedHash (Get-FileHash -LiteralPath $backup).Hash 'Recovery leaves backup untouched'
    $null = & $scanner @params

    # A read failure after a checkpoint must suppress deletions across invocations.
    $null = & $scanner @params -MaxDirectories 1
    [IO.File]::Delete("$child\child.txt")
    [IO.Directory]::Delete($child)
    $failed = & $scanner @params
    Assert-Equal $true $failed.generationHasErrors 'Disappeared pending directory recorded'
    Assert-Equal 0 $failed.deletedFiles 'Partial traversal suppresses deletion'
    $clean = & $scanner @params
    Assert-Equal 1 $clean.deletedFiles 'Clean generation confirms deletion'
    Assert-Equal $legacyHash (Get-FileHash -LiteralPath $legacy).Hash 'Legacy index kept byte for byte'
    Assert-Equal $documentHash (Get-FileHash -LiteralPath $old).Hash 'Source content unchanged'
    Assert-Equal $file.LastWriteTimeUtc (Get-Item -LiteralPath $old).LastWriteTimeUtc 'Source mtime unchanged'

    [IO.File]::WriteAllText($index, '{}')
    [IO.File]::WriteAllText($backup, '{}')
    Assert-Throws { & $scanner @params } '*Invalid index header*'
    Assert-Equal '{}' ([IO.File]::ReadAllText($backup)) 'Invalid copies are not overwritten'
    'PASS: migration, limits, scope, lock, torn and corrupt journal, sealed replay, backup, recovery and deletion'
} finally {
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
