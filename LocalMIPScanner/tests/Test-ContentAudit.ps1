#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -cne $Actual) { throw "$Message expected [$Expected], received [$Actual]." }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "LocalMIPScanner-content-$([guid]::NewGuid().ToString('N'))"
$root = Join-Path $fixture 'root'
$child = Join-Path $root 'nested'
$config = Join-Path $fixture 'config'
$scanner = Join-Path $PSScriptRoot '../Invoke-LocalMIPScanner.ps1'
$settings = @{
    enabled = $true; rescanIntervalDays = 30; detectModifiedFiles = $true; detectDeletedFiles = $true
    forceFullScan = $false; maxFileSizeMB = 1; stateDirectory = Join-Path $fixture 'state'
}
$params = @{ Root = $root; ConfigDirectory = $config; LogDirectory = Join-Path $fixture 'logs' }
try {
    foreach ($directory in $child, $config) { [void][IO.Directory]::CreateDirectory($directory) }
    Set-Content -LiteralPath "$config\extensions.json" -Value '[".txt",".csv",".pdf"]'
    Set-Content -LiteralPath "$config\exclusions.json" -Value '[]'
    Set-Content -LiteralPath "$config\performance.json" -Value '{"batchSize":100,"pauseMilliseconds":0}'
    $settings | ConvertTo-Json | Set-Content -LiteralPath "$config\incremental.json"
    $rules = @{
        maxBytes = 128
        rules = @(@{ id = 'test-marker'; pattern = '\bPILOT-[0-9]{6}\b' })
    }
    $rules | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$config\classifiers.json"
    Set-Content -LiteralPath "$root\positive.txt" -Value 'PILOT-123456 PILOT-123456' -Encoding utf8BOM
    Set-Content -LiteralPath "$root\negative.txt" -Value 'PILOT-12345 and PILOT-1234567'
    Set-Content -LiteralPath "$child\positive.csv" -Value ('id,comment' + [Environment]::NewLine + 'PILOT-654321,synthetic')
    Set-Content -LiteralPath "$child\negative.csv" -Value 'id,comment'
    Set-Content -LiteralPath "$child\unsupported.pdf" -Value 'PILOT-123456'
    Set-Content -LiteralPath "$child\oversized.txt" -Value ('PILOT-123456 ' * 12)
    [IO.File]::WriteAllBytes("$child\invalid.txt", [byte[]]@(255, 255))
    $source = Get-Item -LiteralPath "$root\positive.txt"
    $hash = (Get-FileHash -LiteralPath $source.FullName).Hash

    $inventory = & $scanner @params
    Assert-Equal 7 $inventory.inventoried 'Metadata inventory remains available'
    Assert-Equal 0 @(Get-Content -LiteralPath $inventory.logFile | ConvertFrom-Json |
        Where-Object event -eq 'contentAudit').Count 'Metadata mode emits no content audit events'

    $first = & $scanner @params -AuditContent -MaxDirectories 1
    Assert-Equal $false $first.generationComplete 'First segment incomplete'
    Assert-Equal 2 $first.contentAudited 'First segment text files'
    Assert-Equal 1 $first.contentAuditFilesWithMatches 'One positive TXT'
    $second = & $scanner @params -AuditContent
    Assert-Equal $true $second.generationComplete 'Audited state published'
    Assert-Equal $first.generation $second.generation 'Same generation'
    Assert-Equal 1 $second.resumedDirectories 'Confirmed text files not reopened'
    Assert-Equal 2 $second.contentAudited 'CSV audit completed'
    Assert-Equal 1 $second.contentAuditFilesWithMatches 'One positive CSV'
    Assert-Equal 2 $second.contentAuditSkipped 'Unsupported and oversized files'
    Assert-Equal 1 $second.contentAuditErrors 'Malformed UTF-8'
    Assert-Equal 0 $second.errors 'Content error does not report a traversal error'
    foreach ($run in $first, $second) {
        $log = Get-Content -LiteralPath $run.logFile -Raw
        if ($log.Contains('PILOT-123456') -or $log.Contains('PILOT-654321')) { throw 'Content was written to the log.' }
        $hits = @($log -split '\r?\n' | Where-Object { $_ } | ConvertFrom-Json -AsHashtable |
            Where-Object { $_.event -eq 'contentAudit' -and $_.outcome -eq 'completed' -and $_.matchesByRule.ContainsKey('test-marker') })
        Assert-Equal 1 $hits.Count 'One matching file per format'
        $expected = if ($run -eq $first) { 2 } else { 1 }
        Assert-Equal $expected $hits[0].matchesByRule.'test-marker' 'Only match counts recorded'
        Assert-Equal (Get-FileHash -LiteralPath $hits[0].path).Hash $hits[0].sha256 'Audit fingerprint binds findings to source bytes'
    }

    $repeat = & $scanner @params -AuditContent
    Assert-Equal 4 $repeat.contentAuditReused 'Positive and negative results reused'
    Assert-Equal 0 $repeat.contentAudited 'No successful file reopened'
    Assert-Equal 1 $repeat.contentAuditErrors 'Invalid file retried'

    Add-Content -LiteralPath "$child\positive.csv" -Value 'updated'
    $changed = & $scanner @params -AuditContent
    Assert-Equal 1 $changed.contentAudited 'Modified file audited'
    Assert-Equal 3 $changed.contentAuditReused 'Unchanged audit stamps reused'

    $rules.rules[0].pattern = '\bDIFFERENT-[0-9]{6}\b'
    $rules | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$config\classifiers.json"
    $ruleChange = & $scanner @params -AuditContent
    Assert-Equal 4 $ruleChange.contentAudited 'Changed rules invalidate stamps'
    Assert-Equal 0 $ruleChange.contentAuditFilesWithMatches 'Updated rule has no matches'
    Assert-Equal $hash (Get-FileHash -LiteralPath $source.FullName).Hash 'Source hash unchanged'
    Assert-Equal $source.LastWriteTimeUtc (Get-Item -LiteralPath $source.FullName).LastWriteTimeUtc 'Source mtime unchanged'
    $index = Get-Content -LiteralPath (Join-Path $settings.stateDirectory 'inventory.index.jsonl') -Raw
    if ($index.Contains('PILOT-123456') -or $index.Contains('PILOT-654321')) { throw 'Content was written to the index.' }

    $rules.maxBytes = 2048
    $rules.rules[0].pattern = '(a+)+$'
    $rules | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$config\classifiers.json"
    Set-Content -LiteralPath "$child\timeout.txt" -Value (('a' * 1000) + '!')
    $timeout = & $scanner @params -AuditContent
    $timeoutEvents = @(Get-Content -LiteralPath $timeout.logFile | ConvertFrom-Json -AsHashtable |
        Where-Object { $_['event'] -eq 'contentAudit' -and $_['reason'] -eq 'ruleTimeout' })
    Assert-Equal 1 $timeoutEvents.Count 'Regex timeout isolated to one file'
    Assert-Equal $true $timeout.generationComplete 'Timeout leaves generation publishable'
    'PASS: opt-in content audit, TXT/CSV findings, checkpoint, reuse, retry, change detection and source integrity'
} finally {
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
