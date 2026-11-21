<#PSScriptInfo
.VERSION 0.2.0
.GUID 5d60e962-a7e4-47be-839b-c61b96789a75
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.2.0 Reproduce non-enumerated collection output instead of only array fixtures.
2026-11-20 0.1.0 ACL configuration classification tests with simulated PnP.
#>
<#
.DESCRIPTION
Offline mocks; no SharePoint login, writes or permission changes.
.NOTES
Version     : 0.2.0
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
    if($ClientObject -is [Collections.IList] -and ($Property -contains 'Name' -or $Property -contains 'RoleTypeKind')){throw 'A binding collection is not an individual role definition.'}
    if($Property.Count -gt 1){return}
    switch($Property[0]){
        'HasUniqueRoleAssignments'{$ClientObject.Unique}
        'RoleAssignments'{
            $collection=[Collections.Generic.List[object]]::new()
            foreach($entry in $ClientObject.Assignments){$collection.Add($entry)}
            $ClientObject|Add-Member RoleAssignments $collection -Force
            Write-Output -NoEnumerate $collection
        }
        'Member'{$ClientObject.Member}
        'RoleDefinitionBindings'{
            $collection=[Collections.Generic.List[object]]::new()
            foreach($entry in $ClientObject.Roles){$collection.Add($entry)}
            $ClientObject|Add-Member RoleDefinitionBindings $collection -Force
            Write-Output -NoEnumerate $collection
        }
        'RootFolder'{$ClientObject.Root}
        'ListItemAllFields'{$ClientObject.Item}
    }
}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$common=@{TenantId=$global:AclFixture.Tenant;PortalClientId=$global:AclFixture.Setup;PublisherClientId=$global:AclFixture.Publisher;ListId=$global:AclFixture.List;SiteUrl='https://example.sharepoint.com/sites/Pilot'}
$path=Join-Path $PSScriptRoot 'Get-WorkLibraryAcl.ps1'
try{
    # Regression fixture: array-wrapping a non-enumerated collection hides the roles.
    $entry=$global:AclFixture.Library.Assignments[0]
    $wrapped=@(Get-PnPProperty -ClientObject $entry -Property RoleDefinitionBindings -Connection fixture)
    Assert ($wrapped.Count -eq 1 -and $wrapped[0] -is [Collections.IList]) 'Fixture did not reproduce the PnP collection boundary.'
    $oldRejected=$false;try{$null=Get-PnPProperty -ClientObject $wrapped[0] -Property Name,RoleTypeKind -Connection fixture}catch{$oldRejected=$true}
    Assert $oldRejected 'Previous collection-as-role access was not rejected.'
    $entry.Roles+= [pscustomobject]@{Name='Read';RoleTypeKind=2}
    $result=& $path @common
    Assert ($result.Outcome -eq 'ConfigurationReviewed' -and -not $result.NeedsReview) 'Expected admin group/publisher classification failed.'
    Assert ($result.Library.Assignments[0].Roles.Count -eq 2 -and $result.Library.Assignments[0].Roles[0].Name -eq 'Full Control') 'Multiple binding roles were not enumerated individually.'
    Assert ($result.Library.Assignments[2].Classification -eq 'LimitedAccessOnly' -and -not $result.OrdinaryUserEffectiveAccessTested) 'Limited Access or review scope was misrepresented.'
    $targetPath='work-pilot/devices/'+('a'*32)+'/batches/'+('b'*64)
    $target=& $path @common -TargetRelativePath $targetPath
    Assert ($target.TargetFolderAclReviewed -and $target.TargetAncestorScopes.Count -eq 5 -and -not $target.NeedsReview -and -not $target.ReadyForRealUpload) 'Exact target ancestor review failed.'
    $rejected=$false;try{& $path @common -TargetRelativePath '../escape'|Out-Null}catch{$rejected=$true}
    Assert $rejected 'Traversal target accepted.'
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
    'PASS: non-enumerated collection regression, individual/multiple roles, admin/publisher/Limited Access, unresolved/failed membership, inheritance and parent exception (mock PnP)'
}finally{Remove-Variable AclFixture -Scope Global}
