<#PSScriptInfo
.VERSION 1.0.1
.GUID a06d345c-ac61-4738-9f16-d75633017a48
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-23 1.0.1 Recognize the explicitly identified existing Landing publisher.
2026-11-20 1.0.0 Shared certificate application, selected library grants, approval and profile publication.
#>
<#
.DESCRIPTION
Administrative portal operations. No private endpoint keys or administrative credentials are distributed.
.NOTES
Version     : 1.0.1
Tracking ID : a06d345c-ac61-4738-9f16-d75633017a48
#>
#Requires -Version 7.4
[CmdletBinding()]
param([ValidateSet('Initialize','Approve','Publish')][string]$Action='Initialize',
    [ValidateSet('Plan','Apply')][string]$Mode='Plan',
    [Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][uri]$SiteUrl,
    [guid]$PortalClientId=[guid]::Empty,[guid]$ClientId=[guid]::Empty,
    [Parameter(Mandatory)][string]$StateDirectory,
    [string]$RequestPath,[string]$ProfilePath,[guid]$RegistrationId=[guid]::Empty,
    [guid]$ExistingLandingPublisherClientId=[guid]::Empty,
    [switch]$AllowSharedIngress)
$ErrorActionPreference='Stop'
$suite=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($TenantId -eq [guid]::Empty -or $SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort) { throw 'Invalid tenant/site.' }
if ($Action -eq 'Initialize' -and -not $AllowSharedIngress) { throw 'Specify AllowSharedIngress: all credentials of this app can read/write the shared landing library.' }
if ($Mode -eq 'Plan') {
    [pscustomobject]@{Action=$Action;TenantId=$TenantId;SiteUrl=$SiteUrl.AbsoluteUri;ApplicationPermission='Lists.SelectedOperations.Selected'
        Config='read';Landing='write';PrivateKeysDistributed=$false;SharedIngressIsolation=$false;RequiresLocalElevation=$false};return
}
function Save-ControlJson($Value,[string]$Path) {
    $temp=$Path+'.tmp'
    [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) {[IO.File]::Replace($temp,$Path,[NullString]::Value)} else {[IO.File]::Move($temp,$Path)}
}
function Graph([string]$Uri,[string]$Method='GET',$Body) {
    if (-not $Uri.StartsWith('https://graph.microsoft.com/v1.0/')) { throw 'Unexpected Graph URI.' }
    $p=@{Uri=$Uri;Method=$Method;OutputType='Hashtable'}
    if ($null -ne $Body) {$p.Body=$Body|ConvertTo-Json -Depth 20;$p.ContentType='application/json'}
    Invoke-MgGraphRequest @p
}
function Put-ControlFile([string]$Drive,[string]$Path,[byte[]]$Bytes,[switch]$Immutable,[string]$ExpectedETag) {
    $uri="https://graph.microsoft.com/v1.0/drives/$Drive/root:/${Path}:/content"
    if ($Immutable) {
        # conflictBehavior=fail prevents replacing an already published profile.
        $uri+='?@microsoft.graph.conflictBehavior=fail'
    }
    $headers=@{}
    if($ExpectedETag){$headers['If-Match']=$ExpectedETag}
    Invoke-MgGraphRequest -Uri $uri -Method PUT -Body $Bytes -ContentType 'application/json' -Headers $headers -OutputType Hashtable
}
function Ensure-ControlFolder([string]$Drive,[string]$Parent,[string]$Name) {
    $base=if($Parent -eq 'root'){"https://graph.microsoft.com/v1.0/drives/$Drive/root"}else{"https://graph.microsoft.com/v1.0/drives/$Drive/items/$Parent"}
    $uri="${base}:/$Name"
    try {$folder=Graph $uri} catch {
        if ([int]$_.Exception.Response.StatusCode -ne 404) {throw}
        $folder=Graph "$base/children" POST @{name=$Name;folder=@{};'@microsoft.graph.conflictBehavior'='fail'}
    }
    if (-not $folder.ContainsKey('folder')) {throw 'Expected configuration folder.'};$folder.id
}
function Assert-ControlAcl($List,$Connection,[string]$LibraryName) {
    if (-not (Get-PnPProperty -ClientObject $List -Property HasUniqueRoleAssignments -Connection $Connection)) {throw 'Library inherits access. Review permissions first.'}
    $admins=@(Get-PnPSiteCollectionAdmin -Connection $Connection|ForEach-Object {$_.LoginName.ToLowerInvariant()})
    $null=Get-PnPProperty -ClientObject $List -Property RoleAssignments -Connection $Connection
    foreach($assignment in $List.RoleAssignments) {
        $null=Get-PnPProperty -ClientObject $assignment -Property RoleDefinitionBindings -Connection $Connection
        $roles=@(foreach($roleBinding in $assignment.RoleDefinitionBindings) {
            $null=Get-PnPProperty -ClientObject $roleBinding -Property RoleTypeKind -Connection $Connection
            if ([int]$roleBinding.RoleTypeKind -ne 1) { [int]$roleBinding.RoleTypeKind }
        })
        if ($roles.Count -eq 0) {continue}
        $member=Get-PnPProperty -ClientObject $assignment -Property Member -Connection $Connection
        $null=Get-PnPProperty -ClientObject $member -Property LoginName,Title,PrincipalType -Connection $Connection
        if ($script:AllowedControlApp -and $member.LoginName -match ('(^|\|)'+[regex]::Escape($script:AllowedControlApp)+'@')) {continue}
        $publisherLogin="i:0i.t|ms.sp.ext|$ExistingLandingPublisherClientId@$TenantId"
        if ($LibraryName -eq 'ScannerPortalLanding' -and $ExistingLandingPublisherClientId -ne [guid]::Empty -and
            $member.LoginName -eq $publisherLogin -and $roles.Count -eq 1 -and $roles[0] -eq 3) {continue}

        $members=if ([string]$member.PrincipalType -eq 'SharePointGroup') {@(Get-PnPGroupMember -Group $member.Id -Connection $Connection)} else {@($member)}
        foreach($m in $members) {if ($m.LoginName.ToLowerInvariant() -notin $admins) {throw "Unexpected library principal: $($m.Title)"}}
    }
}
[void][IO.Directory]::CreateDirectory($StateDirectory)
$StateDirectory=[IO.Path]::GetFullPath($StateDirectory)
$lock=[IO.File]::Open((Join-Path $StateDirectory 'controlplane.lock'),'OpenOrCreate','ReadWrite','None')
$connection=$null
try {
    $statePath=Join-Path $StateDirectory 'controlplane.json'
    $state=if(Test-Path -LiteralPath $statePath) {Get-Content -LiteralPath $statePath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable} else {@{tenantId=$TenantId.ToString();siteUrl=$SiteUrl.AbsoluteUri.TrimEnd('/')}}
    if ($state.tenantId -ne $TenantId.ToString() -or $state.siteUrl -ne $SiteUrl.AbsoluteUri.TrimEnd('/')) {throw 'Saved portal registration differs.'}
    foreach($name in 'Microsoft.Graph.Authentication','Microsoft.Graph.Applications') {
        if (-not(Get-Module -ListAvailable $name)) {Install-Module $name -Scope CurrentUser -Force -Repository PSGallery}
    }
    Import-Module Microsoft.Graph.Authentication,Microsoft.Graph.Applications
    Connect-MgGraph -TenantId $TenantId -Scopes Application.ReadWrite.All,AppRoleAssignment.ReadWrite.All,Sites.FullControl.All -NoWelcome
    if ((Get-MgContext).TenantId -ne $TenantId.ToString()) {throw 'Wrong Graph tenant.'}
    if ($Action -eq 'Initialize') {
        if ($PortalClientId -eq [guid]::Empty) {throw 'Specify the existing portal administrative Client ID.'}
        if (-not(Get-Module -ListAvailable PnP.PowerShell|Where-Object Version -eq ([version]'3.2.0'))) {Install-Module PnP.PowerShell -RequiredVersion 3.2.0 -Scope CurrentUser -Force -Repository PSGallery}
        Import-Module PnP.PowerShell -RequiredVersion 3.2.0
        $connection=Connect-PnPOnline -Url $state.siteUrl -Tenant $TenantId -ClientId $PortalClientId -Interactive -ReturnConnection
        if ($state.clientId) {if($ClientId -ne [guid]::Empty -and $ClientId.ToString() -ne $state.clientId){throw 'Conflicting client ID.'};$ClientId=[guid]$state.clientId}
        $script:AllowedControlApp=if($ClientId -ne [guid]::Empty){$ClientId.ToString()}else{''}
        $libraries=@{}
        foreach($name in 'ScannerPortalConfig','ScannerPortalLanding') {
            $list=Get-PnPList -Identity $name -Includes RootFolder,HasUniqueRoleAssignments -Connection $connection
            if ([int]$list.BaseTemplate -ne 101) {throw 'Expected Foundation document library.'}
            Assert-ControlAcl $list $connection $name
            $libraries[$name]=$list.Id.ToString()
        }
        $graphSp=@(Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'")[0]
        $role=@($graphSp.AppRoles|Where-Object {$_.Value -eq 'Lists.SelectedOperations.Selected' -and $_.IsEnabled -and 'Application' -in $_.AllowedMemberTypes})
        if ($role.Count -ne 1) {throw 'Selected application permission unavailable.'}
        $display='Kaz Demos ScannerPortal Endpoints'
        if ($ClientId -eq [guid]::Empty) {
            if (@(Get-MgApplication -Filter "displayName eq '$display'").Count) {throw 'App already exists: specify ClientId to adopt explicitly.'}
            $app=New-MgApplication -DisplayName $display -SignInAudience AzureADMyOrg
            $ClientId=[guid]$app.AppId
            $state.clientId=$ClientId.ToString();Save-ControlJson $state $statePath
        }
        $apps=@(Get-MgApplication -Filter "appId eq '$ClientId'" -Property Id,AppId,DisplayName,RequiredResourceAccess)
        if ($apps.Count -ne 1 -or $apps[0].DisplayName -ne $display) {throw 'Use a dedicated portal endpoint application, not the MIP or administrative app.'}
        $app=$apps[0]
        foreach($resource in $app.RequiredResourceAccess) {
            if ($resource.ResourceAppId -ne $graphSp.AppId -or @($resource.ResourceAccess|Where-Object {$_.Id -ne $role[0].Id -or $_.Type -ne 'Role'}).Count) {throw 'Unexpected API permissions on endpoint app.'}
        }
        Update-MgApplication -ApplicationId $app.Id -RequiredResourceAccess @(@{resourceAppId=$graphSp.AppId;resourceAccess=@(@{id=$role[0].Id;type='Role'})})
        $principals=@(Get-MgServicePrincipal -Filter "appId eq '$ClientId'")
        if($principals.Count -eq 0){$principals=@(New-MgServicePrincipal -AppId $ClientId)}
        $sp=$principals[0]
        $assigned=@(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All)
        if (@($assigned|Where-Object {$_.ResourceId -ne $graphSp.Id -or $_.AppRoleId -ne $role[0].Id}).Count) {throw 'Unexpected effective API grants.'}
        if(-not @($assigned|Where-Object AppRoleId -eq $role[0].Id).Count) {$null=New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graphSp.Id -AppRoleId $role[0].Id}
        $logo=Join-Path $suite 'labs/MipSdkAudit/kaz-demos-entra-215.png'
        if(Test-Path -LiteralPath $logo){Set-MgApplicationLogo -ApplicationId $app.Id -InFile $logo}else{Write-Warning 'Branding logo missing; enrollment can continue without updating it.'}
        $site=Graph ('https://graph.microsoft.com/v1.0/sites/'+$SiteUrl.Host+':'+$SiteUrl.AbsolutePath.TrimEnd('/'))
        $bootstrap=@{schemaVersion=1;tenantId=$TenantId.ToString();clientId=$ClientId.ToString();siteUrl=$state.siteUrl;sharedIdentity=$true}
        foreach($name in 'ScannerPortalConfig','ScannerPortalLanding') {
            $id=$libraries[$name];$roleName=if($name -eq 'ScannerPortalConfig'){'read'}else{'write'}
            $uri="https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$id/permissions"
            $page=Graph $uri;$permissions=@($page.value)
            while($page['@odata.nextLink']) {$page=Graph $page['@odata.nextLink'];$permissions+=@($page.value)}
            $grants=@($permissions|Where-Object {$_.grantedToV2.application.id -eq $ClientId.ToString()})
            if($grants.Count -eq 0){$grants=@(Graph $uri POST @{roles=@($roleName);grantedToV2=@{application=@{id=$ClientId.ToString();displayName=$display}}})}
            if($grants.Count -ne 1 -or @($grants[0].roles).Count -ne 1 -or $grants[0].roles[0] -ne $roleName){throw 'Unexpected library grant.'}
            $drive=Graph "https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$id/drive"
            if($name -eq 'ScannerPortalConfig'){$bootstrap.configDriveId=$drive.id}else{$bootstrap.landingDriveId=$drive.id}
        }
        $state.clientId=$ClientId.ToString();$state.appObjectId=$app.Id;$state.bootstrap=$bootstrap
        Save-ControlJson $state $statePath
        Save-ControlJson $bootstrap (Join-Path $StateDirectory 'endpoint-bootstrap.json')
        $result=@{action=$Action;clientId=$ClientId.ToString();bootstrapPath=(Join-Path $StateDirectory 'endpoint-bootstrap.json');sharedIngressIsolation=$false;privateKeyDistributed=$false}
    } else {
        if(-not $state.bootstrap -or -not $state.appObjectId){throw 'Initialize the control plane first.'}
        if($Action -eq 'Approve') {
            if(-not $RequestPath -or (Get-Item -LiteralPath $RequestPath).Length -gt 32KB){throw 'Expected a small public enrollment request.'}
            $request=Get-Content -LiteralPath $RequestPath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable
            if($request.schemaVersion -ne 1 -or $request.tenantId -ne $state.tenantId -or $request.clientId -ne $state.clientId -or [guid]$request.registrationId -eq [guid]::Empty){throw 'Enrollment request identity mismatch.'}
            $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($request.certificate))
            $rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
            try {if($cert.HasPrivateKey -or -not $rsa -or $rsa.KeySize -lt 2048 -or $cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date).AddDays(1) -or $cert.NotAfter -gt (Get-Date).AddDays(367)){throw 'Invalid public enrollment certificate.'}}finally{if($rsa){$rsa.Dispose()}}
            $app=Get-MgApplication -ApplicationId $state.appObjectId -Property Id,KeyCredentials
            $credentials=@($app.KeyCredentials|Where-Object {$null -ne $_})
            if(-not @($credentials|Where-Object {$_.CustomKeyIdentifier -and [Convert]::ToBase64String($_.CustomKeyIdentifier) -eq [Convert]::ToBase64String($cert.GetCertHash())}).Count){
                foreach($key in $credentials){if(-not $key.Key){throw 'Existing public key could not be read; refusing destructive certificate replacement.'}}
                $credentials+=@{type='AsymmetricX509Cert';usage='Verify';key=$cert.RawData;displayName=('Endpoint '+$request.registrationId);startDateTime=$cert.NotBefore.ToUniversalTime();endDateTime=$cert.NotAfter.ToUniversalTime()}
                Update-MgApplication -ApplicationId $app.Id -KeyCredentials $credentials
            }
            Save-ControlJson @{registrationId=$request.registrationId;deviceName=$request.deviceName;thumbprint=$cert.Thumbprint;approvedUtc=[datetime]::UtcNow.ToString('o');identityAssurance='OperatorApprovedPublicRequest'} (Join-Path $StateDirectory ($request.registrationId+'.approved.json'))
            $result=@{action=$Action;registrationId=$request.registrationId;thumbprint=$cert.Thumbprint;privateKeyReceived=$false;assignmentRequired=$true}
        } else {
            if($RegistrationId -eq [guid]::Empty -or -not(Test-Path -LiteralPath (Join-Path $StateDirectory ($RegistrationId.ToString()+'.approved.json')))){throw 'Approve the endpoint registration first.'}
            # Validation must use the actual PS5.1 scanner, not PS7 JSON/integer behavior.
            $winps=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
            & $winps -NoProfile -File (Join-Path $PSScriptRoot '../tests/Test-ScannerPortalProfile.ps1') -ProfilePath $ProfilePath
            if($LASTEXITCODE -ne 0){throw 'Profile validation failed.'}
            $profile=Get-Content -LiteralPath $ProfilePath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable
            $bytes=[IO.File]::ReadAllBytes((Get-Item -LiteralPath $ProfilePath).FullName)
            $hash=(Get-FileHash -LiteralPath $ProfilePath -Algorithm SHA256).Hash
            $drive=$state.bootstrap.configDriveId
            $parent='root'
            foreach($part in @('profiles',$profile.profileId,$profile.version)){$parent=Ensure-ControlFolder $drive $parent $part}
            $siblings=Graph "https://graph.microsoft.com/v1.0/drives/$drive/items/$parent/children"
            do {
                if(@($siblings.value|Where-Object {$_.name -ne ($hash+'.json')}).Count){throw 'Profile version already contains different content; increment version.'}
                $next=$siblings['@odata.nextLink']
                if($next){$siblings=Graph $next}
            } while($next)
            $path='profiles/'+$profile.profileId+'/'+$profile.version+'/'+$hash+'.json'
            $existing=$null
            try{$existing=Graph "https://graph.microsoft.com/v1.0/drives/$drive/root:/${path}"}catch{if([int]$_.Exception.Response.StatusCode -ne 404){throw}}
            if(-not $existing){$null=Put-ControlFile $drive $path $bytes -Immutable}
            $null=Ensure-ControlFolder $drive 'root' 'assignments'
            $assignment=@{schemaVersion=1;registrationId=$RegistrationId.ToString();profilePath=$path;sha256=$hash}
            $assignmentPath='assignments/'+$RegistrationId.ToString()+'.json'
            $oldAssignment=$null
            try{$oldAssignment=Graph "https://graph.microsoft.com/v1.0/drives/$drive/root:/${assignmentPath}"}catch{if([int]$_.Exception.Response.StatusCode -ne 404){throw}}
            $etag=if($oldAssignment){$oldAssignment.eTag}else{''}
            if($oldAssignment -and -not $etag){throw 'Assignment ETag missing; cannot safely replace it.'}
            $null=Put-ControlFile $drive $assignmentPath ([Text.Encoding]::UTF8.GetBytes(($assignment|ConvertTo-Json))) -ExpectedETag $etag -Immutable:(-not $oldAssignment)
            $result=@{action=$Action;registrationId=$RegistrationId.ToString();profileId=$profile.profileId;profileVersion=$profile.version;sha256=$hash}
        }
    }
    Write-Host '=== PORTAL CONTROL PLANE PARA COMPARTIR ===' -ForegroundColor Magenta
    Write-Host ($result|ConvertTo-Json -Depth 6) -ForegroundColor Magenta
    [pscustomobject]$result
} finally {
    if($connection){Disconnect-PnPOnline -ErrorAction SilentlyContinue}
    if(Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue){Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}
    $lock.Dispose()
}
