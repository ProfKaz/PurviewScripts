<#PSScriptInfo
.VERSION 0.1.0
.GUID 382fa9db-fd14-4903-b3c6-19bf35d4be2a
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 Real single-certificate lifecycle and signed assertion with mocked directory/token transport.
#>
<#
.DESCRIPTION
Offline shared publisher tests. Uses a temporary CurrentUser certificate; no tenant or SharePoint calls.
.NOTES
Version     : 0.1.0
Tracking ID : 382fa9db-fd14-4903-b3c6-19bf35d4be2a
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
Import-Module PKI
$fixture=Join-Path $env:TEMP ('WorkSharedPublisher-'+[guid]::NewGuid().ToString('N'))
$global:SharedWorkFixture=@{Tenant=[guid]::NewGuid().ToString();Client=[guid]::NewGuid().ToString();AppId=[guid]::NewGuid().ToString()
    Principal=[guid]::NewGuid().ToString();GraphId=[guid]::NewGuid().ToString();Role=[guid]::NewGuid().ToString()
    App=$null;Sp=$null;Grants=@();AppCreates=0;KeyWrites=0;Connects=0;Tokens=0;Directory=$fixture}
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
function Invoke-RestMethod{param($Uri,$Method,$ContentType,$Body)
    $f=$global:SharedWorkFixture;$f.Tokens++
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
    $global:SharedWorkFixture.Grants+=@{resourceId=[guid]::NewGuid().ToString();appRoleId=[guid]::NewGuid().ToString()}
    $rejected=$false;try{& $scriptPath -Step Prepare -TenantId $global:SharedWorkFixture.Tenant -StateDirectory $fixture|Out-Null}catch{$rejected=$true}
    Assert ($rejected -and $global:SharedWorkFixture.KeyWrites -eq 1) 'Unexpected effective permissions were not rejected before credential update.'
    'PASS: real single CurrentUser certificate reuse, unique app/key/consent, RSA assertion, separate app-only token path and excessive-grant rejection (mock directory/token HTTP)'
}finally{
    $statePath=Join-Path $fixture 'publisher.json'
    if(Test-Path -LiteralPath $statePath){$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json;if($state.certificateThumbprint){Remove-Item -LiteralPath ('Cert:\CurrentUser\My\'+$state.certificateThumbprint) -DeleteKey -Force}}
    $absolute=[IO.Path]::GetFullPath($fixture)
    if(-not $absolute.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup.'}
    if(Test-Path -LiteralPath $absolute){[IO.Directory]::Delete($absolute,$true)}
    Remove-Variable SharedWorkFixture -Scope Global
}
