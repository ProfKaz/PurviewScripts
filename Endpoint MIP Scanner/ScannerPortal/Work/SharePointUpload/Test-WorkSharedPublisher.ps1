<#PSScriptInfo
.VERSION 0.3.0
.GUID 382fa9db-fd14-4903-b3c6-19bf35d4be2a
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.3.0 Synthetic marker, safe retry after disconnect, existing path conflict and corrupt-download tests.
2026-11-20 0.2.0 App-only library/root reads, control denial and failure-boundary tests.
2026-11-20 0.1.0 Real single-certificate lifecycle and signed assertion with mocked directory/token transport.
#>
<#
.DESCRIPTION
Offline shared publisher tests. Uses a temporary CurrentUser certificate; no tenant or SharePoint calls.
.NOTES
Version     : 0.3.0
Tracking ID : 382fa9db-fd14-4903-b3c6-19bf35d4be2a
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
Import-Module PKI
$fixture=Join-Path $env:TEMP ('WorkSharedPublisher-'+[guid]::NewGuid().ToString('N'))
$global:SharedWorkFixture=@{Tenant=[guid]::NewGuid().ToString();Client=[guid]::NewGuid().ToString();AppId=[guid]::NewGuid().ToString()
    Principal=[guid]::NewGuid().ToString();GraphId=[guid]::NewGuid().ToString();Role=[guid]::NewGuid().ToString()
    App=$null;Sp=$null;Grants=@();AppCreates=0;KeyWrites=0;Connects=0;Tokens=0;Directory=$fixture}
$global:SharedWorkFixture.ListId=[guid]::NewGuid().ToString()
$global:SharedWorkFixture.ControlListId=[guid]::NewGuid().ToString()
$global:SharedWorkFixture.SiteId='example.sharepoint.com,'+[guid]::NewGuid().ToString()+','+[guid]::NewGuid().ToString()
$global:SharedWorkFixture.NegativeStatus=403
$global:SharedWorkFixture.RootUrl='https://example.sharepoint.com/sites/Pilot/ScannerPortalLanding'
$global:SharedWorkFixture.Folders=@{}
$global:SharedWorkFixture.MarkerBytes=$null
$global:SharedWorkFixture.FolderPosts=0
$global:SharedWorkFixture.FilePuts=0
$global:SharedWorkFixture.CorruptDownload=$false
$global:SharedWorkFixture.FailAfterPut=$false
$global:SharedWorkFixture.PoisonFolder=$false
function Get-Module{param($Name,[switch]$ListAvailable) [pscustomobject]@{Name='Microsoft.Graph.Authentication'}}
function Import-Module{param($Name)}
function Connect-MgGraph{param($TenantId,$Scopes,$ContextScope,[switch]$NoWelcome)
    if($Scopes -contains 'Sites.FullControl.All'){throw 'Unexpected site administration scope.'}
    $global:SharedWorkFixture.Connects++
}
function Get-MgContext{[pscustomobject]@{TenantId=$global:SharedWorkFixture.Tenant}}
function Disconnect-MgGraph{param($ErrorAction)}
function Invoke-MgGraphRequest{param($Uri,$Method,$OutputType,$Body,$ContentType)
    $f=$global:SharedWorkFixture
    if($Uri -match '/sites/|/drives/|/lists/'){throw 'SharePoint operation attempted.'}
    if($Uri -match '/servicePrincipals\?' -and $Uri.Contains('00000003-0000-0000-c000-000000000000')){
        return @{value=@(@{id=$f.GraphId;appId='00000003-0000-0000-c000-000000000000';appRoles=@(@{id=$f.Role;value='Lists.SelectedOperations.Selected';isEnabled=$true;allowedMemberTypes=@('Application')})})}
    }
    if($Uri -eq 'https://graph.microsoft.com/v1.0/applications' -and $Method -eq 'POST'){
        $f.AppCreates++;$app=$Body|ConvertFrom-Json -AsHashtable
        $app.id=$f.AppId;$app.appId=$f.Client;$app.requiredResourceAccess=@();$app.keyCredentials=@();$f.App=$app;return $app
    }
    if($Uri.Contains('/applications?')){return @{value=@(if($f.App){$f.App})}}
    if($Uri.Contains('/applications/'+$f.AppId)){
        if($Method -eq 'PATCH'){
            $update=$Body|ConvertFrom-Json -AsHashtable
            $f.App.requiredResourceAccess=$update.requiredResourceAccess
            if($update.ContainsKey('keyCredentials')){
                $f.KeyWrites++;$f.App.keyCredentials=$update.keyCredentials
                $public=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($update.keyCredentials[0].key))
                try{if($public.HasPrivateKey){throw 'Private key sent to directory.'}}finally{$public.Dispose()}
            }
            return $null
        };return $f.App
    }
    if($Uri -eq 'https://graph.microsoft.com/v1.0/servicePrincipals' -and $Method -eq 'POST'){
        $f.Sp=@{id=$f.Principal;appId=$f.Client};return $f.Sp
    }
    if($Uri -match '/appRoleAssignments'){
        if($Method -eq 'POST'){$grant=$Body|ConvertFrom-Json -AsHashtable;$grant.id='grant';$f.Grants+=,$grant;return $grant}
        return @{value=$f.Grants}
    }
    if($Uri.Contains('/servicePrincipals?')){return @{value=@(if($f.Sp){$f.Sp})}}
    throw "Unexpected Graph request: $Method $Uri"
}
function Decode-SharedPart([string]$Part){
    $value=$Part.Replace('-','+').Replace('_','/')
    [Convert]::FromBase64String($value.PadRight($value.Length+((4-$value.Length%4)%4),'='))
}
function Invoke-RestMethod{param($Uri,$Method,$ContentType,$Body,$Headers)
    $f=$global:SharedWorkFixture
    if($Uri.StartsWith('https://graph.microsoft.com/v1.0/drives/')){
        if($Headers.Authorization -ne 'Bearer DO-NOT-SHARE-TOKEN'){throw 'Missing graph authorization.'}
        if($Method -eq 'POST' -and $Uri -match '/items/([^/]+)/children$'){
            $parent=$Matches[1];$folder=$Body|ConvertFrom-Json -AsHashtable
            if(-not $folder.ContainsKey('folder') -or $folder.'@microsoft.graph.conflictBehavior' -ne 'fail'){throw 'Unsafe folder create.'}
            $key=$parent+'/'+$folder.name;$f.FolderPosts++
            $item=@{id=('folder-'+$f.FolderPosts);name=$folder.name;folder=@{}}
            $f.Folders[$key]=$item;return $item
        }
        if($Method -eq 'PUT'){
            if(-not $Uri.EndsWith('/marker.json:/content?@microsoft.graph.conflictBehavior=fail')){throw 'Unsafe marker PUT.'}
            if($f.MarkerBytes){$e=[Exception]::new('conflict');$e|Add-Member ResponseStatusCode 409;throw $e}
            $f.MarkerBytes=[byte[]]$Body;$f.FilePuts++
            if($f.FailAfterPut){$f.FailAfterPut=$false;throw 'Disconnect after successful server write'}
            return @{id='marker-id'}
        }
        if($Method -eq 'GET' -and $Uri.EndsWith(':/marker.json')){
            if(-not $f.MarkerBytes){$e=[Exception]::new('missing marker');$e|Add-Member ResponseStatusCode 404;throw $e}
            return @{id='marker-id';name='marker.json';file=@{};size=$f.MarkerBytes.Length;'@microsoft.graph.downloadUrl'='https://example.invalid/preauthenticated-test-url'}
        }
        if($Method -eq 'GET' -and $Uri -match '/items/([^/]+):/([^/?]+)$'){
            $key=$Matches[1]+'/'+$Matches[2]
            if($f.PoisonFolder){return @{id='existing-file';name=$Matches[2];file=@{}}}
            if($f.Folders.ContainsKey($key)){return $f.Folders[$key]}
            $e=[Exception]::new('missing folder');$e|Add-Member ResponseStatusCode 404;throw $e
        }
    }
    if($Method -eq 'GET'){
        if($Headers.Authorization -ne 'Bearer DO-NOT-SHARE-TOKEN' -or -not $Uri.StartsWith('https://graph.microsoft.com/v1.0/')){throw 'Unexpected resource authentication/host.'}
        if($Uri.Contains('/root?')){return @{id='root-item';folder=@{};webUrl=$f.RootUrl;sharepointIds=@{listId=$f.ListId}}}
        if($Uri.Contains($f.ControlListId)){
            if($f.NegativeStatus -eq 200){return @{id=$f.ControlListId}}
            $e=[Exception]::new('fixture resource failure')
            if($f.NegativeStatus){$e|Add-Member ResponseStatusCode $f.NegativeStatus}
            throw $e
        }
        if($Uri.Contains($f.ListId)){return @{id=$f.ListId;displayName='ScannerPortalLanding';list=@{template='documentLibrary'};webUrl='https://example.sharepoint.com/sites/Pilot/ScannerPortalLanding'}}
        throw 'Unexpected resource URI.'
    }
    $f.Tokens++
    if($Method -ne 'POST' -or $Body.grant_type -ne 'client_credentials' -or $Body.scope -ne 'https://graph.microsoft.com/.default'){throw 'Invalid token exchange.'}
    $parts=$Body.client_assertion.Split('.')
    $claims=[Text.Encoding]::UTF8.GetString((Decode-SharedPart $parts[1]))|ConvertFrom-Json
    if($claims.aud -ne $Uri -or $claims.iss -ne $f.Client -or [math]::Abs($claims.exp-([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+300)) -gt 10){throw 'Invalid assertion claims.'}
    $state=Get-Content -LiteralPath (Join-Path $f.Directory 'publisher.json') -Raw|ConvertFrom-Json
    $cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$state.certificateThumbprint)
    $public=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
    try{
        if(-not $public.VerifyData([Text.Encoding]::UTF8.GetBytes($parts[0]+'.'+$parts[1]),(Decode-SharedPart $parts[2]),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)){throw 'Invalid assertion signature.'}
    }finally{$public.Dispose()}
    @{access_token='DO-NOT-SHARE-TOKEN';expires_in=3600}
}
function Invoke-WebRequest{param($Uri,$Method,$OutFile,$MaximumRedirection,$TimeoutSec,$Headers)
    if($Uri -ne 'https://example.invalid/preauthenticated-test-url' -or $Headers -or $Method -ne 'GET'){throw 'Download used an authorization header or wrong URL/method.'}
    $bytes=[byte[]]$global:SharedWorkFixture.MarkerBytes.Clone()
    if($global:SharedWorkFixture.CorruptDownload){$bytes[0]=$bytes[0] -bxor 1}
    [IO.File]::WriteAllBytes($OutFile,$bytes)
}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$scriptPath=Join-Path $PSScriptRoot 'Invoke-WorkSharedPublisher.ps1'
try{
    $first=& $scriptPath -Step Prepare -TenantId $global:SharedWorkFixture.Tenant -StateDirectory $fixture -AllowCertificateExport
    $second=& $scriptPath -Step Prepare -TenantId $global:SharedWorkFixture.Tenant -StateDirectory $fixture -AllowCertificateExport
    Assert ($first.CertificateCreatedThisRun -and -not $second.CertificateCreatedThisRun -and $first.CertificateThumbprint -eq $second.CertificateThumbprint) 'Prepare duplicated certificates.'
    Assert ($global:SharedWorkFixture.AppCreates -eq 1 -and $global:SharedWorkFixture.KeyWrites -eq 1 -and $global:SharedWorkFixture.Grants.Count -eq 1) 'Prepare duplicated application/key/consent.'
    $cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$first.CertificateThumbprint)
    $private=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    try{
        $exportFlags=[Security.Cryptography.CngExportPolicies]::AllowExport -bor [Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
        Assert (($private.Key.ExportPolicy -band $exportFlags) -ne 0) 'Explicit future export option not applied.'
    }finally{$private.Dispose()}
    $auth=& $scriptPath -Step Authenticate -TenantId $global:SharedWorkFixture.Tenant -StateDirectory $fixture
    Assert ($auth.Outcome -eq 'TokenAcquired' -and $global:SharedWorkFixture.Tokens -eq 1 -and $global:SharedWorkFixture.Connects -eq 2) 'Authenticate used administrative sign-in or failed app-only authentication.'
    Assert (-not(($auth|ConvertTo-Json).Contains('DO-NOT-SHARE'))) 'Token leaked.'
    Assert (-not $auth.SharePointAccessTested -and $auth.FilesUploaded -eq 0) 'Authentication falsely claimed upload access.'
    $access=@{Step='TestAccess';TenantId=$global:SharedWorkFixture.Tenant;StateDirectory=$fixture
        SiteId=$global:SharedWorkFixture.SiteId;ListId=$global:SharedWorkFixture.ListId;DriveId='drive-fixture';ControlListId=$global:SharedWorkFixture.ControlListId}
    $probe=& $scriptPath @access
    Assert ($probe.LibraryReadVerified -and $probe.DriveRootReadVerified -and $probe.ControlReadDenied -and $probe.ControlStatusCode -eq 403 -and -not $probe.WriteAccessTested -and $global:SharedWorkFixture.Connects -eq 2) 'App-only access probe failed or claimed write/admin verification.'
    $global:SharedWorkFixture.NegativeStatus=404;$probe=& $scriptPath @access
    Assert ($probe.ControlStatusCode -eq 404 -and -not $probe.ControlExistenceVerifiedByThisScript) '404 probe falsely claimed control existence verification.'
    foreach($status in 200,401,500,0){
        $global:SharedWorkFixture.NegativeStatus=$status
        $rejected=$false;try{& $scriptPath @access|Out-Null}catch{$rejected=$true}
        Assert $rejected 'Unexpected control success/authentication/server/network failure was counted as isolation.'
    }
    $global:SharedWorkFixture.NegativeStatus=403;$global:SharedWorkFixture.RootUrl='https://example.sharepoint.com/sites/Pilot/OtherLibrary'
    $rejected=$false;try{& $scriptPath @access|Out-Null}catch{$rejected=$true}
    Assert $rejected 'Wrong drive root accepted.'
    $global:SharedWorkFixture.RootUrl='https://example.sharepoint.com/sites/Pilot/ScannerPortalLanding'
    $access.Step='UploadProbe';$global:SharedWorkFixture.PoisonFolder=$true
    $rejected=$false;try{& $scriptPath @access|Out-Null}catch{$rejected=$true}
    Assert ($rejected -and $global:SharedWorkFixture.FilePuts -eq 0) 'A file occupying the folder path was overwritten.'
    $global:SharedWorkFixture.PoisonFolder=$false;$global:SharedWorkFixture.FailAfterPut=$true
    $rejected=$false;try{& $scriptPath @access|Out-Null}catch{$rejected=$true}
    Assert ($rejected -and $global:SharedWorkFixture.FilePuts -eq 1) 'Disconnect after server write was not simulated.'
    $marker=& $scriptPath @access
    $again=& $scriptPath @access
    Assert ($marker.DownloadHashVerified -and $marker.ExpectedSha256 -eq $marker.DownloadedSha256 -and -not $marker.MarkerUploadedThisRun) 'Retry failed to verify/reuse remote marker.'
    Assert ($again.ProbeId -eq $marker.ProbeId -and $global:SharedWorkFixture.FilePuts -eq 1 -and $global:SharedWorkFixture.FolderPosts -eq 3) 'Repeat created duplicate folders/marker.'
    Assert (-not $marker.RealBatchRead -and -not $marker.RealBatchUploaded -and $global:SharedWorkFixture.Connects -eq 2) 'Probe used real evidence/admin login.'
    $global:SharedWorkFixture.CorruptDownload=$true
    $rejected=$false;try{& $scriptPath @access|Out-Null}catch{$rejected=$true}
    Assert ($rejected -and $global:SharedWorkFixture.FilePuts -eq 1) 'Corrupt marker was accepted or overwritten.'
    Assert (@(Get-ChildItem -LiteralPath $fixture -Filter 'probe-download-*.tmp').Count -eq 0) 'Temporary marker download was left behind.'
    $global:SharedWorkFixture.CorruptDownload=$false;$global:SharedWorkFixture.MarkerBytes=$null;$access.ProbeId=[guid]::NewGuid()
    $fresh=& $scriptPath @access
    Assert ($fresh.MarkerUploadedThisRun -and $fresh.DownloadHashVerified -and $fresh.ProbeId -ne $marker.ProbeId -and $global:SharedWorkFixture.FilePuts -eq 2) 'Explicit new probe failed the first-upload happy path.'
    $global:SharedWorkFixture.Grants+=@{resourceId=[guid]::NewGuid().ToString();appRoleId=[guid]::NewGuid().ToString()}
    $rejected=$false;try{& $scriptPath -Step Prepare -TenantId $global:SharedWorkFixture.Tenant -StateDirectory $fixture|Out-Null}catch{$rejected=$true}
    Assert ($rejected -and $global:SharedWorkFixture.KeyWrites -eq 1) 'Unexpected effective permissions were not rejected before credential update.'
    'PASS: real certificate/RSA; app-only access boundaries; synthetic upload/hash, lost-response retry without duplicates, existing-path and corrupt-download rejection, credential-free download (mock HTTP)'
}finally{
    $statePath=Join-Path $fixture 'publisher.json'
    if(Test-Path -LiteralPath $statePath){$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json;if($state.certificateThumbprint){Remove-Item -LiteralPath ('Cert:\CurrentUser\My\'+$state.certificateThumbprint) -DeleteKey -Force}}
    $absolute=[IO.Path]::GetFullPath($fixture)
    if(-not $absolute.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup.'}
    if(Test-Path -LiteralPath $absolute){[IO.Directory]::Delete($absolute,$true)}
    Remove-Variable SharedWorkFixture -Scope Global
}
