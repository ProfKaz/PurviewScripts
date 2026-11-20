<#PSScriptInfo
.VERSION 0.1.0
.GUID 0939436e-815a-4b44-a73c-f3d5d7e5f34
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 Read-only library and work-pilot ACL configuration review before real evidence transfer.
#>
<#
.DESCRIPTION
Inspects ACL configuration with the existing delegated Setup app. Does not test another user's effective access or modify permissions.
.NOTES
Version     : 0.1.0
Tracking ID : 0939436e-815a-4b44-a73c-f3d5d7e5f34
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][guid]$PortalClientId,[Parameter(Mandatory)][guid]$PublisherClientId,
    [Parameter(Mandatory)][guid]$ListId)
$ErrorActionPreference='Stop'
if($TenantId -eq [guid]::Empty -or $PortalClientId -eq [guid]::Empty -or $PublisherClientId -eq [guid]::Empty -or $ListId -eq [guid]::Empty -or $PortalClientId -eq $PublisherClientId){throw 'Specify distinct existing Setup/publisher identities and a list GUID.'}
if($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort){throw 'Expected commercial SharePoint site URL.'}
if(-not(Get-Module -ListAvailable PnP.PowerShell|Where-Object Version -eq ([version]'3.2.0'))){Install-Module PnP.PowerShell -RequiredVersion 3.2.0 -Scope CurrentUser -Repository PSGallery -Force}
Import-Module PnP.PowerShell -RequiredVersion 3.2.0
$connection=$null
$script:AclIssues=[Collections.Generic.List[object]]::new()
$script:AclAdmins=@{}
$script:AclGroupCache=@{}
function Classify-WorkPrincipal($Member){
    $login=[string]$Member.LoginName
    $type=[string]$Member.PrincipalType
    if($login -match ('^i:0i\.t\|ms\.sp\.ext\|'+[regex]::Escape($PublisherClientId.ToString())+'@'+[regex]::Escape($TenantId.ToString())+'$')){return 'ExpectedPublisherApplication'}
    if($login -match '^i:0i\.t\|ms\.sp\.ext\|[a-f0-9-]{36}@'){return 'OtherApplicationNeedsReview'}
    if($login -match 'spo-grid-all-users|^c:0\(\.s\|true$'){return 'BroadPrincipalNeedsReview'}
    if($type -match 'SecurityGroup|DistributionList'){return 'EntraGroupMembershipNotResolved'}
    if($script:AclAdmins.ContainsKey($login.ToLowerInvariant())){return 'ConfiguredSiteAdministrator'}
    if($type -eq 'User'){return 'NonSiteAdminUserNeedsReview'}
    return 'UnknownPrincipalNeedsReview'
}
function Read-WorkAclScope($Object,[string]$Name){
    $unique=[bool](Get-PnPProperty -ClientObject $Object -Property HasUniqueRoleAssignments -Connection $connection)
    $rows=@()
    if($unique){
        $rows=@(foreach($assignment in (Get-PnPProperty -ClientObject $Object -Property RoleAssignments -Connection $connection)){
            $member=Get-PnPProperty -ClientObject $assignment -Property Member -Connection $connection
            $null=Get-PnPProperty -ClientObject $member -Property LoginName,Title,PrincipalType -Connection $connection
            $bindings=@(Get-PnPProperty -ClientObject $assignment -Property RoleDefinitionBindings -Connection $connection)
            $roles=@(foreach($role in $bindings){
                $null=Get-PnPProperty -ClientObject $role -Property Name,RoleTypeKind -Connection $connection
                [pscustomobject]@{Name=$role.Name;RoleType=[int]$role.RoleTypeKind}
            })
            # RoleType.Guest=1 is Limited Access, regardless of localized role name.
            $substantive=@($roles|Where-Object RoleType -ne 1).Count -gt 0
            $members=@();$classification='LimitedAccessOnly'
            if($substantive){
                if([string]$member.PrincipalType -eq 'SharePointGroup'){
                    try{
                        $key=[string]$member.Id
                        if(-not $script:AclGroupCache.ContainsKey($key)){$script:AclGroupCache[$key]=@(Get-PnPGroupMember -Group $member.Id -Connection $connection)}
                        $members=@(foreach($user in $script:AclGroupCache[$key]){
                            [pscustomobject]@{Name=$user.Title;Login=$user.LoginName;PrincipalType=[string]$user.PrincipalType;Classification=(Classify-WorkPrincipal $user)}
                        })
                        $classification=if(-not $members.Count){'EmptySharePointGroupAtReviewTime'}elseif(@($members|Where-Object {$_.Classification -notin 'ConfiguredSiteAdministrator','ExpectedPublisherApplication'}).Count){'SharePointGroupNeedsReview'}else{'SharePointGroupAdministratorsOnly'}
                    }catch{
                        $classification='GroupMembershipReadFailed'
                        $script:AclIssues.Add([pscustomobject]@{Area=$Name;Group=$member.Title;ErrorType=$_.Exception.GetType().Name})
                    }
                }else{$classification=Classify-WorkPrincipal $member}
            }
            [pscustomobject]@{Name=$member.Title;Login=$member.LoginName;PrincipalType=[string]$member.PrincipalType
                Roles=$roles;SubstantiveAccess=$substantive;Classification=$classification;Members=$members}
        })
    }
    $flagged=@($rows|Where-Object {$_.SubstantiveAccess -and $_.Classification -notin 'ConfiguredSiteAdministrator','ExpectedPublisherApplication','EmptySharePointGroupAtReviewTime','SharePointGroupAdministratorsOnly'})
    [pscustomobject]@{Scope=$Name;HasUniqueRoleAssignments=$unique;Assignments=$rows;AssignmentsNeedingReview=$flagged.Count
        InheritedPermissionsEnumerated=$false}
}
try{
    $connection=Connect-PnPOnline -Url $SiteUrl.AbsoluteUri.TrimEnd('/') -Tenant $TenantId -ClientId $PortalClientId -Interactive -ReturnConnection
    $web=Get-PnPWeb -Includes Url -Connection $connection
    if($web.Url.TrimEnd('/') -ne $SiteUrl.AbsoluteUri.TrimEnd('/')){throw 'Connected site differs.'}
    $admins=@(Get-PnPSiteCollectionAdmin -Connection $connection)
    if(-not $admins.Count){throw 'Site administrator baseline could not be read.'}
    foreach($admin in $admins){
        if([string]::IsNullOrWhiteSpace([string]$admin.LoginName)){throw 'Site administrator identity was not loaded.'}
        $script:AclAdmins[([string]$admin.LoginName).ToLowerInvariant()]=$true
    }
    $list=Get-PnPList -Identity $ListId -Includes Id,Title,BaseTemplate,HasUniqueRoleAssignments,RootFolder -Connection $connection
    if($list.Title -ne 'ScannerPortalLanding' -or [guid]$list.Id -ne $ListId -or [int]$list.BaseTemplate -ne 101){throw 'Expected existing ScannerPortalLanding library.'}
    $rootFolder=Get-PnPProperty -ClientObject $list -Property RootFolder -Connection $connection
    $null=Get-PnPProperty -ClientObject $rootFolder -Property ServerRelativeUrl -Connection $connection
    $library=Read-WorkAclScope $list 'ScannerPortalLanding'
    # This is the existing direct parent created by W04; do not enumerate documents.
    $folder=Get-PnPFolder -Url ($rootFolder.ServerRelativeUrl.TrimEnd('/')+'/work-pilot') -Connection $connection
    $item=Get-PnPProperty -ClientObject $folder -Property ListItemAllFields -Connection $connection
    $parent=Read-WorkAclScope $item 'work-pilot'
    $reviewNeeded=(-not $library.HasUniqueRoleAssignments -or $library.AssignmentsNeedingReview -gt 0 -or $parent.AssignmentsNeedingReview -gt 0 -or $script:AclIssues.Count -gt 0)
    $result=[pscustomobject][ordered]@{Test='W05A-LibraryAclConfiguration';Version='0.1.0'
        Outcome=if($script:AclIssues.Count){'Partial'}elseif($reviewNeeded){'NeedsReview'}else{'ConfigurationReviewed'}
        TenantId=$TenantId.ToString();SiteUrl=$web.Url;ListId=$ListId.ToString();Authentication='ExistingSetupDelegatedInteractive'
        SetupClientId=$PortalClientId.ToString();PublisherClientId=$PublisherClientId.ToString()
        SiteAdministrators=@($admins|ForEach-Object {[pscustomobject]@{Name=$_.Title;Login=$_.LoginName}})
        Library=$library;WorkPilotParent=$parent;NeedsReview=$reviewNeeded;Issues=$script:AclIssues.ToArray()
        ReviewScope='Library and existing work-pilot parent only';DescendantUniquePermissionsReviewed=$false
        OrdinaryUserEffectiveAccessTested=$false;FutureTargetFolderAclReviewed=$false
        PermissionsChanged=$false;FilesUploaded=0;CertificatesCreated=0}
    Write-Host '=== WORK W05A PARA COMPARTIR ===' -ForegroundColor Magenta
    Write-Host ($result|ConvertTo-Json -Depth 12) -ForegroundColor Magenta
    $result
}finally{if($connection){Disconnect-PnPOnline -ErrorAction SilentlyContinue}}
