<#PSScriptInfo
.VERSION 0.1.0
.GUID e6dd1c57-b33f-44bf-8f5d-42073dad8f3a
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 W03A read-only site/library resolution and selected application grant inspection.
#>
<#
.DESCRIPTION
Administrative GET-only inspection. No certificate access, grant creation, folder creation or uploads.
.NOTES
Version     : 0.1.0
Tracking ID : e6dd1c57-b33f-44bf-8f5d-42073dad8f3a
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][guid]$PublisherClientId,
    [ValidateLength(1,128)][string]$LibraryName='ScannerPortalLanding')
$ErrorActionPreference='Stop'
if($TenantId -eq [guid]::Empty -or $PublisherClientId -eq [guid]::Empty){throw 'Specify tenant and publisher GUIDs.'}
if($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort){throw 'Expected commercial SharePoint site URL.'}
if(-not(Get-Module -ListAvailable Microsoft.Graph.Authentication)){Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force}
Import-Module Microsoft.Graph.Authentication
$script:TargetRequests=0
function Read-TargetGraph([string]$Uri){
    if(-not $Uri.StartsWith('https://graph.microsoft.com/v1.0/',[StringComparison]::Ordinal)){throw 'Unexpected Graph URI.'}
    $script:TargetRequests++
    Invoke-MgGraphRequest -Uri $Uri -Method GET -OutputType Hashtable
}
function Read-TargetPages([string]$Uri){
    $seen=@{}
    while($Uri){
        if($seen.ContainsKey($Uri) -or $seen.Count -ge 100){throw 'Repeated/excessive pagination.'}
        $seen[$Uri]=$true;$page=Read-TargetGraph $Uri
        if(-not $page.ContainsKey('value')){throw 'Expected Graph collection.'}
        foreach($item in $page.value){$item}
        $Uri=$page['@odata.nextLink']
    }
}
Connect-MgGraph -TenantId $TenantId -Scopes Sites.Read.All -ContextScope Process -NoWelcome
try{
    if((Get-MgContext).TenantId -ne $TenantId.ToString()){throw 'Wrong administrative tenant.'}
    $site=Read-TargetGraph ('https://graph.microsoft.com/v1.0/sites/'+$SiteUrl.Host+':'+$SiteUrl.AbsolutePath.TrimEnd('/')+'?$select=id,displayName,webUrl')
    if($site.webUrl.TrimEnd('/') -ne $SiteUrl.AbsoluteUri.TrimEnd('/')){throw 'Resolved site URL differs from requested site.'}
    $lists=@(Read-TargetPages ("https://graph.microsoft.com/v1.0/sites/$($site.id)/lists"+'?$select=id,displayName,webUrl,list,system&$top=100'))
    $libraries=@($lists|Where-Object {$_.list.template -eq 'documentLibrary'})
    $selected=@($libraries|Where-Object displayName -eq $LibraryName)
    if($selected.Count -gt 1){throw 'Ambiguous library display name.'}
    $issues=[Collections.Generic.List[object]]::new()
    $library=$null;$grants=@()
    if($selected.Count -eq 1){
        $list=$selected[0]
        $drive=Read-TargetGraph ("https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$($list.id)/drive"+'?$select=id,name,webUrl')
        $library=[pscustomobject]@{Name=$list.displayName;ListId=$list.id;DriveId=$drive.id;WebUrl=$list.webUrl;Hidden=[bool]$list.list.hidden}
        try{
            $permissions=@(Read-TargetPages "https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$($list.id)/permissions")
            $grants=@(foreach($permission in $permissions){
                if($permission.grantedToV2.application.id -eq $PublisherClientId.ToString()){
                    [pscustomobject]@{PermissionId=$permission.id;ClientId=$permission.grantedToV2.application.id;Roles=@($permission.roles)}
                }
            })
        }catch{
            $status=$null
            if($_.Exception.PSObject.Properties['ResponseStatusCode']){$status=[int]$_.Exception.ResponseStatusCode}
            elseif($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response){$status=[int]$_.Exception.Response.StatusCode}
            $issues.Add([pscustomobject]@{Area='SelectedLibraryPermissions';ErrorType=$_.Exception.GetType().Name;StatusCode=$status})
        }
    }
    $result=[pscustomobject][ordered]@{Test='W03A-SharePointTargetInventory';Version='0.1.0';TenantId=$TenantId.ToString()
        Authentication='DelegatedAdministrativeRead';RequestedScope='Sites.Read.All';RequestMethods='GET only';GraphRequests=$script:TargetRequests
        Site=[pscustomobject]@{SiteId=$site.id;Name=$site.displayName;WebUrl=$site.webUrl}
        RequestedLibrary=$LibraryName;LibraryFound=($selected.Count -eq 1);Library=$library
        AvailableLibraries=@($libraries|ForEach-Object {[pscustomobject]@{Name=$_.displayName;ListId=$_.id;Hidden=[bool]$_.list.hidden}})
        PublisherClientId=$PublisherClientId.ToString();PublisherGrantsAtLibrary=$grants
        LibraryPermissionsInspected=($selected.Count -eq 1 -and $issues.Count -eq 0)
        OrdinaryUserAclReviewed=$false;PublisherEffectiveAccessTested=$false
        SharePointChanged=$false;CertificatesCreated=0;FilesUploaded=0;Issues=$issues.ToArray()
        Outcome=if($selected.Count -eq 0){'LibraryNotFound'}elseif($issues.Count){'Partial'}else{'Inspected'}
    }
    Write-Host '=== WORK W03A PARA COMPARTIR ===' -ForegroundColor Magenta
    Write-Host ($result|ConvertTo-Json -Depth 9) -ForegroundColor Magenta
    $result
}finally{Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}
