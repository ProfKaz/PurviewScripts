<#PSScriptInfo
.VERSION 0.9.0
.GUID 7bb7b04d-f2b8-4d7d-8840-ec9a8972352b
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.9.0 Install the versioned web part for the managed receiver pilot.
0.8.0 Enable ingestion-driven overview publication and live refresh.
0.7.0 Install the executive governance overview.
0.6.0 Install consolidated inventory and KazDemos branding.
0.5.0 Install the managed inventory report view.
0.4.0 Install the read-only published profile preview.
0.3.0 Install the report history selector, upgrading either previous pilot package.
0.2.2 Reuse the verified current package when the catalog omits ProductId.
0.2.1 Recover a verified prior catalog file when app metadata does not match.
0.2.0 Install or upgrade to the English report web part.
0.1.1 Use the site app catalog API and preserve provider errors.
0.1.0 Downloads the pinned W07B package and installs it through the site catalog.
#>
#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName='Install')]
param(
    [Parameter(Mandatory,ParameterSetName='Install')][uri]$SiteUrl,
    [Parameter(Mandatory,ParameterSetName='Install')][guid]$TenantId,
    [Parameter(Mandatory,ParameterSetName='Install')][guid]$PortalClientId,
    [Parameter(ParameterSetName='Install')][switch]$EnableDynamicOverview,
    [Parameter(ParameterSetName='Install')][string[]]$ExcludeBatchId,
    [Parameter(Mandatory,ParameterSetName='Download')][switch]$DownloadOnly,
    [string]$PackageDirectory = (Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/PortalPackages')
)

$ErrorActionPreference = 'Stop'
$version = [version]'0.9.0.0'
$priorVersions = @([version]'0.1.0.0', [version]'0.2.0.0', [version]'0.3.0.0', [version]'0.4.0.0', [version]'0.5.0.0', [version]'0.6.0.0', [version]'0.7.0.0', [version]'0.8.0.0')
$productId = [guid]'5670f3cc-719f-44e2-a809-b9ddd68f674a'
$expectedHash = 'E74B8A7D600F8731875FF6173A156F7A10367976A44027B84CE477FF76546144'
$url = 'https://raw.githubusercontent.com/ProfKaz/PurviewScripts/8f3fe5fe8814fcc65a1f12f21934fc88c115dab0/Endpoint%20MIP%20Scanner/ScannerPortal/ui/packages/scanner-report-0.9.0.sppkg'
if (-not $DownloadOnly) {
    if ($TenantId -eq [guid]::Empty -or $PortalClientId -eq [guid]::Empty -or
        $SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
        $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or
        $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort) {
        throw 'Specify the exact SharePoint site URL, tenant ID and Setup client ID.'
    }
}

$directory = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($PackageDirectory))
$directory = [IO.Directory]::CreateDirectory((Join-Path $directory.FullName $version.ToString()))
$package = Join-Path $directory.FullName 'scanner-report-0.1.0.sppkg'
$temp = Join-Path $directory.FullName ([guid]::NewGuid().ToString('N') + '.download')
try {
    Invoke-WebRequest -Uri $url -OutFile $temp
    $hash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
    if ($hash -cne $expectedHash) { throw 'Downloaded package SHA-256 does not match the release.' }
    [IO.File]::Move($temp, $package, $true)
} finally {
    if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
}
$result = [ordered]@{
    Test = 'W07B-ReportWebPartInstallation'
    Outcome = 'Downloaded'
    PackagePath = $package
    PackageSha256 = $hash
    ProductId = $productId
    Version = $version.ToString()
}
if (-not $DownloadOnly) {
    Import-Module PnP.PowerShell -RequiredVersion 3.2.0
    $connection = Connect-PnPOnline -Url $SiteUrl.AbsoluteUri -Tenant $TenantId -ClientId $PortalClientId -Interactive -ReturnConnection
    try {
        $web = Get-PnPWeb -Includes Url -Connection $connection
        if ($web.Url.TrimEnd('/') -ne $SiteUrl.AbsoluteUri.TrimEnd('/')) { throw 'Connected site differs from the requested site.' }
        $apps = @(Get-PnPApp -Scope Site -Connection $connection -ErrorAction Stop)
        $app = $apps | Where-Object { ([string]$_.ProductId -eq [string]$productId) -or ([string]$_.Id -eq [string]$productId) } | Select-Object -First 1
        if ($app -and [version]$app.AppCatalogVersion -notin ($priorVersions + $version)) {
            throw 'The existing site catalog version is outside the supported upgrade path.'
        }
        if ($app -and $app.InstalledVersion -and [version]$app.InstalledVersion -notin ($priorVersions + $version)) {
            throw 'The installed version is outside the supported upgrade path.'
        }

        $overwritePrior = $false
        if (-not $app) {
            # The app metadata may omit the product GUID. Check the exact catalog
            # filename before uploading, and require a known hash before overwrite.
            $catalogPath = $SiteUrl.AbsolutePath.TrimEnd('/') + '/AppCatalog/' + [IO.Path]::GetFileName($package)
            $catalogItem = Get-PnPFile -Url $catalogPath -AsListItem -Connection $connection -ErrorAction Stop
            if ($catalogItem) {
                $stream = Get-PnPFile -Url $catalogPath -AsMemoryStream -Connection $connection -ErrorAction Stop
                try {
                    $existingHash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
                } finally {
                    $stream.Dispose()
                }
                if ($existingHash -ceq $expectedHash) {
                    $matches = @($apps | Where-Object {
                        $_.Title -eq 'Endpoint MIP Scanner - Reports' -and
                        [version]$_.AppCatalogVersion -eq $version
                    })
                    if ($matches.Count -ne 1) {
                        throw 'The verified package is already in the catalog, but its app record could not be identified uniquely.'
                    }
                    $app = $matches[0]
                } elseif ($existingHash -cin @('C9645145783F9DDFDC25ECCC5D2560A14B6535572EDC11D5CF2B7743EA699796', 'CE9BBA15A5613AA884B017B31F5FCC9405F69AE7C8B94FE32BEFF17256CFAB49', 'D15B1AB2293416D8C171DADB69AB6F291CDFE5E71042D184A7812445C441FA32', '37AF747ED9B9CE8EBEFD0180CC33BDC4544834EA9DE9321CC456B3305A123289', '10A1E84C7A6EEA038FD7F14DFF719BA89BBDCD218DBB567C41458785D99FAB29', '3B1B4BC706830A39892BA13AAEFB0C2D1DDEFDF83778DA48563F32EA7A743D5B', 'F34C52F75A45FC7A37192999848072B461F2446314D36C215978F4A7F3C5EEE1', 'CA80287AD2BFB09C306B2C3588D43DC0121781E0D61057688BC0A0D5035651F9')) {
                    $overwritePrior = $true
                } else {
                    throw "Catalog file already exists without matching app metadata. Its hash is $existingHash. No overwrite was attempted."
                }
            }
        }

        if (-not $app) {
            $uploaded = Add-PnPApp -Path $package -Scope Site -Overwrite:$overwritePrior -Publish -Connection $connection
            $app = Get-PnPApp -Identity $uploaded.Id -Scope Site -Connection $connection
        } elseif ([version]$app.AppCatalogVersion -in $priorVersions) {
            $uploaded = Add-PnPApp -Path $package -Scope Site -Overwrite -Publish -Connection $connection
            $app = Get-PnPApp -Identity $uploaded.Id -Scope Site -Connection $connection
        }
        if (-not $app -or [version]$app.AppCatalogVersion -ne $version) {
            throw 'Could not verify the expected package version in the site catalog.'
        }
        if (-not $app.Deployed -or $app.CurrentVersionDeployed -eq $false) {
            Publish-PnPApp -Identity $app.Id -Scope Site -Connection $connection | Out-Null
        }

        if (-not $app.InstalledVersion) {
            Install-PnPApp -Identity $app.Id -Scope Site -Wait -Connection $connection | Out-Null
            $result.Outcome = 'Installed'
        } elseif ([version]$app.InstalledVersion -in $priorVersions) {
            Update-PnPApp -Identity $app.Id -Scope Site -Connection $connection | Out-Null
            $result.Outcome = 'Updated'
        } elseif ([version]$app.InstalledVersion -eq $version) {
            $result.Outcome = 'AlreadyInstalled'
        } else {
            throw 'The installed version changed during deployment.'
        }
        for ($attempt = 0; $attempt -lt 24; $attempt++) {
            $installed = Get-PnPApp -Identity $app.Id -Scope Site -Connection $connection
            if ($installed.Deployed -and $installed.CurrentVersionDeployed -ne $false -and
                $installed.InstalledVersion -and [version]$installed.InstalledVersion -eq $version) {
                break
            }
            if ($attempt -lt 23) { Start-Sleep -Seconds 5 }
        }
        if (-not $installed.Deployed -or $installed.CurrentVersionDeployed -eq $false -or
            -not $installed.InstalledVersion -or [version]$installed.InstalledVersion -ne $version) {
            throw ("The expected installed version could not be verified. AppId={0}; CatalogVersion={1}; InstalledVersion={2}; Deployed={3}; CurrentVersionDeployed={4}; CanUpgrade={5}; SharePointError={6}" -f
                $app.Id, $installed.AppCatalogVersion, $installed.InstalledVersion, $installed.Deployed,
                $installed.CurrentVersionDeployed, $installed.CanUpgrade, $installed.ErrorMessage)
        }
        $result.SiteUrl = $web.Url
        $result.CatalogScope = 'Site'
        if ($EnableDynamicOverview) {
            $parameters = @{ SiteUrl=$SiteUrl; TenantId=$TenantId; PortalClientId=$PortalClientId; Connection=$connection }
            if ($PSBoundParameters.ContainsKey('ExcludeBatchId')) { $parameters.ExcludeBatchId = $ExcludeBatchId }
            $result.Overview = & (Join-Path $PSScriptRoot 'Publish-ScannerPortalOverview.ps1') @parameters
        }
    } finally {
        Disconnect-PnPOnline -ErrorAction SilentlyContinue
    }
}
Write-Host '=== WORK W07B INSTALLATION FOR SHARING ===' -ForegroundColor Magenta
Write-Host ($result | ConvertTo-Json) -ForegroundColor Magenta
