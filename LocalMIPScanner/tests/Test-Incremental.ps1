#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Value {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -ne $Actual) { throw "$Message expected [$Expected] got [$Actual]" }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("LocalMIPScanner-M2-" + [guid]::NewGuid().ToString('N'))
$root = Join-Path $fixture 'Root'
$config = Join-Path $fixture 'Config'
$state = Join-Path $root 'State'
$logs = Join-Path $root 'Logs'
$scanner = Join-Path $PSScriptRoot '../Invoke-LocalMIPScanner.ps1'
try {
    [void][IO.Directory]::CreateDirectory($root)
    [void][IO.Directory]::CreateDirectory($config)
    Set-Content -LiteralPath (Join-Path $config 'extensions.json') -Value '[".txt"]'
    Set-Content -LiteralPath (Join-Path $config 'exclusions.json') -Value '[]'
    Set-Content -LiteralPath (Join-Path $config 'performance.json') -Value '{"batchSize":100,"pauseMilliseconds":0}'
    $settings = @{
        enabled = $true
        rescanIntervalDays = 30
        detectModifiedFiles = $true
        detectDeletedFiles = $true
        forceFullScan = $false
        maxFileSizeMB = 1
        stateDirectory = $state
    }
    $settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $config 'incremental.json')
    Set-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'alpha'
    Set-Content -LiteralPath (Join-Path $root 'b.txt') -Value 'beta'
    $params = @{ Root=$root; ConfigDirectory=$config; LogDirectory=$logs }
    $first = & $scanner @params
    Assert-Value 2 $first.newFiles 'First run new'
    Assert-Value 0 $first.errors 'First run errors'
    Assert-Value 2 $first.pendingClassification 'First run pending'
    $second = & $scanner @params
    Assert-Value 0 $second.newFiles 'Second run new'
    Assert-Value 2 $second.unchangedFiles 'Second run unchanged'
    Assert-Value 0 $second.deletedFiles 'Second run deleted'
    Add-Content -LiteralPath (Join-Path $root 'a.txt') -Value 'updated'
    Set-Content -LiteralPath (Join-Path $root 'c.txt') -Value 'charlie'
    [IO.File]::Delete((Join-Path $root 'b.txt'))
    $third = & $scanner @params
    Assert-Value 1 $third.newFiles 'Third run new'
    Assert-Value 1 $third.modifiedFiles 'Third run modified'
    Assert-Value 1 $third.deletedFiles 'Third run deleted'
    Assert-Value 0 $third.errors 'Third run errors'
    $stateLines = @([IO.File]::ReadAllLines((Join-Path $state 'inventory-state.jsonl')) | Where-Object { $_ })
    Assert-Value 2 $stateLines.Count 'Final state entries'
    $records = @($stateLines | ConvertFrom-Json)
    Assert-Value 0 @($records | Where-Object { $_.lastContentScannedUtc }).Count 'No false content scan timestamp'
    $lastEvents = @(Get-Content -LiteralPath $third.logFile | ConvertFrom-Json)
    Assert-Value 1 @($lastEvents | Where-Object event -eq 'deleted').Count 'Deleted events'
    Assert-Value 'summary' $lastEvents[-1].event 'Final summary event'
    'PASS: M2 first, repeat, changed, added, deleted, state integrity and JSONL summary'
} finally {
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
