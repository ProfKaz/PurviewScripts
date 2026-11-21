<#PSScriptInfo
.VERSION 0.4.0
.GUID 93b41e48-1698-483c-9a57-986b9b387239
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.4.0 Prepare an empty per-device/per-batch target before ACL review; no real payload reads/uploads.
2026-11-20 0.3.0 W04 synthetic marker upload, retry without overwrite and downloaded SHA-256 verification.
2026-11-20 0.2.0 W03C app-only metadata reads and denied access to a known ungranted list.
2026-11-20 0.1.0 W02B single pilot certificate/app preparation and separate app-only token test.
#>
<#
.DESCRIPTION
Standalone shared publisher pilot. Prepare sets up the identity; Authenticate/TestAccess read only; UploadProbe writes only a generated synthetic marker.
.NOTES
Version     : 0.4.0
Tracking ID : 93b41e48-1698-483c-9a57-986b9b387239
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,
    [ValidateSet('Prepare','Authenticate','TestAccess','UploadProbe','PrepareBatchTarget')][string]$Step='Authenticate',
    [string]$StateDirectory=(Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/Work/SharedPublisher'),
    [guid]$ClientId=[guid]::Empty,
    [switch]$AllowCertificateExport,
    [string]$SiteId,[guid]$ListId=[guid]::Empty,[string]$DriveId,
    [guid]$ControlListId=[guid]::Empty,[guid]$ProbeId=[guid]::Empty,
    [string]$BatchId,[string]$ExpectedManifestSha256)
$ErrorActionPreference='Stop'
if($TenantId -eq [guid]::Empty){throw 'Specify a tenant GUID.'}
if($Step -eq 'PrepareBatchTarget' -and ($BatchId -cnotmatch '^[A-F0-9]{64}$' -or $ExpectedManifestSha256 -cnotmatch '^[A-F0-9]{64}$')){throw 'Supply the exact verified uppercase batch ID and original manifest SHA-256.'}
if($Step -in 'TestAccess','UploadProbe','PrepareBatchTarget'){
    $siteParts=$SiteId.Split(',')
    if($siteParts.Count -ne 3 -or $siteParts[0] -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
        [guid]$siteParts[1] -eq [guid]::Empty -or [guid]$siteParts[2] -eq [guid]::Empty -or
        $ListId -eq [guid]::Empty -or $ControlListId -eq [guid]::Empty -or $ControlListId -eq $ListId -or
        $DriveId -notmatch '^[A-Za-z0-9_!.,-]{1,256}$'){throw 'Access/probe steps require validated site/list/drive IDs and a different known-existing control list.'}
}
$StateDirectory=[IO.Path]::GetFullPath($StateDirectory)
for($parent=[IO.DirectoryInfo]::new($StateDirectory);$parent;$parent=$parent.Parent){
    if($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse state directory.'}
}
[void][IO.Directory]::CreateDirectory($StateDirectory)
$lock=[IO.File]::Open((Join-Path $StateDirectory 'writer.lock'),'OpenOrCreate','ReadWrite','None')
$statePath=Join-Path $StateDirectory 'publisher.json'
$displayName='Kaz Demos Scanner Publisher - Work'
$permission='Lists.SelectedOperations.Selected'
$connected=$false
function Save-SharedState {
    $temp=$statePath+'.tmp'
    [IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($statePath)){[IO.File]::Replace($temp,$statePath,[NullString]::Value)}else{[IO.File]::Move($temp,$statePath)}
}
function Shared-Graph([string]$Uri,[string]$Method='GET',$Body){
    if(-not $Uri.StartsWith('https://graph.microsoft.com/v1.0/',[StringComparison]::Ordinal)){throw 'Unexpected Graph URI.'}
    $parameters=@{Uri=$Uri;Method=$Method;OutputType='Hashtable'}
    if($null -ne $Body){$parameters.Body=$Body|ConvertTo-Json -Depth 12;$parameters.ContentType='application/json'}
    Invoke-MgGraphRequest @parameters
}
function Shared-Pages([string]$Uri){
    $seen=@{}
    while($Uri){
        if($seen.ContainsKey($Uri) -or $seen.Count -ge 100){throw 'Unexpected pagination.'}
        $seen[$Uri]=$true;$page=Shared-Graph $Uri
        foreach($item in $page.value){$item}
        $Uri=$page['@odata.nextLink']
    }
}
function Shared-Base64Url([byte[]]$Bytes){[Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')}
function Shared-HttpStatus($ErrorRecord){
    if($ErrorRecord.Exception.PSObject.Properties['ResponseStatusCode']){return [int]$ErrorRecord.Exception.ResponseStatusCode}
    if($ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response){return [int]$ErrorRecord.Exception.Response.StatusCode}
    return 0
}
function Shared-ProbeFolder([string]$ParentId,[string]$Name,$Headers){
    if($ParentId -notmatch '^[A-Za-z0-9_!.,-]{1,256}$' -or $Name -notmatch '^[a-z0-9-]{1,64}$'){throw 'Unsafe probe folder segment.'}
    $uri="https://graph.microsoft.com/v1.0/drives/$DriveId/items/${ParentId}:/$Name"
    try{$folder=Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers}
    catch{
        if((Shared-HttpStatus $_) -ne 404){throw}
        try{
            $body=@{name=$Name;folder=@{};'@microsoft.graph.conflictBehavior'='fail'}|ConvertTo-Json -Compress
            $folder=Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ParentId/children" -Method POST -Headers $Headers -ContentType 'application/json' -Body $body
            $script:ProbeFoldersCreated++
        }catch{
            if((Shared-HttpStatus $_) -ne 409){throw}
            $folder=Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers
        }
    }
    if($null -eq $folder.folder -or $folder.name -ne $Name -or $folder.id -notmatch '^[A-Za-z0-9_!.,-]{1,256}$'){throw 'Probe path identifies an unexpected item.'}
    return $folder
}
function Shared-ProbeUpload($Root,$List,$Headers){
    if($ProbeId -eq [guid]::Empty){
        if($state.lastProbeId){
            if($state.lastProbeSiteId -ne $SiteId -or $state.lastProbeListId -ne $ListId.ToString() -or $state.lastProbeDriveId -cne $DriveId){throw 'Last probe belongs to another target; select an explicit new ProbeId.'}
            $ProbeId=[guid]$state.lastProbeId
        }else{$ProbeId=[guid]::NewGuid()}
    }
    if($ProbeId -eq [guid]::Empty){throw 'Invalid probe ID.'}
    $state.lastProbeId=$ProbeId.ToString();$state.lastProbeSiteId=$SiteId;$state.lastProbeListId=$ListId.ToString();$state.lastProbeDriveId=$DriveId
    Save-SharedState
    $payload=[ordered]@{kind='SyntheticTransportProbe';probeId=$ProbeId.ToString();tenantId=$TenantId.ToString();clientId=$ClientId.ToString();message='Synthetic transport test. No endpoint inventory.'}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($payload|ConvertTo-Json -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$expected=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
    $script:ProbeFoldersCreated=0
    $parent=$Root
    foreach($segment in @('work-pilot','probes',$ProbeId.ToString('N'))){$parent=Shared-ProbeFolder $parent.id $segment $Headers}
    $markerUri="https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($parent.id):/marker.json"
    $uploaded=$false;$exists=$true
    try{$marker=Invoke-RestMethod -Uri $markerUri -Method GET -Headers $Headers}
    catch{if((Shared-HttpStatus $_) -ne 404){throw};$exists=$false}
    if(-not $exists){
        try{
            $null=Invoke-RestMethod -Uri ($markerUri+':/content?@microsoft.graph.conflictBehavior=fail') -Method PUT -Headers $Headers -ContentType 'application/json' -Body $bytes
            $uploaded=$true
        }catch{if((Shared-HttpStatus $_) -ne 409){throw}}
        $marker=Invoke-RestMethod -Uri $markerUri -Method GET -Headers $Headers
    }
    if(-not $marker.id -or $null -eq $marker.file -or $marker.name -ne 'marker.json' -or [long]$marker.size -ne $bytes.Length){throw 'Unexpected remote marker metadata; no overwrite or deletion.'}
    if($marker.parentReference.id -and $marker.parentReference.id -cne $parent.id){throw 'Marker identifies another parent folder.'}
    $url=[uri]$marker.'@microsoft.graph.downloadUrl'
    if(-not $url.IsAbsoluteUri -or $url.Scheme -ne 'https' -or $url.UserInfo -or -not $url.IsDefaultPort){throw 'Invalid preauthenticated download URL.'}
    $temp=Join-Path $StateDirectory ('probe-download-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        # The Graph bearer token must not be sent to this preauthenticated URL.
        try{$null=Invoke-WebRequest -Uri $url.AbsoluteUri -Method GET -OutFile $temp -MaximumRedirection 5 -TimeoutSec 30}
        catch{throw 'Marker download failed; preauthenticated URL omitted.'}
        if((Get-Item -LiteralPath $temp).Length -ne $bytes.Length){throw 'Downloaded marker length mismatch; remote marker preserved.'}
        $actual=(Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
        if($actual -cne $expected){throw 'Downloaded marker SHA-256 mismatch; remote marker preserved.'}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    $relative='work-pilot/probes/'+$ProbeId.ToString('N')+'/marker.json'
    [ordered]@{Test='W04-SyntheticUpload';Version='0.3.0';Outcome='Verified';Authentication='CertificateAppOnly'
        TenantId=$TenantId.ToString();ClientId=$ClientId.ToString();ListId=$ListId.ToString();DriveId=$DriveId
        ProbeId=$ProbeId.ToString();RelativePath=$relative;MarkerItemId=$marker.id;MarkerWebUrl=($List.webUrl.TrimEnd('/')+'/'+$relative)
        MarkerBytes=$bytes.Length;ExpectedSha256=$expected;DownloadedSha256=$actual;DownloadHashVerified=$true
        MarkerUploadedThisRun=$uploaded;FoldersCreatedThisRun=$script:ProbeFoldersCreated;RemoteMarkerPreserved=$true
        RealBatchRead=$false;RealBatchUploaded=$false;CertificatesCreated=0;AdministrativeLoginUsed=$false;TokenReturnedToConsole=$false
        OrdinaryUserAclReviewed=$false}
}
function Shared-PrepareBatchTarget($Root,$List,$Headers){
    if($state.reportingDeviceId){
        if([guid]$state.reportingDeviceId -eq [guid]::Empty -or $state.reportingDeviceName -cne $env:COMPUTERNAME){throw 'Reporting identity differs from this computer. Do not copy device identity with the shared credential.'}
        $deviceCreated=$false
    }else{
        $state.reportingDeviceId=[guid]::NewGuid().ToString();$state.reportingDeviceName=$env:COMPUTERNAME;$deviceCreated=$true
    }
    if($state.batchTarget -and $state.batchTarget.batchId -ceq $BatchId){
        if($state.batchTarget.expectedManifestSha256 -cne $ExpectedManifestSha256 -or $state.batchTarget.siteId -ne $SiteId -or
            $state.batchTarget.listId -ne $ListId.ToString() -or $state.batchTarget.driveId -cne $DriveId){throw 'Saved batch/manifest/target binding differs; no automatic retargeting.'}
    }
    $segments=@('work-pilot','devices',([guid]$state.reportingDeviceId).ToString('N'),'batches',$BatchId.ToLowerInvariant())
    $relative=$segments -join '/'
    $state.batchTarget=@{batchId=$BatchId;expectedManifestSha256=$ExpectedManifestSha256;siteId=$SiteId;listId=$ListId.ToString()
        driveId=$DriveId;relativePath=$relative;deviceId=$state.reportingDeviceId;status='Preparing'}
    Save-SharedState
    $script:ProbeFoldersCreated=0;$parent=$Root
    foreach($segment in $segments){$parent=Shared-ProbeFolder $parent.id $segment $Headers}
    $children=Invoke-RestMethod -Uri ("https://graph.microsoft.com/v1.0/drives/$DriveId/items/$($parent.id)/children"+'?$select=id,name&$top=1') -Method GET -Headers $Headers
    if($children.value -isnot [Collections.IList]){throw 'Unexpected folder-children response; cannot confirm empty target.'}
    $empty=(@($children.value).Count -eq 0 -and -not $children.'@odata.nextLink')
    $state.batchTarget.folderItemId=$parent.id;$state.batchTarget.emptyAtPreparation=$empty
    $state.batchTarget.status=if($empty){'AwaitingTargetAclReview'}else{'ExistingTargetNotEmpty'}
    Save-SharedState
    [ordered]@{Test='W05D-PrepareBatchTarget';Version='0.4.0';Outcome=if($empty){'TargetPreparedEmpty'}else{'ExistingTargetNotEmpty'}
        Authentication='CertificateAppOnly';TenantId=$TenantId.ToString();ClientId=$ClientId.ToString();ListId=$ListId.ToString();DriveId=$DriveId
        BatchId=$BatchId;ExpectedManifestSha256=$ExpectedManifestSha256;ReportingDeviceId=$state.reportingDeviceId;DeviceName=$env:COMPUTERNAME
        DeviceIdentityOrigin='LocalPersistentGuid';DeviceIdentityCreatedThisRun=$deviceCreated;TargetRelativePath=$relative
        TargetItemId=$parent.id;TargetWebUrl=($List.webUrl.TrimEnd('/')+'/'+$relative);TargetEmpty=$empty
        FoldersCreatedThisRun=$script:ProbeFoldersCreated;TargetFolderAclReviewed=$false;ReadyForRealUpload=$false
        LocalBatchVerifiedByThisStep=$false;RealBatchRead=$false;RealBatchUploaded=$false;FilesUploaded=0;CertificatesCreated=0
        AdministrativeLoginUsed=$false;TokenReturnedToConsole=$false}
}
try{
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if(Test-Path -LiteralPath $statePath){
        if((Get-Item -LiteralPath $statePath).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse state file.'}
        $state=Get-Content -LiteralPath $statePath -Raw -Encoding utf8|ConvertFrom-Json -AsHashtable
        if($state.schemaVersion -ne 1 -or $state.tenantId -ne $TenantId.ToString() -or $state.keyOwnerSid -ne $sid){throw 'Saved state belongs to another tenant/account.'}
        if($ClientId -ne [guid]::Empty -and $state.clientId -and $state.clientId -ne $ClientId.ToString()){throw 'Conflicting application ID.'}
        if($state.clientId){$ClientId=[guid]$state.clientId}
    }else{
        if($Step -eq 'Authenticate'){throw 'Run Prepare first; no shared publisher state exists.'}
        $state=@{schemaVersion=1;tenantId=$TenantId.ToString();keyOwnerSid=$sid;displayName=$displayName;permission=$permission}
    }
    $certificateCreated=$false
    if($Step -eq 'Prepare'){
        if(-not(Get-Module -ListAvailable Microsoft.Graph.Authentication)){Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force}
        Import-Module Microsoft.Graph.Authentication
        Connect-MgGraph -TenantId $TenantId -Scopes Application.Read.All,Application.ReadWrite.All,AppRoleAssignment.ReadWrite.All -ContextScope Process -NoWelcome
        $connected=$true
        if((Get-MgContext).TenantId -ne $TenantId.ToString()){throw 'Wrong administrative tenant.'}
        $graph=@(Shared-Pages "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'00000003-0000-0000-c000-000000000000'&`$select=id,appId,appRoles")
        if($graph.Count -ne 1){throw 'Microsoft Graph resource principal is ambiguous.'}
        $role=@($graph[0].appRoles|Where-Object {$_.value -eq $permission -and $_.isEnabled -and 'Application' -in $_.allowedMemberTypes})
        if($role.Count -ne 1){throw 'Selected application role is unavailable.'}
        if($ClientId -eq [guid]::Empty){
            $existing=@(Shared-Pages "https://graph.microsoft.com/v1.0/applications?`$filter=displayName%20eq%20'Kaz%20Demos%20Scanner%20Publisher%20-%20Work'&`$select=id,appId,displayName")
            if($existing.Count){throw 'Dedicated app exists without saved state. Specify ClientId explicitly; do not create another certificate.'}
            $app=Shared-Graph 'https://graph.microsoft.com/v1.0/applications' POST @{displayName=$displayName;signInAudience='AzureADMyOrg'}
            $ClientId=[guid]$app.appId;$state.clientId=$ClientId.ToString();$state.appObjectId=$app.id;Save-SharedState
        }
        $apps=@(Shared-Pages "https://graph.microsoft.com/v1.0/applications?`$filter=appId%20eq%20'$ClientId'&`$select=id,appId,displayName")
        if($apps.Count -ne 1 -or $apps[0].displayName -ne $displayName){throw 'Use the dedicated Work publisher; never the MIP or Setup app.'}
        $app=Shared-Graph ("https://graph.microsoft.com/v1.0/applications/$($apps[0].id)"+'?$select=id,appId,displayName,requiredResourceAccess,keyCredentials')
        foreach($api in $app.requiredResourceAccess){
            if($api.resourceAppId -ne $graph[0].appId -or @($api.resourceAccess|Where-Object {$_.id -ne $role[0].id -or $_.type -ne 'Role'}).Count){throw 'Unexpected API declaration on publisher; review manually.'}
        }
        $keys=@($app.keyCredentials|Where-Object {$null -ne $_})
        if($keys.Count -gt 1 -or ($keys.Count -gt 0 -and -not $state.certificateThumbprint)){throw 'App already has credentials not owned by this saved pilot. No keys replaced.'}
        $principals=@(Shared-Pages "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId%20eq%20'$ClientId'&`$select=id,appId")
        if($principals.Count -eq 0){$principals=@(Shared-Graph 'https://graph.microsoft.com/v1.0/servicePrincipals' POST @{appId=$ClientId.ToString()})}
        if($principals.Count -ne 1){throw 'Ambiguous publisher principal.'}
        $sp=$principals[0]
        $grants=@(Shared-Pages "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments")
        if(@($grants|Where-Object {$_.resourceId -ne $graph[0].id -or $_.appRoleId -ne $role[0].id}).Count){throw 'Unexpected effective API permissions; review manually before registering credentials.'}
        $state.clientId=$ClientId.ToString();$state.appObjectId=$app.id;Save-SharedState
        if(-not $state.certificateThumbprint){
            $exportPolicy=if($AllowCertificateExport){'Exportable'}else{'NonExportable'}
            $cert=New-SelfSignedCertificate -Subject 'CN=KazDemosScannerPublisherSharedWork' -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 -KeyUsage DigitalSignature -KeyExportPolicy $exportPolicy -Provider 'Microsoft Software Key Storage Provider' -NotAfter (Get-Date).AddYears(1)
            $state.certificateThumbprint=$cert.Thumbprint;$state.certificateExportPolicy=$exportPolicy;$certificateCreated=$true;Save-SharedState
        }
        $cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$state.certificateThumbprint)
        if(-not $cert.HasPrivateKey -or $cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date)){throw 'Shared certificate is unavailable/expired. No automatic replacement.'}
        if($keys.Count -eq 1 -and $keys[0].customKeyIdentifier -ne [Convert]::ToBase64String($cert.GetCertHash())){throw 'Registered certificate differs. No keys replaced.'}
        $required=@(@{resourceAppId=$graph[0].appId;resourceAccess=@(@{id=$role[0].id;type='Role'})})
        $body=@{requiredResourceAccess=$required}
        if($keys.Count -eq 0){$body.keyCredentials=@(@{keyId=[guid]::NewGuid().ToString();type='AsymmetricX509Cert';usage='Verify';key=[Convert]::ToBase64String($cert.RawData);customKeyIdentifier=[Convert]::ToBase64String($cert.GetCertHash());displayName='Single shared Work certificate';startDateTime=$cert.NotBefore.ToUniversalTime().ToString('o');endDateTime=$cert.NotAfter.ToUniversalTime().ToString('o')})}
        $null=Shared-Graph "https://graph.microsoft.com/v1.0/applications/$($app.id)" PATCH $body
        $state.servicePrincipalId=$sp.id;Save-SharedState
        if(-not $grants.Count){
            $null=Shared-Graph "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" POST @{principalId=$sp.id;resourceId=$graph[0].id;appRoleId=$role[0].id}
        }
        $state.preparedUtc=[datetime]::UtcNow.ToString('o');Save-SharedState
        $result=[ordered]@{Test='W02B1-SharedPublisherPrepare';Outcome='Prepared';TenantId=$TenantId.ToString();ClientId=$ClientId.ToString()
            AppObjectId=$app.id;ServicePrincipalId=$sp.id;ApplicationPermission=$permission
            CertificateThumbprint=$cert.Thumbprint;CertificateStore='CurrentUser/My';CertificateExportPolicy=$state.certificateExportPolicy
            CertificateCreatedThisRun=$certificateCreated;StatePath=$statePath;PrivateKeyExported=$false
            SharePointGrantCreated=$false;SharePointAccessTested=$false;EndpointTokenTested=$false}
    }else{
        if(-not $state.preparedUtc){throw 'Preparation did not complete. Rerun Prepare with the same state directory.'}
        $cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$state.certificateThumbprint)
        if(-not $cert.HasPrivateKey -or $cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date)){throw 'Shared certificate unavailable or expired.'}
        $endpoint="https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $header=@{alg='RS256';typ='JWT';x5t=Shared-Base64Url $cert.GetCertHash()}
        $claims=@{aud=$endpoint;iss=$ClientId.ToString();sub=$ClientId.ToString();jti=[guid]::NewGuid().ToString();nbf=$now-30;exp=$now+300}
        $utf8=[Text.UTF8Encoding]::new($false)
        $unsigned=(Shared-Base64Url $utf8.GetBytes(($header|ConvertTo-Json -Compress)))+'.'+(Shared-Base64Url $utf8.GetBytes(($claims|ConvertTo-Json -Compress)))
        $rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        try{$signature=$rsa.SignData($utf8.GetBytes($unsigned),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)}finally{$rsa.Dispose()}
        $assertion=$unsigned+'.'+(Shared-Base64Url $signature)
        $form=@{client_id=$ClientId.ToString();scope='https://graph.microsoft.com/.default';grant_type='client_credentials';client_assertion_type='urn:ietf:params:oauth:client-assertion-type:jwt-bearer';client_assertion=$assertion}
        try{
            $response=Invoke-RestMethod -Uri $endpoint -Method POST -ContentType 'application/x-www-form-urlencoded' -Body $form
            if(-not $response.access_token){throw 'Token endpoint returned no token.'}
            $result=[ordered]@{Test='W02B2-CertificateAuthentication';Outcome='TokenAcquired';Authentication='CertificateAppOnly'
                TenantId=$TenantId.ToString();ClientId=$ClientId.ToString();CertificateThumbprint=$cert.Thumbprint
                TokenReturnedToConsole=$false;ExpiresInSeconds=$response.expires_in;SharePointAccessTested=$false;FilesUploaded=0}
            if($Step -in 'TestAccess','UploadProbe','PrepareBatchTarget'){
                $headers=@{Authorization='Bearer '+$response.access_token}
                try{
                    $list=Invoke-RestMethod -Uri ("https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ListId"+'?$select=id,displayName,webUrl,list') -Method GET -Headers $headers
                    if([guid]$list.id -ne $ListId -or $list.displayName -ne 'ScannerPortalLanding' -or $list.list.template -ne 'documentLibrary'){throw 'Unexpected list metadata.'}
                    $listUrl=[uri]$list.webUrl
                    if($listUrl.Scheme -ne 'https' -or $listUrl.Host -ne $siteParts[0] -or $listUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/ScannerPortalLanding/?$' -or $listUrl.UserInfo -or $listUrl.Query -or $listUrl.Fragment -or -not $listUrl.IsDefaultPort){throw 'Unexpected library URL.'}
                    $root=Invoke-RestMethod -Uri ("https://graph.microsoft.com/v1.0/drives/$DriveId/root"+'?$select=id,webUrl,folder,sharepointIds') -Method GET -Headers $headers
                    if(-not $root.id -or $null -eq $root.folder -or ([string]$root.webUrl).TrimEnd('/') -ne $list.webUrl.TrimEnd('/')){throw 'Drive root does not match expected library.'}
                    if($root.sharepointIds.listId -and [guid]$root.sharepointIds.listId -ne $ListId){throw 'Drive root identifies another list.'}
                    $denied=$false;$negativeStatus=$null
                    try{
                        $null=Invoke-RestMethod -Uri ("https://graph.microsoft.com/v1.0/sites/$SiteId/lists/$ControlListId"+'?$select=id,displayName') -Method GET -Headers $headers
                    }catch{
                        if($_.Exception.PSObject.Properties['ResponseStatusCode']){$negativeStatus=[int]$_.Exception.ResponseStatusCode}
                        elseif($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response){$negativeStatus=[int]$_.Exception.Response.StatusCode}
                        if($negativeStatus -notin 403,404){throw}
                        $denied=$true
                    }
                    if(-not $denied){throw 'Publisher can read the ungranted control list; review resource grants.'}
                    $result=[ordered]@{Test='W03C-CertificateLibraryAccess';Outcome='Verified';Authentication='CertificateAppOnly'
                        TenantId=$TenantId.ToString();ClientId=$ClientId.ToString();CertificateThumbprint=$cert.Thumbprint
                        SiteId=$SiteId;ListId=$ListId.ToString();DriveId=$DriveId;RootItemId=$root.id
                        LibraryUrl=$list.webUrl;LibraryReadVerified=$true;DriveRootReadVerified=$true
                        ControlListId=$ControlListId.ToString();ControlReadDenied=$denied;ControlStatusCode=$negativeStatus
                        ControlExistenceVerifiedByThisScript=$false;WriteAccessTested=$false;OrdinaryUserAclReviewed=$false
                        AdministrativeLoginUsed=$false;TokenReturnedToConsole=$false;SharePointChanged=$false;CertificatesCreated=0;FilesUploaded=0}
                    if($Step -eq 'UploadProbe'){$result=Shared-ProbeUpload $root $list $headers}
                    if($Step -eq 'PrepareBatchTarget'){$result=Shared-PrepareBatchTarget $root $list $headers}
                }finally{$headers.Clear()}
            }
        }finally{$form.Clear();$assertion=$null;$response=$null}
    }
    $headline=if($Step -eq 'PrepareBatchTarget'){'=== WORK W05D PARA COMPARTIR ==='}elseif($Step -eq 'UploadProbe'){'=== WORK W04 PARA COMPARTIR ==='}else{'=== WORK W02B PARA COMPARTIR ==='}
    Write-Host $headline -ForegroundColor Magenta
    Write-Host ($result|ConvertTo-Json -Depth 6) -ForegroundColor Magenta
    [pscustomobject]$result
}finally{if($connected){Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null};$lock.Dispose()}
