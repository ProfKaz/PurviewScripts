<#PSScriptInfo
.VERSION 0.1.0
.GUID 5d60e962-a7e4-47be-839b-c61b96789a75
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 ACL configuration classification tests with simulated PnP.
#>
<#
.DESCRIPTION
Offline mocks; no SharePoint login, writes or permission changes.
.NOTES
Version     : 0.1.0
Tracking ID : 5d60e962-a7e4-47be-839b-c61b96789a75
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$global:AclFixture=@{Tenant=[guid]::NewGuid().ToString();Setup=[guid]::NewGuid().ToString();Publisher=[guid]::NewGuid().ToString();List=[guid]::NewGuid().ToString();GroupFails=$false}
$global:AclFixture.Admin=[pscustomobject]@{Title='Fixture Admin';LoginName='i:0#.f|membership|admin@example.invalid';PrincipalType='User'}
$global:AclFixture.Members=@($global:AclFixture.Admin)
$group=[pscustomobject]@{Id=7;Title='Owners';LoginName='Owners';PrincipalType='SharePointGroup'}
$app=[pscustomobject]@{Title='Work Publisher';LoginName=('i:0i.t|ms.sp.ext|'+$global:AclFixture.Publisher+'@'+$global:AclFixture.Tenant);PrincipalType='User'}
$limited=[pscustomobject]@{Title='Limited entry';LoginName='limited@example.invalid';PrincipalType='User'}
$global:AclFixture.Library=[pscustomobject]@{Id=$global:AclFixture.List;Title='ScannerPortalLanding';BaseTemplate=101;Unique=$true
    Root=[pscustomobject]@{ServerRelativeUrl='/sites/Pilot/ScannerPortalLanding'}
    Assignments=@(
        [pscustomobject]@{Member=$group;Roles=@([pscustomobject]@{Name='Full Control';RoleTypeKind=5})},
        [pscustomobject]@{Member=$app;Roles=@([pscustomobject]@{Name='Contribute';RoleTypeKind=3})},
        [pscustomobject]@{Member=$limited;Roles=@([pscustomobject]@{Name='Acceso limitado';RoleTypeKind=1})}
    )}
$global:AclFixture.Parent=[pscustomobject]@{Unique=$false;Assignments=@()}
function Get-Module{param($Name,[switch]$ListAvailable) [pscustomobject]@{Version=[version]'3.2.0'}}
function Import-Module{param($Name,$RequiredVersion)}
function Connect-PnPOnline{param($Url,$Tenant,$ClientId,[switch]$Interactive,[switch]$ReturnConnection) 'fixture-connection'}
function Disconnect-PnPOnline{param($ErrorAction)}
function Get-PnPWeb{param($Includes,$Connection) [pscustomobject]@{Url='https://example.sharepoint.com/sites/Pilot'}}
function Get-PnPSiteCollectionAdmin{param($Connection) $global:AclFixture.Admin}
function Get-PnPList{param($Identity,$Includes,$Connection) $global:AclFixture.Library}
function Get-PnPFolder{param($Url,$Connection) [pscustomobject]@{Item=$global:AclFixture.Parent}}
function Get-PnPGroupMember{param($Group,$Connection) if($global:AclFixture.GroupFails){throw 'Membership denied'};$global:AclFixture.Members}
function Get-PnPProperty{param($ClientObject,[string[]]$Property,$Connection)
    if($Property.Count -gt 1){return}
    switch($Property[0]){
        'HasUniqueRoleAssignments'{$ClientObject.Unique}
        'RoleAssignments'{$ClientObject.Assignments}
        'Member'{$ClientObject.Member}
        'RoleDefinitionBindings'{$ClientObject.Roles}
        'RootFolder'{$ClientObject.Root}
        'ListItemAllFields'{$ClientObject.Item}
    }
}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$common=@{TenantId=$global:AclFixture.Tenant;PortalClientId=$global:AclFixture.Setup;PublisherClientId=$global:AclFixture.Publisher;ListId=$global:AclFixture.List;SiteUrl='https://example.sharepoint.com/sites/Pilot'}
$path=Join-Path $PSScriptRoot 'Get-WorkLibraryAcl.ps1'
try{
    $result=& $path @common
    Assert ($result.Outcome -eq 'ConfigurationReviewed' -and -not $result.NeedsReview) 'Expected admin group/publisher classification failed.'
    Assert ($result.Library.Assignments[2].Classification -eq 'LimitedAccessOnly' -and -not $result.OrdinaryUserEffectiveAccessTested) 'Limited Access or review scope was misrepresented.'
    $global:AclFixture.Members=@([pscustomobject]@{Title='Nested Entra group';LoginName='c:0t.c|tenant|group-guid';PrincipalType='SecurityGroup'})
    $result=& $path @common
    Assert ($result.NeedsReview -and $result.Library.Assignments[0].Members[0].Classification -eq 'EntraGroupMembershipNotResolved') 'Unresolved Entra group was treated as restricted.'
    $global:AclFixture.Members=@([pscustomobject]@{Title='GUID-shaped user';LoginName=('i:0#.f|membership|'+$global:AclFixture.Publisher+'@example.invalid');PrincipalType='User'})
    $result=& $path @common
    Assert ($result.NeedsReview -and $result.Library.Assignments[0].Members[0].Classification -eq 'NonSiteAdminUserNeedsReview') 'A user UPN was mistaken for the publisher application claim.'
    $global:AclFixture.GroupFails=$true;$result=& $path @common
    Assert ($result.Outcome -eq 'Partial' -and $result.Issues.Count -gt 0) 'Membership failure appeared as an empty allowed group.'
    $global:AclFixture.GroupFails=$false;$global:AclFixture.Members=@($global:AclFixture.Admin);$global:AclFixture.Library.Unique=$false
    $result=& $path @common
    Assert ($result.NeedsReview -and -not $result.Library.InheritedPermissionsEnumerated) 'Inherited library was declared restricted without inspection.'
    $global:AclFixture.Library.Unique=$true;$global:AclFixture.Parent.Unique=$true
    $global:AclFixture.Parent.Assignments=@([pscustomobject]@{Member=[pscustomobject]@{Title='Other User';LoginName='other@example.invalid';PrincipalType='User'};Roles=@([pscustomobject]@{Name='Read';RoleTypeKind=2})})
    $result=& $path @common
    Assert ($result.NeedsReview -and $result.WorkPilotParent.AssignmentsNeedingReview -eq 1) 'Unique parent-folder user access was missed.'
    'PASS: read-only ACL review, admin/publisher/Limited Access classification, unresolved group, failed membership, inheritance and parent-folder exception (mock PnP)'
}finally{Remove-Variable AclFixture -Scope Global}
