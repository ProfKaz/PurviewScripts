<#PSScriptInfo
.VERSION 0.1.0
.GUID d3e93c72-040d-43f7-b85b-5a1b70792614
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 W03B explicit selected-library write grant with readback and safe reuse.
#>
<#
.DESCRIPTION
Plan by default. Apply grants only the dedicated Work publisher write on the existing ScannerPortalLanding library.
.NOTES
Version     : 0.1.0
Tracking ID : d3e93c72-040d-43f7-b85b-5a1b70792614
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][guid]$ListId,[Parameter(Mandatory)][guid]$PublisherClientId,[switch]$Apply)
$ErrorActionPreference='Stop'
if($TenantId -eq [guid]::Empty -or $ListId -eq [guid]::Empty -or $PublisherClientId -eq [guid]::Empty){throw 'Specify nonempty tenant, list and client GUIDs.'}
if($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort){throw 'Expected commercial SharePoint site URL.'}
if(-not(Get-Module -ListAvailable Microsoft.Graph.Authentication)){Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force}
Import-Module Microsoft.Graph.Authentication
function Grant-Graph([string]$Uri,[string]$Method='GET',$Body){
    if(-not $Uri.StartsWith('https://graph.microsoft.com/v1.0/',[StringComparison]::Ordinal)){throw 'Unexpected Graph URI.'}
    if($Method -ne 'GET' -and ($Method -ne 'POST' -or -not $Apply -or $Uri -cne $script:GrantUri)){throw 'Unexpected write operation.'}
    $parameters=@{Uri=$Uri;Method=$Method;OutputType='Hashtable'}
    if($null -ne $Body){$parameters.Body=$Body|ConvertTo-Json -Depth 8;$parameters.ContentType='application/json'}
    Invoke-MgGraphRequest @parameters
}
function Grant-Pages([string]$Uri){
    $seen=@{}
    while($Uri){
        if($seen.ContainsKey($Uri) -or $seen.Count -ge 100){throw 'Unexpected pagination.'}
        $seen[$Uri]=$true;$page=Grant-Graph $Uri
        foreach($item in $page.value){$item};$Uri=$page['@odata.nextLink']
    }
}
function Assert-ExpectedGrant($Grant){
    if(@($Grant.roles).Count -ne 1 -or $Grant.roles[0] -ne 'write' -or $Grant.grantedToV2.application.id -ne $PublisherClientId.ToString()){
        throw 'Unexpected existing grant; no permissions updated or removed.'
    }
}
$siteScope=if($Apply){'Sites.ReadWrite.All'}else{'Sites.Read.All'}
Connect-MgGraph -TenantId $TenantId -Scopes Application.Read.All,$siteScope -ContextScope Process -NoWelcome
try{
    if((Get-MgContext).TenantId -ne $TenantId.ToString()){throw 'Wrong administrative tenant.'}
    $apps=@(Grant-Pages "https://graph.microsoft.com/v1.0/applications?`$filter=appId%20eq%20'$PublisherClientId'&`$select=id,appId,displayName")
    if($apps.Count -ne 1 -or $apps[0].displayName -ne 'Kaz Demos Scanner Publisher - Work'){throw 'Use the dedicated Work publisher, not MIP/Setup or another app.'}
    $site=Grant-Graph ('https://graph.microsoft.com/v1.0/sites/'+$SiteUrl.Host+':'+$SiteUrl.AbsolutePath.TrimEnd('/')+'?$select=id,webUrl')
    if($site.webUrl.TrimEnd('/') -ne $SiteUrl.AbsoluteUri.TrimEnd('/')){throw 'Resolved site differs from requested site.'}
    $list=Grant-Graph ("https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$ListId"+'?$select=id,displayName,webUrl,list')
    if($list.displayName -ne 'ScannerPortalLanding' -or $list.list.template -ne 'documentLibrary' -or [guid]$list.id -ne $ListId){throw 'Expected the existing ScannerPortalLanding document library.'}
    $drive=Grant-Graph ("https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$ListId/drive"+'?$select=id,name')
    $script:GrantUri="https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$ListId/permissions"
    $grants=@(Grant-Pages $script:GrantUri|Where-Object {$_.grantedToV2.application.id -eq $PublisherClientId.ToString()})
    if($grants.Count -gt 1){throw 'Duplicate application grants; review before changing access.'}
    $created=$false
    if($grants.Count -eq 1){Assert-ExpectedGrant $grants[0]}
    elseif($Apply){
        try{
            $null=Grant-Graph $script:GrantUri POST @{grantedToV2=@{application=@{id=$PublisherClientId.ToString();displayName=$apps[0].displayName}};roles=@('write')}
            $created=$true
        }catch{
            $status=if($_.Exception.PSObject.Properties['ResponseStatusCode']){[int]$_.Exception.ResponseStatusCode}elseif($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response){[int]$_.Exception.Response.StatusCode}else{0}
            if($status -ne 409){throw}
        }
        # Only repeat the read on propagation delay; never blindly repeat grant creation.
        for($attempt=0;$attempt -lt 4;$attempt++){
            $grants=@(Grant-Pages $script:GrantUri|Where-Object {$_.grantedToV2.application.id -eq $PublisherClientId.ToString()})
            if($grants.Count){break}
            if($attempt -lt 3){Start-Sleep -Seconds 2}
        }
        if($grants.Count -ne 1){throw 'Grant was not confirmed by readback. Rerun to inspect/reuse; no automatic deletion.'}
        Assert-ExpectedGrant $grants[0]
    }
    $verified=($grants.Count -eq 1)
    $result=[pscustomobject][ordered]@{Test='W03B-SelectedLibraryGrant';Version='0.1.0';Mode=if($Apply){'Apply'}else{'Plan'}
        Outcome=if($verified){'Verified'}else{'GrantRequired'};TenantId=$TenantId.ToString();SiteId=$site.id;SiteUrl=$site.webUrl
        LibraryName=$list.displayName;ListId=$ListId.ToString();DriveId=$drive.id;PublisherClientId=$PublisherClientId.ToString()
        GrantedRole=if($verified){'write'}else{$null};PermissionId=if($verified){$grants[0].id}else{$null}
        GrantCreatedThisRun=$created;GrantReadBackVerified=$verified;OrdinaryUserAclReviewed=$false
        PublisherEffectiveAccessTested=$false;CertificatesCreated=0;FilesUploaded=0}
    Write-Host '=== WORK W03B PARA COMPARTIR ===' -ForegroundColor Magenta
    Write-Host ($result|ConvertTo-Json -Depth 6) -ForegroundColor Magenta
    $result
}finally{Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}
