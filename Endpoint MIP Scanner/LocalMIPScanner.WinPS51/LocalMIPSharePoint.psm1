<#PSScriptInfo

.VERSION 1.0.0

.GUID 2fc2ddf1-533f-471d-8870-02794f401e56

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-20  1.0.0  Device-folder publisher registration and app-only permission preflight.
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/LocalMIPSharePoint.psm1.
.NOTES
HISTORY
Version     : 1.0.0
Tracking ID : 2fc2ddf1-533f-471d-8870-02794f401e56
2026-11-20  Kaz Demos  Initial publisher preparation and permission verification.
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PublisherField {
    param($Object, [string] $Name)
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-PublisherBase64Url {
    param([byte[]] $Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-PublisherClientAssertion {
    param($certificate, [guid] $tenant, [guid] $client)
    $endpoint = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = ConvertTo-PublisherBase64Url ($certificate.GetCertHash()) }
    $claims = @{
        aud = $endpoint; iss = $client.ToString(); sub = $client.ToString()
        jti = [guid]::NewGuid().ToString(); nbf = $now - 30; exp = $now + 300
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $unsigned = (ConvertTo-PublisherBase64Url $utf8.GetBytes(($header | ConvertTo-Json -Compress))) + '.' +
        (ConvertTo-PublisherBase64Url $utf8.GetBytes(($claims | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    try {
        $signature = $rsa.SignData($utf8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $rsa.Dispose() }
    $assertion = $unsigned + '.' + (ConvertTo-PublisherBase64Url $signature)
    return $assertion
}

function Get-PublisherAccessToken {
    param([Parameter(Mandatory)] $Configuration)
    $tenant = [guid]$Configuration.TenantId
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = [guid]$Configuration.ClientId
    if ($tenant -eq [guid]::Empty -or $client -eq [guid]::Empty) { throw 'Invalid publisher tenant/client ID.' }
    $certificate = Get-Item -LiteralPath ("Cert:\LocalMachine\My\" + $Configuration.CertificateThumbprint)
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter.ToUniversalTime() -le [datetime]::UtcNow) {
        throw 'Publisher certificate is expired or has no accessible private key.'
    }
    $endpoint = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
    $assertion = New-PublisherClientAssertion $certificate $tenant $client
    $body = @{
        client_id = $client.ToString(); scope = 'https://graph.microsoft.com/.default'
        grant_type = 'client_credentials'; client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion = $assertion
    }
    try { (Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded').access_token }
    finally { $body.Clear(); $assertion = $null }
}

function Get-PublisherHttpStatus {
    param($ErrorRecord)
    if ($ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    return 0
}

function Invoke-PublisherGraph {
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('GET','POST','PUT','DELETE')][string] $Method = 'GET',
        $Body,
        [byte[]] $Bytes
    )
    if (-not $Uri.StartsWith('https://graph.microsoft.com/v1.0/', [StringComparison]::Ordinal)) {
        throw 'Publisher requests must target Microsoft Graph v1.0.'
    }
    $parameters = @{ Uri = $Uri; Method = $Method; Headers = @{ Authorization = "Bearer $Token" }; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('Bytes')) {
        $parameters.Body = $Bytes; $parameters.ContentType = 'application/octet-stream'
    } elseif ($null -ne $Body) {
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
        $parameters.ContentType = 'application/json'
    }
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try { return Invoke-RestMethod @parameters }
        catch {
            $status = Get-PublisherHttpStatus $_
            if ($status -notin 429,503 -or $attempt -eq 3) { throw }
            $delay = [int][Math]::Min(30, [Math]::Pow(2, $attempt + 1))
            $response = $_.Exception.Response
            if ($response.PSObject.Properties['Headers']) {
                $retryAfter = $null
                if ($response.Headers -is [Collections.IDictionary]) { $retryAfter = $response.Headers['Retry-After'] }
                elseif ($response.Headers -is [Collections.Specialized.NameValueCollection]) { $retryAfter = $response.Headers.Get('Retry-After') }
                elseif ($response.Headers.PSObject.Properties['RetryAfter'] -and $response.Headers.RetryAfter) {
                    $condition = $response.Headers.RetryAfter
                    if ($condition.Delta) { $retryAfter = [string][int][Math]::Ceiling($condition.Delta.TotalSeconds) }
                    elseif ($condition.Date) { $retryAfter = [string][int][Math]::Ceiling(($condition.Date.UtcDateTime - [datetime]::UtcNow).TotalSeconds) }
                }
                $seconds = 0
                if ($retryAfter -and [int]::TryParse([string]$retryAfter, [ref]$seconds)) {
                    if ($seconds -gt 30) { throw }
                    $delay = [Math]::Max(1, $seconds)
                }
            }
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-OrCreatePublisherFolder {
    param([string] $Token, [string] $DriveId, [string] $ParentId, [string] $Name)
    if ($Name -notmatch '^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$') { throw 'Invalid publisher folder segment.' }
    $uri = "https://graph.microsoft.com/v1.0/drives/$DriveId/items/${ParentId}:/$Name"
    try { $item = Invoke-PublisherGraph -Token $Token -Uri $uri }
    catch {
        if ((Get-PublisherHttpStatus $_) -ne 404) { throw }
        $body = @{ name = $Name; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' }
        try {
            $item = Invoke-PublisherGraph -Token $Token -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/items/$ParentId/children" -Method POST -Body $body
        } catch {
            if ((Get-PublisherHttpStatus $_) -ne 409) { throw }
            $item = Invoke-PublisherGraph -Token $Token -Uri $uri
        }
    }
    if ($null -eq (Get-PublisherField $item 'folder')) { throw 'Publisher path already identifies a file.' }
    return $item
}

function Get-PublisherRelativePath {
    param([Parameter(Mandatory)][guid] $DeviceId, [Parameter(Mandatory)][string] $BatchId, [datetime] $CreatedUtc)
    if ($DeviceId -eq [guid]::Empty -or $BatchId -cnotmatch '^[0-9A-F]{64}$') { throw 'Invalid device/batch identity.' }
    'devices/{0}/{1}/batches/{2}/{3}/{4}' -f $DeviceId.ToString('N').Substring(0,2),
        $DeviceId.ToString(), $CreatedUtc.ToUniversalTime().ToString('yyyy'),
        $CreatedUtc.ToUniversalTime().ToString('MM'), $BatchId
}

function Test-LocalMIPPublisher {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Configuration)
    if ($Configuration.SchemaVersion -ne 1 -or [guid]$Configuration.DeviceId -eq [guid]::Empty) {
        throw 'Unsupported publisher registration.'
    }
    foreach ($name in 'DriveId','DeviceFolderId','IsolationFolderId') {
        if ([string]::IsNullOrWhiteSpace($Configuration.$name) -or $Configuration.$name -match '[/\\:?#]') {
            throw "Invalid publisher resource ID: $name"
        }
    }
    $token = Get-PublisherAccessToken $Configuration
    $base = "https://graph.microsoft.com/v1.0/drives/$($Configuration.DriveId)/items"
    $probe = $null
    try {
        $folder = Get-OrCreatePublisherFolder -Token $token -DriveId $Configuration.DriveId -ParentId $Configuration.DeviceFolderId -Name '_preflight'
        $probeName = 'probe-' + [guid]::NewGuid().ToString('N')
        $probe = Get-OrCreatePublisherFolder -Token $token -DriveId $Configuration.DriveId -ParentId $folder.id -Name $probeName
        $bytes = [Text.Encoding]::UTF8.GetBytes('Endpoint MIP Scanner synthetic permission probe')
        $uploaded = Invoke-PublisherGraph -Token $token -Uri "$base/$($probe.id):/probe.txt:/content" -Method PUT -Bytes $bytes
        $metadata = Invoke-PublisherGraph -Token $token -Uri "$base/$($uploaded.id)"
        $downloadUrl = Get-PublisherField $metadata '@microsoft.graph.downloadUrl'
        if (-not $downloadUrl -or ([uri]$downloadUrl).Scheme -ne 'https') { throw 'No HTTPS download URL returned for verification.' }
        $temporary = Join-Path $env:TEMP ('Endpoint-Probe-' + [guid]::NewGuid().ToString('N'))
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $temporary -ErrorAction Stop
            $hash = [Security.Cryptography.SHA256]::Create()
            try { $expected = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','') }
            finally { $hash.Dispose() }
            if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $expected) { throw 'Remote permission probe hash mismatch.' }
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
        $denied = $false
        try { $null = Invoke-PublisherGraph -Token $token -Uri "$base/$($Configuration.IsolationFolderId)/children" }
        catch {
            if ((Get-PublisherHttpStatus $_) -in 403,404) { $denied = $true } else { throw }
        }
        if (-not $denied) { throw 'Publisher can access the ungranted control folder. Isolation failed.' }
        [pscustomobject]@{
            Verified = $true; Authentication = 'CertificateAppOnly'; SiteUrl = $Configuration.SiteUrl
            ClientId = $Configuration.ClientId; DeviceId = $Configuration.DeviceId
            DeviceName = $Configuration.DeviceName; Library = $Configuration.Library
            DeviceFolder = $Configuration.DeviceFolderPath
            RuntimePermission = 'Files.SelectedOperations.Selected'
            CertificateThumbprint = $Configuration.CertificateThumbprint
            WriteAndDownloadHashVerified = $true; UngrantedFolderDenied = $true
            EndUserAccessTest = 'PendingSeparateIdentity'; BatchUploaded = $false
        }
    } finally {
        if ($null -ne $probe) {
            # This ID was created uniquely by this invocation and contains synthetic data only.
            $null = Invoke-PublisherGraph -Token $token -Uri "$base/$($probe.id)" -Method DELETE
        }
        $token = $null
    }
}

Export-ModuleMember -Function Get-PublisherAccessToken, Invoke-PublisherGraph, Get-OrCreatePublisherFolder,
    Get-PublisherRelativePath, Test-LocalMIPPublisher, Get-PublisherHttpStatus
