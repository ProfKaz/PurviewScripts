#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid] $TenantId,
    [guid] $ClientId = [guid]::Empty,
    [ValidateNotNullOrEmpty()][string] $ConfigPath = (Join-Path $PSScriptRoot 'policy-audit.json'),
    [ValidateNotNullOrEmpty()][string] $DisplayName = 'LocalMIPScanner MIP SDK Lab',
    [ValidateNotNullOrEmpty()][string] $LogoPath,
    [switch] $IncludeRightsManagement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($TenantId -eq [guid]::Empty) { throw 'Specify the GUID of the lab tenant.' }

if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $configuration = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
    if ($configuration -isnot [Collections.IDictionary]) { throw 'The policy configuration must be a JSON object.' }
    $configuredTenant = [guid]::Empty
    $configuredClient = [guid]::Empty
    if (-not [guid]::TryParse($configuration['tenantId'], [ref] $configuredTenant) -or $configuredTenant -ne $TenantId -or
        -not [guid]::TryParse($configuration['clientId'], [ref] $configuredClient) -or $configuredClient -eq [guid]::Empty) {
        throw 'The policy configuration must contain the selected tenant and a valid ClientId.'
    }
    if ($PSBoundParameters.ContainsKey('ClientId') -and $ClientId -ne $configuredClient) {
        throw '-ClientId does not match the policy configuration.'
    }
    $ClientId = $configuredClient
} elseif ($PSBoundParameters.ContainsKey('ConfigPath')) {
    throw "The policy configuration does not exist: $ConfigPath"
}
if ($PSBoundParameters.ContainsKey('ClientId') -and $ClientId -eq [guid]::Empty) {
    throw 'Specify a valid -ClientId.'
}

function Get-LocalLogo {
    param([string] $Path, [string] $ExpectedHash)

    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or $file.Extension -ine '.png' -or $file.Length -gt 100KB) {
        throw 'The Entra logo must be a PNG file of up to 100 KB.'
    }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if ($ExpectedHash -and $hash -cne $ExpectedHash) {
        throw 'The downloaded logo failed SHA-256 verification.'
    }
    Add-Type -AssemblyName System.Drawing.Common
    $image = [Drawing.Image]::FromFile($file.FullName)
    try {
        if ($image.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Png.Guid -or
            $image.Width -ne 215 -or $image.Height -ne 215 -or [Drawing.Image]::IsAlphaPixelFormat($image.PixelFormat) -or
            ($image.Flags -band ([Drawing.Imaging.ImageFlags]::HasAlpha -bor [Drawing.Imaging.ImageFlags]::HasTranslucent))) {
            throw 'The Entra logo must be an opaque 215 by 215 pixel PNG.'
        }
    } finally { $image.Dispose() }
    @{ Path = $file.FullName; Hash = $hash }
}

$localLogoPath = $LogoPath
if ($PSBoundParameters.ContainsKey('LogoPath')) {
    if (-not (Test-Path -LiteralPath $LogoPath -PathType Leaf)) {
        throw "The logo specified by -LogoPath does not exist: '$LogoPath'. Supply the PNG path or omit -LogoPath to use the default logo."
    }
} else {
    $localLogoPath = @(
        Join-Path $PSScriptRoot 'kaz-demos-entra-215.png'
        Join-Path $PSScriptRoot 'labs/MipSdkAudit/kaz-demos-entra-215.png'
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
$logo = if ($localLogoPath) { Get-LocalLogo $localLogoPath }

if ($WhatIfPreference) {
    if ($null -eq $logo) { Write-Host 'The default logo will be downloaded from GitHub during setup.' }
    [void] $PSCmdlet.ShouldProcess($TenantId, "Resolve the public client '$DisplayName' and apply Kaz Demos branding")
    return
}

# Reuse the Graph bootstrap pattern from Create-MSLearnPeopleConnectorApp.ps1.
# This interactive public client uses delegated scopes and has no client secret.
foreach ($module in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications') {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Install-Module -Name $module -Repository PSGallery -Scope CurrentUser -Force
    }
}
Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications

function Read-ApplicationLogoHash {
    param([string] $ApplicationId, [string] $Path)

    [IO.File]::Delete($Path)
    try {
        Get-MgApplicationLogo -ApplicationId $ApplicationId -OutFile $Path -ErrorAction Stop | Out-Null
    } catch {
        $status = $_.Exception.PSObject.Properties['ResponseStatusCode']
        if ($null -ne $status -and [int]$status.Value -eq 404) { return $null }
        throw
    }
    if ([IO.File]::Exists($Path) -and [IO.FileInfo]::new($Path).Length -gt 0) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

$tag = 'LocalMIPScanner.MipSdkAudit'
$provider = 'Kaz Demos'
$description = "$provider | LocalMIPScanner MIP SDK audit lab"
$resources = [ordered] @{
    '870c4f2e-85b6-4d43-bdda-6ed9a579b725' = 'UnifiedPolicy.User.Read'
}
if ($IncludeRightsManagement) {
    $resources['00000012-0000-0000-c000-000000000000'] = 'user_impersonation'
}

$connected = $false
$downloadedLogo = Join-Path ([IO.Path]::GetTempPath()) "mip-lab-logo-$([guid]::NewGuid().ToString('N')).png"
$temporaryDefaultLogo = $null
try {
    if ($null -eq $logo) {
        $temporaryDefaultLogo = Join-Path ([IO.Path]::GetTempPath()) "mip-lab-default-logo-$([guid]::NewGuid().ToString('N')).png"
        $logoUri = 'https://raw.githubusercontent.com/ProfKaz/PurviewScripts/ea977502aedfd20f6bf3e73d813b1941c89b214e/labs/MipSdkAudit/kaz-demos-entra-215.png'
        try {
            Invoke-WebRequest -Uri $logoUri -OutFile $temporaryDefaultLogo -TimeoutSec 20
            $logo = Get-LocalLogo $temporaryDefaultLogo -ExpectedHash '55FFE29B1453404E0DB12DA9BC2C17C654F3A026A12334CCF6447C95A4B058A6'
        } catch {
            Write-Warning "The default logo is unavailable. The app setup will continue without updating its logo. Use -LogoPath to supply the PNG. $($_.Exception.Message)"
        }
    }

    Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All' -ContextScope Process -NoWelcome | Out-Null
    $connected = $true
    if ([guid](Get-MgContext).TenantId -ne $TenantId) { throw 'Microsoft Graph connected to a different tenant.' }

    $requiredAccess = @(foreach ($resource in $resources.GetEnumerator()) {
        $service = @(Get-MgServicePrincipal -Filter "appId eq '$($resource.Key)'" -Property 'appId,oauth2PermissionScopes')
        if ($service.Count -ne 1) {
            throw "The first-party API $($resource.Key) is unavailable in the lab tenant. Review its API registration in Entra."
        }
        $scope = @($service[0].Oauth2PermissionScopes | Where-Object { $_.IsEnabled -and $_.Value -ceq $resource.Value })
        if ($scope.Count -ne 1) { throw "Delegated scope $($resource.Value) is unavailable in the lab tenant." }
        @{
            ResourceAppId = $resource.Key
            ResourceAccess = @(@{ Id = $scope[0].Id; Type = 'Scope' })
        }
    })

    $escapedName = $DisplayName.Replace("'", "''")
    $properties = 'id,appId,displayName,description,tags,signInAudience,publicClient,isFallbackPublicClient,requiredResourceAccess'
    if ($ClientId -ne [guid]::Empty) {
        $matches = @(Get-MgApplication -Filter "appId eq '$ClientId'" -Property $properties -All)
        if ($matches.Count -ne 1) { throw "Could not resolve ClientId '$ClientId' in the selected tenant." }
    } else {
        $matches = @(Get-MgApplication -Filter "displayName eq '$escapedName'" -Property $properties -All)
        if ($matches.Count -eq 0 -and -not $PSBoundParameters.ContainsKey('DisplayName')) {
            $matches = @(Get-MgApplication -Filter "tags/any(t:t eq '$tag')" -Property $properties -All)
        }
    }
    $created = $false
    if ($matches.Count -eq 0) {
        if (-not $PSCmdlet.ShouldProcess($TenantId, "Register '$DisplayName'")) { return }
        $app = New-MgApplication -BodyParameter @{
            DisplayName = $DisplayName
            Description = $description
            SignInAudience = 'AzureADMyOrg'
            PublicClient = @{ RedirectUris = @('http://localhost') }
            IsFallbackPublicClient = $true
            RequiredResourceAccess = $requiredAccess
            Tags = @($tag)
        }
        $created = $true
    } else {
        if ($matches.Count -ne 1 -or $tag -notin $matches[0].Tags) {
            throw 'Could not identify a single registration managed by this lab. Check the ClientId or select a distinct display name.'
        }
        $app = $matches[0]
        $expected = @(foreach ($resource in $requiredAccess) {
            "$($resource.ResourceAppId)/$($resource.ResourceAccess[0].Id)/Scope"
        }) | Sort-Object
        $actual = @(foreach ($resource in $app.RequiredResourceAccess) {
            foreach ($scope in $resource.ResourceAccess) {
                "$($resource.ResourceAppId)/$($scope.Id)/$($scope.Type)"
            }
        }) | Sort-Object
        if ($app.SignInAudience -ne 'AzureADMyOrg' -or -not $app.IsFallbackPublicClient -or
            $null -eq $app.PublicClient -or
            ($actual -join ',') -ine ($expected -join ',')) {
            throw 'The existing lab registration has different settings or permissions. Review it in Entra or use a distinct -DisplayName.'
        }
    }

    $changes = @{}
    if (-not $created -and -not ([string]$app.Description).StartsWith("$provider | ", [StringComparison]::Ordinal)) {
        $newDescription = if ($app.Description) { "$provider | $($app.Description)" } else { $description }
        if ($newDescription.Length -gt 1024) { throw 'Adding the provider would exceed the application description limit.' }
        $changes.Description = $newDescription
    }

    $brokerUri = "ms-appx-web://Microsoft.AAD.BrokerPlugin/$($app.AppId)"
    $redirects = if ($created) { @('http://localhost') } else { @($app.PublicClient.RedirectUris) }
    if (@($redirects | Where-Object { $_.TrimEnd('/') -ceq 'http://localhost' }).Count -ne 1 -or
        @($redirects | Where-Object { $_.TrimEnd('/') -cne 'http://localhost' -and $_ -ine $brokerUri }).Count -gt 0) {
        throw 'The existing lab registration has unexpected redirect URIs. Review it in Entra.'
    }
    if ($brokerUri -notin $redirects) {
        $changes.PublicClient = @{ RedirectUris = @(@($redirects) + $brokerUri) }
    }
    if ($changes.Count -gt 0) {
        if (-not $PSCmdlet.ShouldProcess($app.AppId, 'Update Windows broker sign-in or the application description')) { return }
        Update-MgApplication -ApplicationId $app.Id -BodyParameter $changes
    }

    $enterprise = @(Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -Property 'id,appId')
    if ($enterprise.Count -eq 0) {
        if (-not $PSCmdlet.ShouldProcess($app.AppId, 'Create the enterprise application')) { return }
        # An app created through Graph can take a few seconds to become visible to the service principal API.
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $enterprise = @(New-MgServicePrincipal -BodyParameter @{ AppId = $app.AppId })
                break
            } catch {
                $status = $_.Exception.PSObject.Properties['ResponseStatusCode']
                if ($attempt -eq 5 -or $null -eq $status -or [int]$status.Value -notin 400,404,409) { throw }
                Start-Sleep -Seconds $attempt
                $enterprise = @(Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -Property 'id,appId')
                if ($enterprise.Count -gt 0) { break }
            }
        }
    }
    if ($enterprise.Count -ne 1) { throw 'Could not identify a single enterprise application for the lab.' }

    $logoStatus = 'Unavailable'
    $logoBackup = $null
    if ($null -ne $logo) {
        $logoStatus = 'Unchanged'
        $currentHash = Read-ApplicationLogoHash $app.Id $downloadedLogo
        if ($currentHash -ne $logo.Hash) {
            if (-not $PSCmdlet.ShouldProcess($app.AppId, 'Set the Kaz Demos application logo')) { return }
            if ($currentHash) {
                $backupDirectory = Join-Path $env:LOCALAPPDATA 'LocalMIPScanner\MipSdkAudit\branding-backups'
                [void] [IO.Directory]::CreateDirectory($backupDirectory)
                $logoBackup = Join-Path $backupDirectory "$($app.AppId)-$([guid]::NewGuid().ToString('N')).bin"
                [IO.File]::Copy($downloadedLogo, $logoBackup)
            }
            Set-MgApplicationLogo -ApplicationId $app.Id -InFile $logo.Path -ContentType 'image/png' -Confirm:$false | Out-Null
            for ($attempt = 1; $attempt -le 6; $attempt++) {
                if ($attempt -gt 1) { Start-Sleep -Seconds 3 }
                $currentHash = Read-ApplicationLogoHash $app.Id $downloadedLogo
                if ($currentHash -eq $logo.Hash) { break }
            }
            if ($currentHash -ne $logo.Hash) {
                throw "Graph accepted the logo upload, but the returned logo does not yet match. Previous logo backup: $logoBackup"
            }
            $logoStatus = 'Updated'
        }
    }

    [pscustomobject] @{
        TenantId = $TenantId.ToString()
        ClientId = $app.AppId
        AppObjectId = $app.Id
        ServicePrincipalId = $enterprise[0].Id
        Created = $created
        Provider = $provider
        LogoUpdated = $logoStatus -eq 'Updated'
        LogoStatus = $logoStatus
        LogoSha256 = if ($null -ne $logo) { $logo.Hash }
        LogoBackupPath = $logoBackup
        BrokerRedirectUri = $brokerUri
        DelegatedPermissions = @($resources.Values)
        PortalUrl = "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$($app.AppId)"
    }
} finally {
    try { if ($connected) { Disconnect-MgGraph | Out-Null } }
    finally {
        [IO.File]::Delete($downloadedLogo)
        if ($temporaryDefaultLogo) { [IO.File]::Delete($temporaryDefaultLogo) }
    }
}
