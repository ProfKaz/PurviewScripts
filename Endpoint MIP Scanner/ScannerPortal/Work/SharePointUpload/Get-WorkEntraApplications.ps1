<#PSScriptInfo
.VERSION 0.1.0
.GUID 49b41718-3711-4773-aed5-10ae37b1cf9f
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 W02A administrative application inventory using GET requests only.
#>
<#
.DESCRIPTION
Uses delegated administrative read access to discover existing identities. Does not authenticate the endpoint app or access SharePoint.
.NOTES
Version     : 0.1.0
Tracking ID : 49b41718-3711-4773-aed5-10ae37b1cf9f
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,
    [guid[]]$KnownClientId=@(),
    [ValidateLength(1,128)][string]$NamePattern='scanner|localmip|purview|kaz demos')
$ErrorActionPreference='Stop'
if($TenantId -eq [guid]::Empty){throw 'Specify the laboratory tenant GUID.'}
if(-not(Get-Module -ListAvailable Microsoft.Graph.Authentication)){
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force
}
Import-Module Microsoft.Graph.Authentication
$script:WorkRequests=0
$script:WorkResources=@{}
function Read-WorkGraph([string]$Uri){
    if(-not $Uri.StartsWith('https://graph.microsoft.com/v1.0/',[StringComparison]::Ordinal)){throw 'Unexpected Graph pagination/resource host.'}
    $script:WorkRequests++
    Invoke-MgGraphRequest -Uri $Uri -Method GET -OutputType Hashtable
}
function Read-WorkPages([string]$Uri){
    $seen=@{}
    while($Uri){
        if($seen.ContainsKey($Uri) -or $seen.Count -ge 100){throw 'Repeated or excessive pagination.'}
        $seen[$Uri]=$true
        $page=Read-WorkGraph $Uri
        if(-not $page.ContainsKey('value')){throw 'Graph collection did not return value.'}
        foreach($item in $page.value){$item}
        $Uri=$page['@odata.nextLink']
    }
}
function Get-WorkResource([guid]$ObjectId=[guid]::Empty,[guid]$AppId=[guid]::Empty){
    $key=if($ObjectId -ne [guid]::Empty){$ObjectId.ToString()}else{$AppId.ToString()}
    if($script:WorkResources.ContainsKey($key)){return $script:WorkResources[$key]}
    $select='id,appId,displayName,appRoles,oauth2PermissionScopes'
    if($ObjectId -ne [guid]::Empty){$resource=Read-WorkGraph ("https://graph.microsoft.com/v1.0/servicePrincipals/$ObjectId"+'?$select='+$select)}
    else {
        $matches=@(Read-WorkPages ("https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'$AppId'&`$select=$select"))
        if($matches.Count -ne 1){throw 'Resource service principal is missing or ambiguous.'}
        $resource=$matches[0]
    }
    $script:WorkResources[$resource.id]=$resource;$script:WorkResources[$resource.appId]=$resource
    return $resource
}
$issues=[Collections.Generic.List[object]]::new()
Connect-MgGraph -TenantId $TenantId -Scopes Application.Read.All -ContextScope Process -NoWelcome
try{
    $context=Get-MgContext
    if($context.TenantId -ne $TenantId.ToString()){throw 'Wrong tenant session.'}
    $all=@(Read-WorkPages 'https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName&$top=100')
    $candidates=@($all|Where-Object {$_.displayName -match $NamePattern -or $_.appId -in @($KnownClientId|ForEach-Object {$_.ToString()})})
    if($candidates.Count -gt 50){throw 'More than 50 candidates. Narrow NamePattern before continuing.'}
    $applications=@(foreach($candidate in $candidates){
        try{
            $id=[guid]$candidate.id
            $app=Read-WorkGraph ("https://graph.microsoft.com/v1.0/applications/$id"+'?$select=id,appId,displayName,keyCredentials,requiredResourceAccess')
            $declared=@(foreach($api in $app.requiredResourceAccess){
                $resource=Get-WorkResource -AppId ([guid]$api.resourceAppId)
                foreach($permission in $api.resourceAccess){
                    $definitions=if($permission.type -eq 'Role'){@($resource.appRoles)}else{@($resource.oauth2PermissionScopes)}
                    $resolved=@($definitions|Where-Object id -eq $permission.id)
                    [pscustomobject]@{Api=$resource.displayName;Type=$permission.type;Permission=if($resolved.Count -eq 1){$resolved[0].value}else{$permission.id}}
                }
            })
            $principals=@(Read-WorkPages ("https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'$($app.appId)'&`$select=id,appId,displayName"))
            if($principals.Count -gt 1){throw 'Ambiguous application service principal.'}
            $effective=@(if($principals.Count -eq 1){
                foreach($grant in @(Read-WorkPages ("https://graph.microsoft.com/v1.0/servicePrincipals/$($principals[0].id)/appRoleAssignments"+'?$select=resourceId,appRoleId'))){
                    $resource=Get-WorkResource -ObjectId ([guid]$grant.resourceId)
                    $role=@($resource.appRoles|Where-Object id -eq $grant.appRoleId)
                    [pscustomobject]@{Api=$resource.displayName;Permission=if($role.Count -eq 1){$role[0].value}else{$grant.appRoleId}}
                }
            })
            $certificates=@(foreach($key in $app.keyCredentials){
                [pscustomobject]@{KeyId=$key.keyId;Type=$key.type;Usage=$key.usage;ExpiresUtc=$key.endDateTime}
            })
            [pscustomobject]@{DisplayName=$app.displayName;ClientId=$app.appId;AppObjectId=$app.id
                ServicePrincipalId=if($principals.Count -eq 1){$principals[0].id}else{$null}
                DeclaredApiPermissions=$declared;EffectiveApplicationPermissions=$effective
                RegisteredCertificateCount=$certificates.Count;CertificateMetadata=$certificates
                PrivateKeyAvailability='NotTested';SharePointResourceGrants='NotTested'}
        }catch{$issues.Add([pscustomobject]@{ClientId=$candidate.appId;ErrorType=$_.Exception.GetType().Name})}
    })
    $result=[pscustomobject][ordered]@{Test='W02A-EntraApplicationInventory';Version='0.1.0';TenantId=$TenantId.ToString()
        Authentication='DelegatedAdministrativeRead';DirectoryRequests='GET only';RequestedScope='Application.Read.All'
        GraphRequests=$script:WorkRequests;Applications=$applications
        KnownClientIdsWithoutLocalAppRegistration=@($KnownClientId|Where-Object {$_.ToString() -notin @($all.appId)}|ForEach-Object {$_.ToString()})
        Issues=$issues.ToArray();Complete=($issues.Count -eq 0)
        CertificatesCreated=0;ApplicationConfigurationChanged=$false;EndpointAuthenticationTested=$false;SharePointAccessTested=$false}
    Write-Host '=== WORK W02A PARA COMPARTIR ===' -ForegroundColor Magenta
    Write-Host ($result|ConvertTo-Json -Depth 10) -ForegroundColor Magenta
    $result
}finally{Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}
