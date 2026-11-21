<#PSScriptInfo
.VERSION 0.1.0
.GUID 215e99b9-9f1e-49a5-90ad-a4073ab0b378
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 Plan/apply/reuse and target/role rejection tests with simulated Graph.
#>
<#
.DESCRIPTION
Mock transport only; no real grants, certificates or SharePoint operations.
.NOTES
Version     : 0.1.0
Tracking ID : 215e99b9-9f1e-49a5-90ad-a4073ab0b378
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$global:GrantFixture=@{Tenant=[guid]::NewGuid().ToString();Client=[guid]::NewGuid().ToString();List=[guid]::NewGuid().ToString()
    Grants=@();Posts=0;Library='ScannerPortalLanding';AppName='Kaz Demos Scanner Publisher - Work'}
function Get-Module{param($Name,[switch]$ListAvailable) [pscustomobject]@{Name='Microsoft.Graph.Authentication'}}
function Import-Module{param($Name)}
function Connect-MgGraph{param($TenantId,$Scopes,$ContextScope,[switch]$NoWelcome) if($Scopes -contains 'Sites.FullControl.All'){throw 'Unexpected full control scope.'}}
function Get-MgContext{[pscustomobject]@{TenantId=$global:GrantFixture.Tenant}}
function Disconnect-MgGraph{param($ErrorAction)}
function Invoke-MgGraphRequest{param($Uri,$Method,$OutputType,$Body,$ContentType)
    $f=$global:GrantFixture
    if($Uri.Contains('/applications?')){return @{value=@(@{appId=$f.Client;displayName=$f.AppName})}}
    if($Uri.Contains('/sites/example.sharepoint.com:')){return @{id='site-id';webUrl='https://example.sharepoint.com/sites/Pilot'}}
    if($Uri.Contains('/drive?')){return @{id='drive-id'}}
    if($Uri.EndsWith('/permissions')){
        if($Method -eq 'POST'){
            if($Uri -ne ('https://graph.microsoft.com/v1.0/sites/site-id/lists/'+$f.List+'/permissions')){throw 'Wrong write destination.'}
            $grant=$Body|ConvertFrom-Json -AsHashtable
            if($grant.roles.Count -ne 1 -or $grant.roles[0] -ne 'write' -or $grant.grantedToV2.application.id -ne $f.Client){throw 'Wrong role/principal payload.'}
            $f.Posts++;$grant.id='grant-id';$f.Grants+=,$grant;return $grant
        }
        return @{value=$f.Grants}
    }
    if($Uri.Contains('/lists/')){return @{id=$f.List;displayName=$f.Library;list=@{template='documentLibrary'}}}
    throw "Unexpected operation: $Method $Uri"
}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed 'Expected rejection.'}
$path=Join-Path $PSScriptRoot 'Set-WorkSharePointLibraryGrant.ps1'
$common=@{TenantId=$global:GrantFixture.Tenant;PublisherClientId=$global:GrantFixture.Client;ListId=$global:GrantFixture.List;SiteUrl='https://example.sharepoint.com/sites/Pilot'}
try{
    $plan=& $path @common
    Assert ($plan.Outcome -eq 'GrantRequired' -and $global:GrantFixture.Posts -eq 0) 'Plan modified permissions.'
    $first=& $path @common -Apply
    $repeat=& $path @common -Apply
    Assert ($first.GrantCreatedThisRun -and $first.GrantReadBackVerified -and -not $repeat.GrantCreatedThisRun -and $global:GrantFixture.Posts -eq 1) 'Apply did not verify/reuse the one expected grant.'
    Assert (-not $repeat.PublisherEffectiveAccessTested -and $repeat.FilesUploaded -eq 0) 'Grant readback falsely claimed effective file access.'
    $global:GrantFixture.Grants[0].roles=@('read');Reject {& $path @common -Apply}
    Assert ($global:GrantFixture.Posts -eq 1) 'Unexpected existing role was changed.'
    $global:GrantFixture.Library='ScannerPortalConfig';Reject {& $path @common -Apply}
    $global:GrantFixture.Library='ScannerPortalLanding';$global:GrantFixture.AppName='LocalMIPScanner MIP SDK Lab';Reject {& $path @common -Apply}
    Assert ($global:GrantFixture.Posts -eq 1) 'Wrong library/application received write access.'
    'PASS: W03B default Plan, one selected-library write grant, readback/reuse, wrong role/library/app rejection (mock Graph)'
}finally{Remove-Variable GrantFixture -Scope Global}
