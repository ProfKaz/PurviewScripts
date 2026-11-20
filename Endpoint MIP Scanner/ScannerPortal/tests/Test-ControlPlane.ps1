<#PSScriptInfo
.VERSION 1.0.0
.GUID b5cacb4d-11bb-40e3-b8a1-b8f2d8e1ced
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 1.0.0 Offline administrative workflow with mocked Graph and PnP.
#>
<#
.DESCRIPTION
Exercises initialize/reuse, certificate preservation/approval and profile assignment without tenant access.
.NOTES
Version     : 1.0.0
Tracking ID : b5cacb4d-11bb-40e3-b8a1-b8f2d8e1ced
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('ControlPlane-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$global:ControlPlaneFixture=@{}
$tenant=[guid]::NewGuid();$portal=[guid]::NewGuid();$client=[guid]::NewGuid();$global:ControlPlaneFixture.FixtureRoleId=[guid]::NewGuid();$graphId=[guid]::NewGuid()
$global:ControlPlaneFixture.App=$null;$global:ControlPlaneFixture.Sp=$null;$global:ControlPlaneFixture.Assignments=@();$global:ControlPlaneFixture.Grants=@{};$global:ControlPlaneFixture.Remote=@{};$global:ControlPlaneFixture.Creates=0
function Get-Module {param($Name,[switch]$ListAvailable) [pscustomobject]@{Version=[version]'3.2.0'}}
function Import-Module {param($Name,$RequiredVersion)}
function Connect-MgGraph {param($TenantId,$Scopes,[switch]$NoWelcome)}
function Disconnect-MgGraph {}
function Get-MgContext {[pscustomobject]@{TenantId=$tenant.ToString()}}
function Connect-PnPOnline {param($Url,$Tenant,$ClientId,[switch]$Interactive,[switch]$ReturnConnection) 'fixture-connection'}
function Disconnect-PnPOnline {param($ErrorAction)}
function Get-PnPList {param($Identity,$Includes,$Connection) [pscustomobject]@{Id=if($Identity -eq 'ScannerPortalConfig'){'config-list'}else{'landing-list'};BaseTemplate=101}}
function Get-PnPProperty {param($ClientObject,$Property,$Connection) if($Property -eq 'HasUniqueRoleAssignments'){return $true};return @()}
function Get-PnPSiteCollectionAdmin {param($Connection) [pscustomobject]@{LoginName='admin@example.invalid'}}
function Get-MgApplication {param($Filter,$Property,$ApplicationId) if($global:ControlPlaneFixture.App){return $global:ControlPlaneFixture.App}}
function New-MgApplication {param($DisplayName,$SignInAudience)
 $global:ControlPlaneFixture.Creates++;$global:ControlPlaneFixture.App=[pscustomobject]@{Id='app-object';AppId=$client.ToString();DisplayName=$DisplayName;RequiredResourceAccess=@();KeyCredentials=@()};$global:ControlPlaneFixture.App
}
function Update-MgApplication {param($ApplicationId,$RequiredResourceAccess,$KeyCredentials)
 if($RequiredResourceAccess){$global:ControlPlaneFixture.App.RequiredResourceAccess=$RequiredResourceAccess}
 if($KeyCredentials){
  $global:ControlPlaneFixture.App.KeyCredentials=@(foreach($key in $KeyCredentials){
   if($key -is [Collections.IDictionary] -and -not $key.Contains('CustomKeyIdentifier')){
    $c=[Security.Cryptography.X509Certificates.X509Certificate2]::new($key.key);$key.CustomKeyIdentifier=$c.GetCertHash()
   };[pscustomobject]$key
  })
 }
}
function Get-MgServicePrincipal {param($Filter)
 if($Filter -match '00000003-0000-0000-c000-000000000000'){return [pscustomobject]@{Id=$graphId;AppId='00000003-0000-0000-c000-000000000000';AppRoles=@([pscustomobject]@{Id=$global:ControlPlaneFixture.FixtureRoleId;Value='Lists.SelectedOperations.Selected';IsEnabled=$true;AllowedMemberTypes=@('Application')})}}
 if($global:ControlPlaneFixture.Sp){$global:ControlPlaneFixture.Sp}
}
function New-MgServicePrincipal {param($AppId) $global:ControlPlaneFixture.Sp=[pscustomobject]@{Id='endpoint-sp'};$global:ControlPlaneFixture.Sp}
function Get-MgServicePrincipalAppRoleAssignment {param($ServicePrincipalId,[switch]$All) $global:ControlPlaneFixture.Assignments}
function New-MgServicePrincipalAppRoleAssignment {param($ServicePrincipalId,$PrincipalId,$ResourceId,$AppRoleId)
 $global:ControlPlaneFixture.Assignments+= [pscustomobject]@{ResourceId=$ResourceId;AppRoleId=$AppRoleId}
}
function Set-MgApplicationLogo {param($ApplicationId,$InFile)}
function Invoke-MgGraphRequest {param($Uri,$Method='GET',$Body,$ContentType,$OutputType,$Headers)
 if($Uri -match '/sites/example.sharepoint.com:'){return @{id='site-id'}}
 if($Uri -match '/lists/(config-list|landing-list)/drive$'){return @{id=$Matches[1]}}
 if($Uri -match '/lists/(config-list|landing-list)/permissions$'){
  $list=$Matches[1]
  if($Method -eq 'POST'){
   $value=$Body|ConvertFrom-Json -AsHashtable
   if(-not $value.grantedToV2.application.id){throw 'Wrong list grant contract.'}
   $value.id=$list+'-permission';$global:ControlPlaneFixture.Grants[$list]=$value;return $value
  }
  return @{value=@(if($global:ControlPlaneFixture.Grants.ContainsKey($list)){$global:ControlPlaneFixture.Grants[$list]})}
 }
 if($Uri -match '/root:/(.+):/content(?:\?.*)?$'){
  $path=$Matches[1]
  if($Method -ne 'PUT'){throw 'Unexpected method.'}
  if($Headers['If-Match'] -and $Headers['If-Match'] -ne 'fixture-etag'){throw 'Wrong assignment concurrency condition.'}
  $global:ControlPlaneFixture.Remote[$path]=$Body;return @{id='published';eTag='fixture-etag'}
 }
 if($Uri -match '/root:/(profiles/.+\.json|assignments/.+\.json)$'){
  if($global:ControlPlaneFixture.Remote.ContainsKey($Matches[1])){return @{id='published';eTag='fixture-etag'}}
  $e=[Exception]::new('not found');$e|Add-Member Response ([pscustomobject]@{StatusCode=404});throw $e
 }
 if($Uri.EndsWith('/children')){return @{value=@()}}
 if($Uri -match ':/(profiles|assignments|workstations-audit-pilot|\d+\.\d+\.\d+)$'){return @{id='folder-'+$Matches[1];folder=@{}}}
 throw "Unexpected Graph request: $Method $Uri"
}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$setup=Join-Path $PSScriptRoot '../deployment/Set-ScannerPortalControlPlane.ps1'
$common=@{TenantId=$tenant;SiteUrl='https://example.sharepoint.com/sites/ScannerPortalPilot';StateDirectory=$fixture;Mode='Apply'}
$rsa=[Security.Cryptography.RSA]::Create(2048)
$request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Endpoint-Test',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
$cert=$request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5),[DateTimeOffset]::UtcNow.AddDays(30))
try{
 $null=& $setup @common -Action Initialize -PortalClientId $portal -AllowSharedIngress
 $null=& $setup @common -Action Initialize -PortalClientId $portal -AllowSharedIngress
 Assert ($global:ControlPlaneFixture.Creates -eq 1 -and $global:ControlPlaneFixture.Assignments.Count -eq 1) 'Initialize duplicated app or role grant.'
 Assert ($global:ControlPlaneFixture.Grants['config-list'].roles[0] -eq 'read' -and $global:ControlPlaneFixture.Grants['landing-list'].roles[0] -eq 'write') 'Wrong resource roles.'
 $registration=[guid]::NewGuid()
 $enrollment=@{schemaVersion=1;registrationId=$registration.ToString();deviceName='fixture-device';tenantId=$tenant.ToString();clientId=$client.ToString();certificate=[Convert]::ToBase64String($cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))}
 $path=Join-Path $fixture 'enrollment-request.json';$enrollment|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding utf8
 $global:ControlPlaneFixture.App.KeyCredentials=@([pscustomobject]@{Key=[byte[]]@(1,2,3);CustomKeyIdentifier=[byte[]]@(4,5,6);DisplayName='Existing preserved key'})
 $null=& $setup @common -Action Approve -RequestPath $path
 $null=& $setup @common -Action Approve -RequestPath $path
 Assert ($global:ControlPlaneFixture.App.KeyCredentials.Count -eq 2 -and $global:ControlPlaneFixture.App.KeyCredentials[0].DisplayName -eq 'Existing preserved key') 'Approval replaced or duplicated existing credentials.'
 $profile=Join-Path $PSScriptRoot '../config/managed-profile.example.json'
 $null=& $setup @common -Action Publish -ProfilePath $profile -RegistrationId $registration
 $null=& $setup @common -Action Publish -ProfilePath $profile -RegistrationId $registration
 Assert (@($global:ControlPlaneFixture.Remote.Keys|Where-Object {$_ -like 'assignments/*'}).Count -eq 1) 'Assignment publication failed.'
 'PASS: administrative initialize/reuse, selected read/write grants, public approval preserving credentials, duplicate approval and profile assignment/ETag (mock Graph/PnP; PS5.1 validator real)'
}finally{
 $cert.Dispose();$rsa.Dispose();Remove-Variable ControlPlaneFixture -Scope Global
 [IO.Directory]::Delete($fixture,$true)
}
