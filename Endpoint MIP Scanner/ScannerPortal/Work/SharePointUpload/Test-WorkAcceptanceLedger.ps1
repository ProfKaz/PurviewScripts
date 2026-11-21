<#PSScriptInfo
.VERSION 0.1.0
.GUID a35628b3-e27b-4d07-b5ca-a018b5dd8245
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-21 0.1.0 Mocked PnP acceptance list creation/reuse, schema/ACL rejection.
#>
<#
.NOTES
Version     : 0.1.0
Tracking ID : a35628b3-e27b-4d07-b5ca-a018b5dd8245
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$global:LedgerFixture=@{Exists=$false;Creates=0;Breaks=0;Fields=@{};Id=[guid]::NewGuid();Unsafe=$false;Unique=$true}
$global:LedgerFixture.Fields.Title=@{InternalName='Title';TypeAsString='Text';Indexed=$false;EnforceUniqueValues=$false;Required=$false}
function Get-Module{param($ListAvailable,$Name) @{Version=[version]'3.2.0'}}
function Import-Module{param($Name,$RequiredVersion)}
function Connect-PnPOnline{param($Url,$Tenant,$ClientId,[switch]$Interactive,[switch]$ReturnConnection) 'fixture'}
function Disconnect-PnPOnline{param($ErrorAction)}
function Get-PnPWeb{param($Includes,$Connection) @{Url='https://example.sharepoint.com/sites/Pilot'}}
function Get-PnPSiteCollectionAdmin{param($Connection) @{LoginName='admin@example.invalid'}}
function Get-PnPList{param($Identity,$Includes,$Connection)
 $f=$global:LedgerFixture
 if($f.Exists){[pscustomobject]@{Id=$f.Id;Title='ScannerPortalAcceptance';BaseTemplate=100;HasUniqueRoleAssignments=$f.Unique;RoleAssignments=@([pscustomobject]@{Member=[pscustomobject]@{LoginName=$(if($f.Unsafe){'other@example.invalid'}else{'admin@example.invalid'})};RoleDefinitionBindings=@([pscustomobject]@{Name='Full Control';RoleTypeKind=5})})}}
}
function New-PnPList{param($Title,$Template,$Url,[switch]$Hidden,$Connection) $global:LedgerFixture.Exists=$true;$global:LedgerFixture.Creates++}
function Set-PnPList{param($Identity,[switch]$BreakRoleInheritance,[switch]$CopyRoleAssignments,$Connection)
 if(-not $BreakRoleInheritance -or $CopyRoleAssignments){throw 'Unsafe ACL copy/reset'};$global:LedgerFixture.Breaks++
}
function Get-PnPProperty{param($ClientObject,[string[]]$Property,$Connection) if($Property.Count -eq 1 -and $Property[0] -eq 'Member'){$ClientObject.Member}}
function Get-PnPField{param($List,$Identity,$Connection) if($Identity){[pscustomobject]$global:LedgerFixture.Fields[$Identity]}else{foreach($v in $global:LedgerFixture.Fields.Values){[pscustomobject]$v}}}
function Add-PnPField{param($List,$DisplayName,$InternalName,$Type,$Connection) $global:LedgerFixture.Fields[$InternalName]=@{InternalName=$InternalName;TypeAsString=$Type}}
function Set-PnPField{param($List,$Identity,$Values,$Connection) foreach($key in $Values.Keys){$global:LedgerFixture.Fields[$Identity][$key]=$Values[$key]}}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
try{
 $common=@{TenantId=[guid]::NewGuid();SiteUrl='https://example.sharepoint.com/sites/Pilot';PortalClientId=[guid]::NewGuid();PublisherClientId=[guid]::NewGuid()}
 $scriptPath=Join-Path $PSScriptRoot 'Initialize-WorkAcceptanceLedger.ps1'
 $first=& $scriptPath @common;$again=& $scriptPath @common
 Assert ($first.CreatedThisRun -and -not $again.CreatedThisRun -and $global:LedgerFixture.Creates -eq 1 -and $global:LedgerFixture.Breaks -eq 1 -and $again.FieldsCreatedThisRun -eq 0) 'Repeated preparation changed ACL or duplicated list/fields.'
 Assert (-not $first.ReadyForAcceptance -and $first.AcceptanceRecordsCreated -eq 0 -and -not $first.PublisherEffectiveAccessTested) 'Preparation falsely claims acceptance/access verification.'
 $global:LedgerFixture.Unsafe=$true;$failed=$false;try{& $scriptPath @common|Out-Null}catch{$failed=$true};Assert $failed 'Unsafe ACL accepted.'
 $global:LedgerFixture.Unsafe=$false;$global:LedgerFixture.Unique=$false;$failed=$false;try{& $scriptPath @common|Out-Null}catch{$failed=$true};Assert $failed 'Inherited ACL accepted.'
 $global:LedgerFixture.Unique=$true;$global:LedgerFixture.Fields.BatchId.TypeAsString='Number';$failed=$false;try{& $scriptPath @common|Out-Null}catch{$failed=$true};Assert $failed 'Wrong schema accepted.'
 'PASS: mocked PnP create/reuse, no repeat ACL reset, unique indexed key, unsafe/inherited ACL and wrong field type rejection; zero acceptances'
}finally{Remove-Variable LedgerFixture -Scope Global}
