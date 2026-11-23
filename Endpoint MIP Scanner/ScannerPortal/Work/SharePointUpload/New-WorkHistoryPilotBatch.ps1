<#PSScriptInfo
.VERSION 0.1.0
.GUID 3772dfe7-279e-497e-a6ba-91288b2822ef
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.0 Create a distinct synthetic sealed batch for the report history pilot.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][string]$ReportingModulePath,
    [string]$PilotDirectory = (Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner\Work\HistoryPilot')
)
$ErrorActionPreference = 'Stop'
if ($TenantId -eq [guid]::Empty) { throw 'A nonempty tenant GUID is required.' }
Import-Module -Name (Get-Item -LiteralPath $ReportingModulePath).FullName -Force

$runDirectory = Join-Path $PilotDirectory ('fixture-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($runDirectory)
$utf8 = [Text.UTF8Encoding]::new($false)
$discoveryPath = Join-Path $runDirectory 'discovery.jsonl'
$retryPath = Join-Path $runDirectory 'retry.json'
$inventoryPath = Join-Path $runDirectory 'inventory.jsonl'

$rows = @(
    @{ Path = 'C:\ScannerHistorySynthetic\fixture.csv'; Result = 'Responded'; Findings = @(
        @{ SitId = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'; Name = 'Credit Card Number'; Count = 3; Confidence = 85 }
    ) }
    @{ Path = 'C:\ScannerHistorySynthetic\fixture.docx'; Result = 'Responded'; Findings = @() }
    @{ Path = 'C:\ScannerHistorySynthetic\fixture.txt'; Result = 'NoResponse'; Findings = @() }
)
$discovery = @(foreach ($row in $rows) {
    $row.Extension = [IO.Path]::GetExtension($row.Path)
    $row.ClientVersion = '3.2.92.0'
    $row.StartedUtc = '2026-11-23T12:00:00Z'
    $row.NativeStatus = @(if ($row.Result -eq 'Responded') { 'Skipped' })
    ConvertTo-Json -InputObject $row -Depth 8 -Compress
})
[IO.File]::WriteAllLines($discoveryPath, [string[]]$discovery, $utf8)
[IO.File]::WriteAllText($retryPath, '{"ReintentosCSV":[]}', $utf8)
$inventory = @(foreach ($row in $rows) {
    @{ event = 'file'; path = $row.Path } | ConvertTo-Json -Compress
})
$inventory += (@{ event = 'summary'; generationComplete = $true; errors = 0 } | ConvertTo-Json -Compress)
[IO.File]::WriteAllLines($inventoryPath, [string[]]$inventory, $utf8)

# Use the production sealer and verifier. The fixture paths are never opened.
$batch = New-LocalMIPReportBatch -DiscoveryReport $discoveryPath -RetryReport $retryPath `
    -InventoryLog $inventoryPath -TenantId $TenantId -OutboxDirectory (Join-Path $PilotDirectory 'Outbox')
$verified = Test-LocalMIPReportBatch -BatchDirectory $batch.BatchDirectory
if (-not $verified.Verified -or $verified.Summary.candidateFiles -ne 3 -or
    $verified.Summary.respondedFiles -ne 2 -or $verified.Summary.noResponseFiles -ne 1 -or
    $verified.Summary.filesWithFindings -ne 1) {
    throw 'The sealed fixture does not match the expected counts.'
}

$result = [ordered]@{
    Test = 'W07D1-SecondSealedBatch'
    Outcome = 'Verified'
    Synthetic = $true
    BatchId = $verified.BatchId
    ManifestSha256 = $verified.ManifestSha256
    BatchDirectory = $verified.BatchDirectory
    Files = $verified.Summary.candidateFiles
    Responded = $verified.Summary.respondedFiles
    NoResponse = $verified.Summary.noResponseFiles
    FilesWithFindings = $verified.Summary.filesWithFindings
    CoverageErrors = $verified.Summary.coverageErrors
}
Write-Host '=== WORK W07D1 FOR SHARING ===' -ForegroundColor Magenta
Write-Host ($result | ConvertTo-Json) -ForegroundColor Magenta
