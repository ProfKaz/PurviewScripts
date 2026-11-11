#Requires -Version 7.4
<#
.SYNOPSIS
Provisions the empty Scanner Portal pilot foundation and a native SharePoint landing page.
.DESCRIPTION
Use only on the dedicated pilot site. Apply requires authenticated PnP connections
and refuses sites with external sharing or principals beyond the owner.
This stage uploads no scanner data and does not install SPFx.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][ValidatePattern('^[^\s@]+@[^\s@]+\.[^\s@]+$')][string]$Owner,
    [ValidateSet('Plan','Apply')][string]$Mode = 'Plan',
    $AdminConnection,
    $SiteConnection
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[a-zA-Z0-9][a-zA-Z0-9_-]{2,63}$' -or
    $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort) {
    throw 'SiteUrl must identify the dedicated pilot on the commercial SharePoint cloud.'
}
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'solution-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.solution -ne 'ScannerPortal' -or $manifest.schemaVersion -ne '0.1') { throw 'Unsupported manifest.' }
$pageName = 'ScannerPortalPilot.aspx'
$pageTitle = 'Scanner Portal — Piloto'
$siteAddress = $SiteUrl.AbsoluteUri.TrimEnd('/')
$plan = [pscustomobject]@{
    Stage = 'Foundation'
    SiteUrl = $siteAddress
    Owner = $Owner
    Libraries = @($manifest.libraries.name)
    Lists = @($manifest.lists.name)
    Page = "$siteAddress/SitePages/$pageName"
    DeploysSPFx = $false
    UploadsScannerData = $false
}
if ($Mode -eq 'Plan' -or $WhatIfPreference) { $plan; return }
if ($null -eq $AdminConnection -or $null -eq $SiteConnection) { throw 'Apply requires explicit PnP admin and site connections.' }
Import-Module PnP.PowerShell -MinimumVersion 3.2.0

function Test-PilotOwner($Principal) {
    if ($null -eq $Principal) { return $false }
    $login = [string]$Principal.LoginName
    return $login -eq $Owner -or $login.EndsWith("|$Owner", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-OwnerOnlyRoleAssignments($Securable) {
    $assignments = Get-PnPProperty -ClientObject $Securable -Property RoleAssignments -Connection $SiteConnection
    foreach ($assignment in $assignments) {
        $principal = Get-PnPProperty -ClientObject $assignment -Property Member -Connection $SiteConnection
        if ([string]$principal.PrincipalType -eq 'SharePointGroup') {
            $members = @(Get-PnPGroupMember -Group $principal.Id -Connection $SiteConnection)
            if (@($members | Where-Object { -not (Test-PilotOwner $_) }).Count) {
                throw "Unexpected group membership in '$($principal.Title)'; owner-only pilot access could not be verified."
            }
        } elseif (-not (Test-PilotOwner $principal)) {
            throw "Unexpected role assignment '$($principal.Title)'; owner-only pilot access could not be verified."
        }
    }
}

$tenantSite = Get-PnPTenantSite -Identity $siteAddress -Detailed -Connection $AdminConnection
$web = Get-PnPWeb -Includes Url,CurrentUser -Connection $SiteConnection
$currentUser = Get-PnPProperty -ClientObject $web -Property CurrentUser -Connection $SiteConnection
if ($web.Url.TrimEnd('/') -ne $siteAddress -or $tenantSite.Url.TrimEnd('/') -ne $siteAddress -or
    [string]$tenantSite.SharingCapability -ne 'Disabled' -or -not (Test-PilotOwner $currentUser)) {
    throw 'Site mismatch, external sharing enabled, or authenticated user differs from the pilot owner.'
}
$siteAdmins = @(Get-PnPSiteCollectionAdmin -Connection $SiteConnection)
if (-not @($siteAdmins | Where-Object { Test-PilotOwner $_ }).Count -or
    @($siteAdmins | Where-Object { -not (Test-PilotOwner $_) }).Count) {
    throw 'The pilot owner must be the only configured site collection administrator.'
}
Assert-OwnerOnlyRoleAssignments $web
if (-not $PSCmdlet.ShouldProcess($siteAddress, 'Provision empty pilot libraries, indexed lists and a native landing page')) { return }

foreach ($spec in $manifest.libraries) {
    $library = Get-PnPList -Identity $spec.name -Includes BaseTemplate,HasUniqueRoleAssignments,Hidden,NoCrawl,EnableVersioning -Connection $SiteConnection
    if ($null -eq $library) {
        $library = New-PnPList -Title $spec.name -Template DocumentLibrary -Url $spec.name -Hidden -Connection $SiteConnection
        $null = Get-PnPProperty -ClientObject $library -Property HasUniqueRoleAssignments -Connection $SiteConnection
    }
    if ([int]$library.BaseTemplate -ne 101) { throw "Unexpected resource type: $($spec.name)." }
    if (-not $library.HasUniqueRoleAssignments) {
        Set-PnPList -Identity $library.Id -BreakRoleInheritance -CopyRoleAssignments:$false -Connection $SiteConnection
    }
    $settings = @{ Identity = $library.Id; Hidden = $true; NoCrawl = $true; Connection = $SiteConnection }
    if ($spec.name -eq 'ScannerPortalConfig') { $settings.EnableVersioning = $true }
    Set-PnPList @settings
    $library = Get-PnPList -Identity $library.Id -Includes HasUniqueRoleAssignments,Hidden,NoCrawl,EnableVersioning -Connection $SiteConnection
    if (-not ($library.HasUniqueRoleAssignments -and $library.Hidden -and $library.NoCrawl) -or
        ($spec.name -eq 'ScannerPortalConfig' -and -not $library.EnableVersioning)) {
        throw "Restricted settings could not be verified for $($spec.name)."
    }
    Assert-OwnerOnlyRoleAssignments $library
}

foreach ($spec in $manifest.lists) {
    $list = Get-PnPList -Identity $spec.name -Includes BaseTemplate,HasUniqueRoleAssignments -Connection $SiteConnection
    if ($null -eq $list) { $list = New-PnPList -Title $spec.name -Template GenericList -Connection $SiteConnection }
    if ([int]$list.BaseTemplate -ne 100) { throw "Unexpected resource type: $($spec.name)." }
    Assert-OwnerOnlyRoleAssignments $list
    $fields = @(Get-PnPField -List $list.Id -Includes InternalName,TypeAsString,Indexed -Connection $SiteConnection)
    foreach ($name in $spec.indexedFields) {
        $type = if ($name.EndsWith('Utc')) { 'DateTime' } else { 'Text' }
        $field = $fields | Where-Object InternalName -EQ $name | Select-Object -First 1
        if ($null -eq $field) {
            $field = Add-PnPField -List $list.Id -DisplayName $name -InternalName $name -Type $type -AddToDefaultView -Connection $SiteConnection
            $null = Get-PnPProperty -ClientObject $field -Property TypeAsString,Indexed -Connection $SiteConnection
        }
        if ($field.TypeAsString -ne $type) { throw "Field type mismatch for $($spec.name).$name." }
        if (-not $field.Indexed) {
            Set-PnPField -List $list.Id -Identity $field.Id -Values @{Indexed = $true} -Connection $SiteConnection | Out-Null
            $field = Get-PnPField -List $list.Id -Identity $field.Id -Includes Indexed -Connection $SiteConnection
            if (-not $field.Indexed) { throw "Index could not be verified for $($spec.name).$name." }
        }
    }
}

$pageLibraryPath = "$($SiteUrl.AbsolutePath)/SitePages"
$pageLibrary = Get-PnPList -Identity $pageLibraryPath -ThrowExceptionIfListNotFound -Connection $SiteConnection
Assert-OwnerOnlyRoleAssignments $pageLibrary
$query = "<View><Query><Where><Eq><FieldRef Name='FileLeafRef'/><Value Type='File'>$pageName</Value></Eq></Where></Query></View>"
$existingPage = Get-PnPListItem -List $pageLibrary.Id -Query $query -Connection $SiteConnection | Select-Object -First 1
if ($null -eq $existingPage) {
    Add-PnPPage -Name $pageName -Title $pageTitle -LayoutType Home -Connection $SiteConnection | Out-Null
} elseif ($existingPage['Title'] -ne $pageTitle) {
    throw 'An unrelated page already uses the pilot page filename.'
}
if ($null -eq $existingPage -or [string]$existingPage['CanvasContent1'] -notmatch 'Powered by Kaz Demos') {
    $intro = '<h2>Scanner Portal</h2><p>Entorno piloto de configuración y reportes de escaneo.</p><ul><li>Perfiles y configuración central</li><li>Explorador de contenido</li><li>Explorador de actividades</li></ul><p>Los conectores y reportes aún no están habilitados.</p><p><strong>Powered by Kaz Demos</strong></p>'
    Add-PnPPageTextPart -Page $pageName -Text $intro -Connection $SiteConnection | Out-Null
}
Set-PnPPage -Identity $pageName -Publish -Connection $SiteConnection | Out-Null
Set-PnPHomePage -RootFolderRelativeUrl "SitePages/$pageName" -Connection $SiteConnection
$home = Get-PnPHomePage -Connection $SiteConnection
if (-not ([string]$home).EndsWith("SitePages/$pageName", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The pilot home page could not be verified.'
}
[pscustomobject]@{ Status = 'FoundationDeployed'; SiteUrl = $siteAddress; Page = $plan.Page; Libraries = $plan.Libraries; Lists = $plan.Lists; DeploysSPFx = $false }
