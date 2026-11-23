<#PSScriptInfo
.VERSION 0.1.1
.GUID 7bb7b04d-f2b8-4d7d-8840-ec9a8972352b
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.1 Use the site app catalog API and preserve provider errors.
0.1.0 Downloads the pinned W07B package and installs it through the site catalog.
#>
#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName='Install')]
param(
    [Parameter(Mandatory,ParameterSetName='Install')][uri]$SiteUrl,
    [Parameter(Mandatory,ParameterSetName='Install')][guid]$TenantId,
    [Parameter(Mandatory,ParameterSetName='Install')][guid]$PortalClientId,
    [Parameter(Mandatory,ParameterSetName='Download')][switch]$DownloadOnly,
    [string]$PackageDirectory = (Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/PortalPackages')
)

$ErrorActionPreference = 'Stop'
$version = [version]'0.1.0.0'
$productId = [guid]'5670f3cc-719f-44e2-a809-b9ddd68f674a'
$expectedHash = 'C9645145783F9DDFDC25ECCC5D2560A14B6535572EDC11D5CF2B7743EA699796'
$url = 'https://raw.githubusercontent.com/ProfKaz/PurviewScripts/42d7251bbf279833de50854dbd8951b93f6147c6/Endpoint%20MIP%20Scanner/ScannerPortal/ui/packages/scanner-report-0.1.0.sppkg'
if (-not $DownloadOnly) {
    if ($TenantId -eq [guid]::Empty -or $PortalClientId -eq [guid]::Empty -or
        $SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
        $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or
        $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort) {
        throw 'Specify the exact SharePoint site URL, tenant ID and Setup client ID.'
    }
}

$directory = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($PackageDirectory))
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
        $alreadyInstalled = $false
        if ($app) {
            if ([version]$app.AppCatalogVersion -ne $version) {
                throw 'A different version exists at the site catalog. This installer handles only the initial release.'
            }
        } else {
            $uploaded = Add-PnPApp -Path $package -Scope Site -Publish -Connection $connection
            $app = Get-PnPApp -Identity $uploaded.Id -Scope Site -Connection $connection
        }
        if (-not $app -or [version]$app.AppCatalogVersion -ne $version) {
            throw 'Could not verify the expected package version in the site catalog.'
        }
        if (-not $app.Deployed) {
            Publish-PnPApp -Identity $app.Id -Scope Site -Connection $connection | Out-Null
        }
        if ($app.InstalledVersion) {
            if ([version]$app.InstalledVersion -ne $version) { throw 'An upgrade is required. The installed app was preserved.' }
            $alreadyInstalled = $true
        } else {
            Install-PnPApp -Identity $app.Id -Scope Site -Wait -Connection $connection | Out-Null
        }
        $installed = Get-PnPApp -Identity $app.Id -Scope Site -Connection $connection
        if (-not $installed.Deployed -or -not $installed.InstalledVersion -or [version]$installed.InstalledVersion -ne $version) {
            throw 'The expected installed version could not be verified.'
        }
        $result.Outcome = if ($alreadyInstalled) { 'AlreadyInstalled' } else { 'Installed' }
        $result.SiteUrl = $web.Url
        $result.CatalogScope = 'Site'
    } finally {
        Disconnect-PnPOnline -ErrorAction SilentlyContinue
    }
}
Write-Host '=== WORK W07B INSTALACION PARA COMPARTIR ===' -ForegroundColor Magenta
Write-Host ($result | ConvertTo-Json) -ForegroundColor Magenta
