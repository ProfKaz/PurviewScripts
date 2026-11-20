<#PSScriptInfo

.VERSION 1.0.0

.GUID 1bb2400c-1847-42af-937f-72021625400b

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-20  1.0.0  Device-folder publisher registration and app-only permission preflight.
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/tests/Test-Publisher.ps1.
.NOTES
HISTORY
Version     : 1.0.0
Tracking ID : 1bb2400c-1847-42af-937f-72021625400b
2026-11-20  Kaz Demos  Initial publisher preparation and permission verification.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '../LocalMIPSharePoint.psm1') -Force -PassThru
function Assert-Fails([scriptblock] $Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected rejection.' }
}
$path = Get-PublisherRelativePath -DeviceId 'a34fef7c-4624-4d6f-8bb5-463468b077a1' -BatchId ('A' * 64) -CreatedUtc ([datetime]'2026-11-20T10:00:00Z')
if ($path -ne ('devices/a3/a34fef7c-4624-4d6f-8bb5-463468b077a1/batches/2026/11/' + ('A' * 64))) { throw 'Unexpected partition layout.' }
Assert-Fails { Get-PublisherRelativePath -DeviceId ([guid]::Empty) -BatchId ('A' * 64) -CreatedUtc ([datetime]::UtcNow) }
Assert-Fails { Get-PublisherRelativePath -DeviceId ([guid]::NewGuid()) -BatchId '../invalid' -CreatedUtc ([datetime]::UtcNow) }
Assert-Fails { Invoke-PublisherGraph -Token fixture -Uri 'https://example.invalid/test' }

$rsa = [Security.Cryptography.RSACng]::new(2048)
$request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=EndpointMIPScanner-AssertionFixture',
    $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
$certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddMinutes(10))
try {
    $assertion = & $module { param($cert) New-PublisherClientAssertion $cert ([guid]'d88f1561-bdab-46f0-b8ba-bfca21e1b5c4') ([guid]'a0e89d29-a20a-45af-8971-54fd03a25dac') } $certificate
    $parts = $assertion.Split('.')
    function Decode-AssertionPart([string]$Part) {
        $value = $Part.Replace('-','+').Replace('_','/')
        [Convert]::FromBase64String($value.PadRight($value.Length + ((4 - $value.Length % 4) % 4), '='))
    }
    $claims = [Text.Encoding]::UTF8.GetString((Decode-AssertionPart $parts[1])) | ConvertFrom-Json
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ([Math]::Abs($claims.nbf - ($epoch - 30)) -gt 10 -or [Math]::Abs($claims.exp - ($epoch + 300)) -gt 10) {
        throw 'Assertion UTC epoch incorrect.'
    }
    if ($claims.aud -ne 'https://login.microsoftonline.com/d88f1561-bdab-46f0-b8ba-bfca21e1b5c4/oauth2/v2.0/token') { throw 'Assertion audience incorrect.' }
    $public = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
    try {
        $valid = $public.VerifyData([Text.Encoding]::UTF8.GetBytes($parts[0] + '.' + $parts[1]),
            (Decode-AssertionPart $parts[2]), [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        if (-not $valid) { throw 'Assertion signature invalid.' }
    } finally { $public.Dispose() }
} finally { $certificate.Dispose(); $rsa.Dispose() }

& $module {
    $script:ControlAllowed = $false
    $script:CorruptDownload = $false
    $script:ControlStatus = 403
    $script:Deleted = @()
    function script:Throw-Http([int]$Code) {
        $exception = [Exception]::new("Fixture HTTP $Code")
        $exception | Add-Member NoteProperty Response ([pscustomobject]@{ StatusCode = $Code; Headers = @{} })
        throw $exception
    }
    function script:Get-PublisherAccessToken { param($Configuration) 'fixture-token' }
    function script:Invoke-RestMethod {
        param($Uri, $Method, $Headers, $Body, $ContentType, $ErrorAction)
        if ($Headers.Authorization -ne 'Bearer fixture-token') { throw 'Missing application authorization.' }
        if ($Uri -like '*/items/device:/_preflight') { return [pscustomobject]@{ id = 'preflight'; folder = @{} } }
        if ($Uri -like '*/items/preflight:/probe-*') { Throw-Http 404 }
        if ($Uri -like '*/items/preflight/children' -and $Method -eq 'POST') { return [pscustomobject]@{ id = 'probe'; folder = @{} } }
        if ($Uri -like '*/items/probe:/probe.txt:/content' -and $Method -eq 'PUT') { return [pscustomobject]@{ id = 'file' } }
        if ($Uri -like '*/items/file' -and $Method -eq 'GET') { return [pscustomobject]@{ '@microsoft.graph.downloadUrl' = 'https://example.invalid/download' } }
        if ($Uri -like '*/items/control/children') {
            if ($script:ControlAllowed) { return [pscustomobject]@{ value = @() } }
            Throw-Http $script:ControlStatus
        }
        if ($Uri -like '*/items/probe' -and $Method -eq 'DELETE') { $script:Deleted += 'probe'; return }
        throw "Unexpected fixture request: $Method $Uri"
    }
    function script:Invoke-WebRequest {
        param([switch]$UseBasicParsing, $Uri, $OutFile, $ErrorAction)
        $value = if ($script:CorruptDownload) { 'corrupt' } else { 'Endpoint MIP Scanner synthetic permission probe' }
        [IO.File]::WriteAllText($OutFile, $value, [Text.UTF8Encoding]::new($false))
    }
}
$configuration = [pscustomobject]@{
    SchemaVersion = 1; TenantId = [guid]::NewGuid().ToString(); ClientId = [guid]::NewGuid().ToString()
    DeviceId = 'a34fef7c-4624-4d6f-8bb5-463468b077a1'; DeviceName = 'Fixture'
    DriveId = 'drive'; DeviceFolderId = 'device'; IsolationFolderId = 'control'
    DeviceFolderPath = 'devices/a3/a34fef7c-4624-4d6f-8bb5-463468b077a1'
    SiteUrl = 'https://example.sharepoint.com/sites/Pilot'; Library = 'ScannerPortalLanding'
    CertificateThumbprint = 'FIXTURE'
}
$result = Test-LocalMIPPublisher $configuration
if (-not $result.Verified -or $result.BatchUploaded) { throw 'Preflight result incorrect.' }
& $module { $script:ControlStatus = 404 }
$null = Test-LocalMIPPublisher $configuration
& $module { $script:ControlStatus = 401 }
Assert-Fails { Test-LocalMIPPublisher $configuration }
& $module { $script:ControlStatus = 403; $script:ControlAllowed = $true }
Assert-Fails { Test-LocalMIPPublisher $configuration }
& $module { $script:ControlAllowed = $false; $script:CorruptDownload = $true }
Assert-Fails { Test-LocalMIPPublisher $configuration }
$deleted = & $module { $script:Deleted }
if (@($deleted).Count -ne 5 -or @($deleted | Where-Object { $_ -ne 'probe' }).Count) { throw 'Probe cleanup did not use its own ID.' }
'PASS: RSA client assertion/UTC epoch, device partition, token use, remote hash, negative access and probe cleanup (mock transport)'
