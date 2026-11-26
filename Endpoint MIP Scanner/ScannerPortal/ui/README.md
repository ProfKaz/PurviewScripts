# Interactive portal report (W07B)

The portal uses English for navigation, labels, formatting, and messages.
This web part uses SPFx 1.24.1, React 18.3.1, and Fluent UI.
It reads the acceptance list in the current site through the signed-in
SharePoint session. The package includes its client assets and requests no
additional API permissions.

### Agent management (0.10.0.0)

Select an existing registration in **Agent management**. The editor reads its assigned revision and verifies the SHA-256. Edit its scan roots, extensions, exclusions, local detection rules, incremental and performance settings, pause state, schedule and expiration. The signed-in operator needs add and edit rights on ScannerPortalConfig. SharePoint enforces access on every request. Local content rules use .NET regular expressions and the WinPS 5.1 endpoint validates them at sync.

**Publish configuration** writes a new revision and conditionally updates that registration using its assignment ETag. After a conflict, reload and review the current revision. **Request full rescan** publishes the displayed settings with a new local index directory. The next agent sync picks up the assignment. **Check rescan progress** on the requested revision reads accepted runs for the device and verifies the landing manifest and summary against their recorded hashes. Progress requires read access to the acceptance ledger and landing library. Check the closing generation and acceptance before reassigning that agent.

### Executive overview (0.7.0.0)

In 0.9.0 the footer shows the loaded web part version. Install the receiver on
the administrative host using the suite Download stage. After enabling dynamic
overview, run `Work/SharePointUpload/Start-ScannerPortalReceiver.ps1` with
`-SiteUrl`, `-TenantId`, `-PortalClientId`, `-AcknowledgePublisherDenied` and
`-Watch`. Use the existing Setup sign-in for the interactive pilot. Leave
the process running. Without Watch the command executes one discovery pass.
For a preprovisioned dedicated receiver application, `-CertificateThumbprint`
selects certificate authentication. Its SharePoint rights must permit all of
the existing receiver ACL checks, acceptance writes and overview publication.
Provisioning and reboot recovery for that identity require tenant validation.

Discovery pages by increasing landing item ID. It processes new endpoint-created
manifest items under devices/{registration}/batches/{run}, including existing
items on the first pass. It verifies that the registration has a configuration
assignment. The initial hash is observed in Landing and saved for retry. This
provides consistency across reads, not independent endpoint attestation.
Accepted evidence and per-file hashes are checked by the existing receiver.
Failed jobs remain pending and are retried independently. The source folder must
receive manifest.json last at its final path, as the managed endpoint uploader does.
The cursor and pending queue are scoped to the tenant and library under
LOCALAPPDATA/EndpointMIPScanner/PortalReceiver. Run one worker per state directory.

Run `deployment/Publish-ScannerPortalOverview.ps1` as the portal administrator with
`-SiteUrl`, `-TenantId` and `-PortalClientId`. Supply known test batch IDs through
`-ExcludeBatchId` on each refresh. The publisher pages through the acceptance ledger
and publishes a snapshot in the separate ScannerPortalExecutive library. Initial
provisioning breaks permission inheritance before uploading the snapshot. Grant
designated readers access to the summary and the report page separately.

Version 0.8.0.0 adds automatic refresh after report storage. Use the suite's
Download stage on the administrative machine so that the receiver and publisher
are installed together. Run the report installer with `-EnableDynamicOverview`
and pass any existing excluded batch IDs on migration from 0.7. The receiver
reuses its connection, preserves those exclusions, and reconciles the snapshot
on both storage and retry. Identical inputs retain the existing snapshot.
If concurrent publication fails, rerun the receiver to reconcile the already
stored report. Standalone publication remains available for recovery.
An open visible Overview checks the published snapshot once a minute and on
return to the tab. Its timestamp is the publication time.
The device and account selectors apply to the entire overview. The extension and
detection search fields narrow their respective distributions. Historical totals
include repeat observations. The device count represents reporting identities.

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

### Selecting a batch (0.13.1)

Batch detail initially loads the highest acceptance ID visible to the signed-in reader. Use Show latest acceptance to refresh, or open an acceptance number in Run audit to display that exact run. The header identifies the acceptance and run ID. IDs saved in the web part properties remain available in the dropdown. An accepted item whose report is still pending displays its status instead of showing an older batch.
