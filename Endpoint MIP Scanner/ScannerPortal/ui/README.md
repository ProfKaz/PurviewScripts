# Interactive portal report (W07B)

The portal uses English for navigation, labels, formatting, and messages.
This read-only web part uses SPFx 1.24.1, React 18.3.1, and Fluent UI.
It reads the acceptance list in the current site through the signed-in
SharePoint session. The package includes its client assets and requests no
additional API permissions.

Version 0.6.0.0 adds **Consolidated inventory** to the existing web part.
Select the accepted cycles for one device. The selector reads the 50 most
recent acceptance items and includes those with a saved managed inventory
report. Counts sum file observations across the selected cycles. The pilot
generation spans acceptance items 4, 6 and 5 (closing cycle), totaling 517
observations. Item 3 belongs to an earlier scan. The selection is local to
the view and does not modify the acceptance list.

Build with Node.js 24 and npm:

```powershell
npm ci
node --test test/report.test.mjs
npm run build
```

The build creates sharepoint/solution/scanner-report.sppkg. In the pilot,
add **Endpoint MIP Scanner · Report** to a restricted administrative page
and configure the ScannerPortalAcceptance list GUID and acceptance item ID.
For ScannerPortalPilot, use ef8d5b7c-9550-4fb5-b704-034924b903be and item 1.

Verify 2,293 files, 1,814 responded, 479 with no response, 98 sensitive
information types, and 13 coverage errors. In **Detected types**, search
for Credit Card Number, change the sort order, and clear the search.
Use an ordinary account to verify access to both the page and the list item.

## Install the packaged pilot

Run deployment/Install-ScannerPortalReport.ps1 using PowerShell 7.4+ and
PnP.PowerShell 3.2.0 (the pilot runtime already supplies PowerShell).
The script fetches a pinned package from GitHub and verifies SHA-256 before
using the existing Setup app for the one-time interactive administrator
sign-in. DownloadOnly downloads and verifies without requiring PnP.
The site collection App Catalog must already be enabled. The script uploads
and installs at Site scope, verifies the version, and reuses an existing
installation of that version. Version 0.6.0.0 supports upgrades from pilot versions 0.1 through 0.5.
Portal viewers do not run this installer or install Node, npm, or PowerShell.
Placement and configuration of the web part on the protected page follow
installation.

## Bootstrap the SharePoint App Catalog

1. Sign in to the SharePoint admin center as a SharePoint Administrator.
   Open **More features > Apps > Open**. This opens the tenant App Catalog
   or starts provisioning it if it is missing. Wait until it opens.
2. Use an account that is also a site collection administrator of the
   tenant App Catalog and the target site. In PowerShell 7, run the
   following with the tenant's own URLs and existing Setup client ID.

```powershell
$ErrorActionPreference = 'Stop'
Import-Module PnP.PowerShell -RequiredVersion 3.2.0
$adminUrl = 'https://contoso-admin.sharepoint.com'
$siteUrl = 'https://contoso.sharepoint.com/sites/ScannerPortalPilot'
$auth = @{
    Tenant = '<tenant GUID or verified tenant domain>'
    ClientId = '<Setup application client GUID>'
    Interactive = $true
    ReturnConnection = $true
}
$admin = Connect-PnPOnline -Url $adminUrl @auth
$tenantCatalog = Get-PnPTenantAppCatalogUrl -Connection $admin
if (-not $tenantCatalog) {
    throw 'Open Apps in the SharePoint admin center and wait for the tenant catalog.'
}

$site = Connect-PnPOnline -Url $siteUrl @auth
$catalog = Get-PnPSiteCollectionAppCatalog -CurrentSite -Connection $site
if (-not $catalog) {
    Add-PnPSiteCollectionAppCatalog -Site $siteUrl -Connection $admin
    for ($attempt = 0; $attempt -lt 12 -and -not $catalog; $attempt++) {
        Start-Sleep -Seconds 5
        $catalog = Get-PnPSiteCollectionAppCatalog -CurrentSite -Connection $site
    }
}
if (-not $catalog) {
    throw 'The site catalog is not registered yet. Wait and run the check again.'
}
$status = ([string]$catalog.ErrorMessage).Trim()
if ($status -and $status -ne 'Success') {
    throw "SharePoint App Catalog status: $status"
}
$null = Get-PnPApp -Scope Site -Connection $site -ErrorAction Stop
[pscustomobject]@{
    TenantCatalogUrl = $tenantCatalog
    SiteUrl = $siteUrl
    CatalogReadable = $true
}
```

A null TenantAppCatalog error can occur before SharePoint can read the site
catalog registration. Check the tenant catalog first. PnP can return
ErrorMessage=Success for a healthy catalog. A successful Get-PnPApp call
confirms that the site catalog is readable even when it contains no packages.
Continue with Install-ScannerPortalReport.ps1 after CatalogReadable=True.

[Provision the tenant App Catalog](https://learn.microsoft.com/en-us/sharepoint/dev/spfx/set-up-your-developer-tenant#create-app-catalog-site)
and [enable a site collection App Catalog](https://learn.microsoft.com/en-us/sharepoint/dev/general-development/site-collection-app-catalog).

## W07D batch history

In the web part properties, keep acceptance item ID 1 and enter 2 under
**Additional acceptance item IDs**. The pilot shows explicitly configured
IDs only, up to ten including the default. The selector reads the acceptance
date (UTC) and reporting device from SharePoint and loads only the selected
saved report. A previous page with only a default ID still works as before.

Acceptance 1 should show 2,293 files, 98 detected types and 13 coverage errors.
Acceptance 2 is synthetic and should show 3 files, 1 detected type and 0
coverage errors. Switch 1 to 2 to 1, then switch rapidly and confirm that
the final selection keeps its own counts. Verify 2 responds with the sole
Credit Card Number row showing 1 file and 3 matches.
