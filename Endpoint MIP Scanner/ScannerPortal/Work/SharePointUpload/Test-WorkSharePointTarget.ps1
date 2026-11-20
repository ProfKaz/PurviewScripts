<#PSScriptInfo
.VERSION 0.1.0
.GUID e6978500-1f7b-4c96-94a4-d0e91186fc7b
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 W03A GET-only hidden library, missing target and partial-permission tests.
#>
<#
.DESCRIPTION
Mock Graph only; no tenant or SharePoint operations.
.NOTES
Version     : 0.1.0
Tracking ID : e6978500-1f7b-4c96-94a4-d0e91186fc7b
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$global:TargetFixture=@{Tenant=[guid]::NewGuid().ToString();Client=[guid]::NewGuid().ToString();Mode='EmptyGrant'}
function Get-Module{param($Name,[switch]$ListAvailable) [pscustomobject]@{Name='Microsoft.Graph.Authentication'}}
function Import-Module{param($Name)}
function Connect-MgGraph{param($TenantId,$Scopes,$ContextScope,[switch]$NoWelcome) if($Scopes -ne 'Sites.Read.All'){throw 'Unexpected write scope.'}}
function Get-MgContext{[pscustomobject]@{TenantId=$global:TargetFixture.Tenant}}
function Disconnect-MgGraph{param($ErrorAction)}
function Invoke-MgGraphRequest{param($Uri,$Method,$OutputType)
    if($Method -ne 'GET'){throw 'Write attempted.'}
    $f=$global:TargetFixture
    if($Uri -match '/sites/example.sharepoint.com:'){return @{id='site-id';displayName='Pilot';webUrl='https://example.sharepoint.com/sites/Pilot'}}
    if($Uri.Contains('/lists?')){
        if(-not $Uri.Contains(',system')){throw 'System facet was not selected; hidden libraries may be missed.'}
        return @{value=@(@{id='list-id';displayName='ScannerPortalLanding';list=@{template='documentLibrary';hidden=$true};webUrl='https://example.sharepoint.com/sites/Pilot/ScannerPortalLanding'})}
    }
    if($Uri.Contains('/drive?')){return @{id='drive-id';name='ScannerPortalLanding'}}
    if($Uri.EndsWith('/permissions')){
        if($f.Mode -eq 'Denied'){$e=[Exception]::new('denied');$e|Add-Member ResponseStatusCode 403;throw $e}
        if($f.Mode -eq 'Grant'){return @{value=@(@{id='grant-id';grantedToV2=@{application=@{id=$f.Client}};roles=@('write')})}}
        return @{value=@()}
    }
    throw "Unexpected request: $Uri"
}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$path=Join-Path $PSScriptRoot 'Get-WorkSharePointTarget.ps1'
$common=@{TenantId=$global:TargetFixture.Tenant;PublisherClientId=$global:TargetFixture.Client;SiteUrl='https://example.sharepoint.com/sites/Pilot'}
try{
    $result=& $path @common
    Assert ($result.Outcome -eq 'Inspected' -and $result.Library.Hidden -and $result.Library.DriveId -eq 'drive-id') 'Hidden landing library was not resolved.'
    Assert ($result.LibraryPermissionsInspected -and $result.PublisherGrantsAtLibrary.Count -eq 0 -and -not $result.PublisherEffectiveAccessTested) 'Empty grant inspection falsely claimed effective access.'
    $global:TargetFixture.Mode='Grant';$result=& $path @common
    Assert ($result.PublisherGrantsAtLibrary.Count -eq 1 -and $result.PublisherGrantsAtLibrary[0].Roles[0] -eq 'write') 'Publisher grant was not recognized.'
    $global:TargetFixture.Mode='Denied';$result=& $path @common
    Assert ($result.Outcome -eq 'Partial' -and -not $result.LibraryPermissionsInspected -and $result.Issues[0].StatusCode -eq 403) 'Denied permission read appeared as an inspected empty grant.'
    $result=& $path @common -LibraryName 'MissingLibrary'
    Assert ($result.Outcome -eq 'LibraryNotFound' -and -not $result.LibraryFound -and $result.Library -eq $null) 'Missing library was fabricated/created.'
    'PASS: W03A GET-only read scope, hidden library resolution, grant inspection, partial denial and missing library (mock Graph)'
}finally{Remove-Variable TargetFixture -Scope Global}
