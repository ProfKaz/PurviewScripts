<#PSScriptInfo
.VERSION 0.1.0
.GUID 293a1ff1-f699-44bc-9e22-6e2d2aa0d5d2
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-21 0.1.0 W06B1 prepare a separate central acceptance list; no batch acceptance yet.
#>
<#
.DESCRIPTION
Creates/reuses a dedicated acceptance ledger and reviews its ACL. Does not grant endpoint access or publish acceptance records.
.NOTES
Version     : 0.1.0
Tracking ID : 293a1ff1-f699-44bc-9e22-6e2d2aa0d5d2
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][uri]$SiteUrl,
 [Parameter(Mandatory)][guid]$PortalClientId,[Parameter(Mandatory)][guid]$PublisherClientId)
$ErrorActionPreference='Stop'
if($TenantId -eq [guid]::Empty -or $PortalClientId -eq [guid]::Empty -or $PublisherClientId -eq [guid]::Empty -or $PublisherClientId -eq $PortalClientId){throw 'Distinct nonempty Setup/publisher IDs required.'}
if($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort){throw 'Invalid site URL.'}
if(-not(Get-Module -ListAvailable PnP.PowerShell|Where-Object Version -eq ([version]'3.2.0'))){Install-Module PnP.PowerShell -RequiredVersion 3.2.0 -Scope CurrentUser -Repository PSGallery -Force}
Import-Module PnP.PowerShell -RequiredVersion 3.2.0
$connection=$null;$name='ScannerPortalAcceptance';$created=$false;$fieldsCreated=0
try{
 $connection=Connect-PnPOnline -Url $SiteUrl.AbsoluteUri.TrimEnd('/') -Tenant $TenantId -ClientId $PortalClientId -Interactive -ReturnConnection
 $web=Get-PnPWeb -Includes Url -Connection $connection
 if($web.Url.TrimEnd('/') -ne $SiteUrl.AbsoluteUri.TrimEnd('/')){throw 'Connected site mismatch.'}
 $admins=@(Get-PnPSiteCollectionAdmin -Connection $connection)
 if(-not $admins.Count){throw 'Cannot read site administrators.'}
 $adminLogins=@($admins|ForEach-Object {$_.LoginName})
 $lists=@(Get-PnPList -Includes Id,Title,BaseTemplate,HasUniqueRoleAssignments,Hidden -Connection $connection|Where-Object Title -eq $name)
 if($lists.Count -gt 1){throw 'Ambiguous acceptance list.'}
 if(-not $lists.Count){
  $null=New-PnPList -Title $name -Template GenericList -Url ('Lists/'+$name) -Hidden -Connection $connection
  $created=$true
  # New empty list only: do not copy parent grants. Existing list ACLs are never reset.
  $null=Set-PnPList -Identity $name -BreakRoleInheritance -CopyRoleAssignments:$false -Connection $connection
 }
 $list=Get-PnPList -Identity $name -Includes Id,Title,BaseTemplate,HasUniqueRoleAssignments,Hidden -Connection $connection
 if($list.BaseTemplate -ne 100 -or -not $list.HasUniqueRoleAssignments){throw 'Acceptance list must be a generic list with unique ACL; inspect manually, no automatic reset.'}
 $null=Get-PnPProperty -ClientObject $list -Property RoleAssignments -Connection $connection
 $acl=@(foreach($assignment in $list.RoleAssignments){
  $member=Get-PnPProperty -ClientObject $assignment -Property Member -Connection $connection
  $null=Get-PnPProperty -ClientObject $member -Property LoginName,PrincipalType,Title -Connection $connection
  $null=Get-PnPProperty -ClientObject $assignment -Property RoleDefinitionBindings -Connection $connection
  $roles=@(foreach($role in $assignment.RoleDefinitionBindings){
   $null=Get-PnPProperty -ClientObject $role -Property Name,RoleTypeKind -Connection $connection
   [pscustomobject]@{Name=$role.Name;RoleType=[int]$role.RoleTypeKind}
  })
  [pscustomobject]@{Login=$member.LoginName;Roles=$roles;SubstantiveAccess=(@($roles|Where-Object RoleType -ne 1).Count -gt 0);IsSiteAdministrator=($member.LoginName -in $adminLogins)}
 })
 if(@($acl|Where-Object {$_.SubstantiveAccess -and -not $_.IsSiteAdministrator}).Count){throw 'Acceptance list has non-site-administrator access; no acceptance permitted. Inspect ACL manually.'}
 if(-not @($acl|Where-Object {$_.SubstantiveAccess -and $_.IsSiteAdministrator}).Count){throw 'No explicit site administrator assignment found.'}
 $specs=[ordered]@{Title='Text';BatchId='Text';ManifestSha256='Text';ReportingDeviceId='Text';SourceListId='Text';SourceRelativePath='Note';AcceptanceJson='Note'}
 foreach($fieldName in $specs.Keys){
  $fields=@(Get-PnPField -List $list.Id -Connection $connection|Where-Object InternalName -eq $fieldName)
  if(-not $fields.Count){
   if($fieldName -eq 'Title'){throw 'Missing built-in Title field.'}
   $null=Add-PnPField -List $list.Id -DisplayName $fieldName -InternalName $fieldName -Type $specs[$fieldName] -Connection $connection
   $fieldsCreated++
  }elseif($fields.Count -ne 1 -or $fields[0].TypeAsString -ne $specs[$fieldName]){throw "Unexpected field type: $fieldName"}
 }
 $null=Set-PnPField -List $list.Id -Identity Title -Values @{Indexed=$true;EnforceUniqueValues=$true;Required=$true} -Connection $connection
 foreach($fieldName in 'SourceRelativePath','AcceptanceJson'){$null=Set-PnPField -List $list.Id -Identity $fieldName -Values @{RichText=$false;AppendOnly=$false} -Connection $connection}
 $title=Get-PnPField -List $list.Id -Identity Title -Connection $connection
 if(-not $title.Indexed -or -not $title.EnforceUniqueValues -or -not $title.Required){throw 'Unique indexed acceptance key was not verified.'}
 $result=[ordered]@{Test='W06B1-AcceptanceLedgerPreparation';Version='0.1.0';Outcome='Prepared';TenantId=$TenantId.ToString();SiteUrl=$web.Url
  AcceptanceListId=$list.Id.ToString();AcceptanceListName=$name;PublisherClientId=$PublisherClientId.ToString();CreatedThisRun=$created
  HasUniqueRoleAssignments=$true;Assignments=$acl;UniqueIndexedKey='Title';FieldsCreatedThisRun=$fieldsCreated
  PublisherEffectiveAccessTested=$false;ReadyForAcceptance=$false;AcceptanceRecordsCreated=0;EndpointOutboxChanged=$false;CertificatesCreated=0
  NextStep='Verify publisher app-only denial on this known-existing list before publishing acceptance.'}
 Write-Host '=== WORK W06B1 PARA COMPARTIR ===' -ForegroundColor Magenta
 Write-Host ($result|ConvertTo-Json -Depth 10) -ForegroundColor Magenta
 [pscustomobject]$result
}finally{if($connection){Disconnect-PnPOnline -ErrorAction SilentlyContinue}}
