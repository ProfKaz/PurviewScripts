<#PSScriptInfo
.VERSION 1.1.0
.GUID 6def98b7-2ffc-414f-b51b-8cca247a6168
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.PROJECTURI https://github.com/ProfKaz/PurviewScripts
.RELEASENOTES
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: 6def98b7-2ffc-414f-b51b-8cca247a6168
#>
<#
.DESCRIPTION
Endpoint MIP Scanner component: deployment/Invoke-PortalSetup.ps1.
.NOTES
HISTORY
Script      : deployment/Invoke-PortalSetup.ps1
Version     : 1.1.0
Tracking ID : 6def98b7-2ffc-414f-b51b-8cca247a6168
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid] $TenantId,
    [guid] $ClientId = [guid]::Empty,
    [Parameter(Mandatory)][string] $AdminUrl,
    [Parameter(Mandatory)][string] $SiteUrl,
    [Parameter(Mandatory)][string] $Owner,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [switch] $ResumeFoundation
)
$ErrorActionPreference = 'Stop'
$suite = Split-Path -Parent $PSScriptRoot
$recordPath = Join-Path $EvidenceDirectory 'portal-app.json'
$logo = Join-Path $suite 'labs/MipSdkAudit/kaz-demos-entra-215.png'
if (-not (Test-Path -LiteralPath $logo -PathType Leaf)) { throw "Missing branding asset: $logo" }

foreach ($module in 'Microsoft.Graph.Authentication','Microsoft.Graph.Applications') {
    if (-not (Get-Module -ListAvailable $module)) {
        Install-Module $module -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
    }
}
if (-not (Get-Module -ListAvailable PnP.PowerShell | Where-Object Version -eq ([version]'3.2.0'))) {
    Install-Module PnP.PowerShell -RequiredVersion 3.2.0 -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
}
Import-Module PnP.PowerShell -RequiredVersion 3.2.0
Import-Module Microsoft.Graph.Authentication,Microsoft.Graph.Applications
Connect-MgGraph -TenantId $TenantId -Scopes Application.ReadWrite.All -NoWelcome
try {
    if ((Get-MgContext).TenantId -ne $TenantId.ToString()) { throw 'Graph connected to the wrong tenant.' }
    if (Test-Path -LiteralPath $recordPath) {
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        if ($record.TenantId -ne $TenantId.ToString()) { throw 'Saved portal app belongs to a different tenant.' }
        if ($ClientId -ne [guid]::Empty -and $ClientId.ToString() -ne $record.ClientId) {
            throw 'Explicit portal client ID differs from saved installation.'
        }
        $ClientId = [guid]$record.ClientId
    }
    $displayName = 'Kaz Demos Scanner Portal - Setup'
    if ($ClientId -eq [guid]::Empty) {
        if (@(Get-MgApplication -Filter "displayName eq '$displayName'").Count -gt 0) {
            throw 'Portal setup app already exists. Supply -PortalClientId to reuse the intended registration.'
        }
        $newApp = @{
            DisplayName = $displayName; SignInAudience = 'AzureADMyOrg'
            IsFallbackPublicClient = $true; PublicClient = @{ RedirectUris = @('http://localhost') }
        }
        $app = New-MgApplication @newApp
        $ClientId = [guid]$app.AppId
        # Persist immediately so a later failure never creates a duplicate.
        @{ TenantId = $TenantId.ToString(); ClientId = $ClientId.ToString(); AppObjectId = $app.Id } |
            ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding utf8
    } else {
        $apps = @(Get-MgApplication -Filter "appId eq '$ClientId'")
        if ($apps.Count -ne 1) { throw 'Portal app must be owned by the selected tenant.' }
        $app = $apps[0]
    }
    $resources = @{}
    foreach ($entry in $app.RequiredResourceAccess) {
        $resources[$entry.ResourceAppId] = @($entry.ResourceAccess | ForEach-Object { @{ Id = $_.Id; Type = $_.Type } })
    }
    foreach ($resource in @(
        @{ AppId = '00000003-0000-0000-c000-000000000000'; Scope = 'User.Read' },
        @{ AppId = '00000003-0000-0ff1-ce00-000000000000'; Scope = 'AllSites.FullControl' }
    )) {
        $principal = @(Get-MgServicePrincipal -Filter "appId eq '$($resource.AppId)'")
        if ($principal.Count -ne 1) { throw "Resource principal unavailable: $($resource.AppId)" }
        $scope = @($principal[0].Oauth2PermissionScopes | Where-Object { $_.Value -eq $resource.Scope -and $_.IsEnabled })
        if ($scope.Count -ne 1) { throw "Scope unavailable: $($resource.Scope)" }
        if (-not $resources.ContainsKey($resource.AppId)) { $resources[$resource.AppId] = @() }
        if (-not @($resources[$resource.AppId] | Where-Object { $_.Id -eq $scope[0].Id -and $_.Type -eq 'Scope' }).Count) {
            $resources[$resource.AppId] += @{ Id = $scope[0].Id; Type = 'Scope' }
        }
    }
    $required = @(foreach ($key in $resources.Keys) { @{ ResourceAppId = $key; ResourceAccess = $resources[$key] } })
    $redirects = @($app.PublicClient.RedirectUris)
    if ('http://localhost' -notin $redirects) { $redirects += 'http://localhost' }
    $update = @{
        ApplicationId = $app.Id; RequiredResourceAccess = $required
        PublicClient = @{ RedirectUris = $redirects }; IsFallbackPublicClient = $true
    }
    Update-MgApplication @update
    if (@(Get-MgServicePrincipal -Filter "appId eq '$ClientId'").Count -eq 0) {
        $null = New-MgServicePrincipal -AppId $ClientId
    }
    Set-MgApplicationLogo -ApplicationId $app.Id -InFile $logo
    $record = @{
        TenantId = $TenantId.ToString(); ClientId = $ClientId.ToString(); AppObjectId = $app.Id
        LogoSha256 = (Get-FileHash -LiteralPath $logo -Algorithm SHA256).Hash
        AdministrativePermissions = @('User.Read','AllSites.FullControl')
    }
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding utf8
} finally { Disconnect-MgGraph | Out-Null }

$parameters = @{
    AdminUrl = $AdminUrl; SiteUrl = $SiteUrl; Owner = $Owner
    ClientId = $ClientId; Tenant = $TenantId.ToString(); Mode = 'Apply'; DeployFoundation = $true
}
if ($ResumeFoundation) { $parameters.ResumeFoundation = $true }
$result = @(& (Join-Path $suite 'ScannerPortal/deployment/New-ScannerPortalPilot.ps1') @parameters)
$result | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $EvidenceDirectory 'portal-foundation.json') -Encoding utf8
@{
    PowerShell = $PSVersionTable.PSVersion.ToString()
    Modules = @(Get-Module | Select-Object Name, Version, Path)
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $EvidenceDirectory 'portal-dependencies.json') -Encoding utf8
if (@($result | Where-Object { $_.Status -eq 'AlreadyExistsNeedsReview' }).Count) {
    throw 'Pilot site already exists. Review it and rerun with -ResumeFoundation to provision the foundation.'
}
$result
