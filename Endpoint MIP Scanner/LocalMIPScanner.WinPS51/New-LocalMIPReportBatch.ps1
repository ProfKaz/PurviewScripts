<#PSScriptInfo

.VERSION 1.0.0

.GUID d279bf37-ff61-433b-8f20-4b5210704aa7

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-20  1.0.0  Consolidate local discovery and retry evidence into verified pending batches.
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/New-LocalMIPReportBatch.ps1.
.NOTES
HISTORY
Version     : 1.0.0
Tracking ID : d279bf37-ff61-433b-8f20-4b5210704aa7
2026-11-20  Kaz Demos  Initial local batch implementation and verification.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding(DefaultParameterSetName='Create')]
param(
    [Parameter(Mandatory,ParameterSetName='Create')][string] $DiscoveryReport,
    [Parameter(Mandatory,ParameterSetName='Create')][string] $RetryReport,
    [Parameter(Mandatory,ParameterSetName='Create')][string] $InventoryLog,
    [Parameter(Mandatory,ParameterSetName='Create')][guid] $TenantId,
    [Parameter(ParameterSetName='Create')][string] $AccountObjectId,
    [Parameter(ParameterSetName='Create')][string] $DeviceId,
    [Parameter(ParameterSetName='Create')][string] $OutboxDirectory,
    [Parameter(Mandatory,ParameterSetName='Verify')][string] $VerifyBatch
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalMIPReporting.psm1') -Force -ErrorAction Stop
if ($PSCmdlet.ParameterSetName -eq 'Verify') {
    $result = Test-LocalMIPReportBatch -BatchDirectory $VerifyBatch
} else {
    $parameters = @{
        DiscoveryReport = $DiscoveryReport; RetryReport = $RetryReport
        InventoryLog = $InventoryLog; TenantId = $TenantId
    }
    foreach ($name in 'AccountObjectId','DeviceId','OutboxDirectory') {
        if ($PSBoundParameters.ContainsKey($name)) { $parameters[$name] = $PSBoundParameters[$name] }
    }
    $result = New-LocalMIPReportBatch @parameters
}
Write-Host '=== LOTE LOCAL PARA COMPARTIR ===' -ForegroundColor Magenta
$display = [ordered]@{
    VerifiedLocal = $result.Verified; DeliveryState = $result.DeliveryState
    BatchId = $result.BatchId; BatchDirectory = $result.BatchDirectory; ManifestSha256 = $result.ManifestSha256
    Candidates = $result.Summary['candidateFiles']; Responded = $result.Summary['respondedFiles']
    NoResponse = $result.Summary['noResponseFiles']; Errors = $result.Summary['errorFiles']
    Skipped = $result.Summary['skippedFiles']; FilesWithFindings = $result.Summary['filesWithFindings']
    CoverageErrors = $result.Summary['coverageErrors']; AppliedRetries = $result.Summary['appliedRetryCount']
    DetectedSitTypes = @($result.Summary['findingsByType']).Count
}
Write-Host ($display | ConvertTo-Json -Depth 4) -ForegroundColor Magenta
$result
