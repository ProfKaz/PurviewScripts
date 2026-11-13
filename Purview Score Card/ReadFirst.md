# Read First — Microsoft Purview Score Card

This folder is a clean release package for collecting Microsoft Purview evidence and generating the related HTML reports. All commands below must be run from this folder in **PowerShell 7 or later**.

## 1. Open the release folder

```powershell
Set-Location "<path-to-your-clone>\PurviewScripts\Purview Score Card"
$PSVersionTable.PSVersion
```

The major PowerShell version must be `7` or later. Local Windows administrator rights are not inherently required, but the signed-in Microsoft 365 account must have the tenant roles and delegated permissions required for the selected collection profile.

## 2. Unblock the PowerShell scripts

Run this once after copying or downloading the release:

```powershell
Unblock-File -Path .\*.ps1
```

To verify the files:

```powershell
Get-ChildItem -Path . -Filter *.ps1 -File | Select-Object Name, Length, LastWriteTime
```

If organizational execution policy still blocks the scripts, contact the PowerShell or endpoint administrator. Do not permanently weaken the execution policy for this package.

## 3. Review permissions before signing in

Read [PRINCIPLE-OF-LEAST-PRIVILEGE.md](PRINCIPLE-OF-LEAST-PRIVILEGE.md) before running the collector.

At minimum, the collector can request these Microsoft Graph delegated permissions depending on the selected profile:

- `Organization.Read.All`
- `LicenseAssignment.Read.All`
- `User.Read.All`
- `Reports.Read.All`
- `ThreatHunting.Read.All` for Advanced Hunting in the Full profile

Purview, Exchange, eDiscovery, Insider Risk, Communication Compliance, Content Explorer and role-group evidence also depend on the Microsoft 365 roles assigned to the interactive administrator. The permission document contains the minimum role matrix and explains when more than one authorized operator may be required.

## 4. Review the assessment configuration

Before collecting a new tenant, review:

- [scoring-config.json](scoring-config.json): assessment weights, eligible licenses, target workloads, Content Explorer tags and Advanced Hunting queries.
- [SCORING-METHODOLOGY.md](SCORING-METHODOLOGY.md): scoring rules, confidence rules, standards alignment and limitations.
- [scoring-config.schema.json](scoring-config.schema.json): structural schema for the scoring configuration.

The default eligible SKU and configured sensitivity-label names may be tenant-specific. Update them before collection if they do not match the tenant being assessed. Keep the dimension and metric weights at a total of 100.

## 5. Confirm the required PowerShell modules

The collector uses:

- `ExchangeOnlineManagement`
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Users`
- `Microsoft.Graph.Identity.DirectoryManagement`
- `Microsoft.Graph.Reports`

The script does not install missing modules unless `-InstallMissingModules` is specified. To let the collector install missing modules for the current user, add this switch to the execution command:

```powershell
.\Collect-PurviewAssessment.ps1 -InstallMissingModules
```

## 6. Optional dry run

A dry run validates the configuration and planned sources without signing in:

```powershell
.\Collect-PurviewAssessment.ps1 -Profile Full -LookbackDays 30 -DryRun
```

Dry-run output is written to `Collected Data`, and its report does not replace the latest real report.

## 7. Run the collector

For the interactive menu:

```powershell
.\Collect-PurviewAssessment.ps1
```

The menu options are:

1. **Basic** — DLP policies and detailed rules, sensitive information types and rule packages, rule-to-SIT confidence validation, Information Protection labels and publishing policies, licensing, directory coverage, and aggregate Exchange/OneDrive/SharePoint usage.
2. **Intermediate** — everything in Basic, plus IRM/RMS, retention labels/policies/rules, IRM-related mail-flow rules, and aggregated Activity Explorer evidence.
3. **Full** — everything in Intermediate, plus Information Barriers, Communication Compliance, Advanced Hunting aggregates, Content Explorer counts, eDiscovery and Insider Risk case inventory, Purview role groups, and the Purview diagnostic configuration export.
4. **Custom** — select one or more collection groups:
   1. DLP and sensitive information types.
   2. Information Protection labels and publishing policies.
   3. Licensing, directory coverage and Microsoft 365 usage.
   4. IRM, retention and Activity Explorer.
   5. Information Barriers and Communication Compliance.
   6. Insider Risk and eDiscovery case inventory.
   7. Microsoft Purview role groups.
   8. Purview diagnostic configuration export.

For a repeatable, non-menu Full collection with a 30-day window:

```powershell
.\Collect-PurviewAssessment.ps1 -Profile Full -LookbackDays 30
```

Allowed lookback values are `30`, `60`, and `90`. Graph Reports uses D90 data filtered to 60 days when a 60-day window is requested. Activity Explorer remains limited to the configured 30-day maximum.

### If no sign-in window appears

Use the alternative authentication flow:

```powershell
.\Collect-PurviewAssessment.ps1 -Profile Full -LookbackDays 30 -DeviceAuthentication
```

Microsoft Graph displays a device code. For Exchange Online and Security & Compliance PowerShell, this switch disables WAM and requests the alternative interactive flow supported by the installed module.

Do not automate credentials, passwords, MFA or device-code approval. Complete each Microsoft sign-in prompt manually with an authorized account.

### Privacy-sensitive switches

Case names and role-group member identities are not persisted by default. Use the following only with Legal/DPO approval and a protected output location:

```powershell
.\Collect-PurviewAssessment.ps1 -Profile Full -LookbackDays 30 `
  -IncludeCaseNames -IncludeRoleGroupMembers
```

To add a policy export supplied by an authorized Insider Risk administrator:

```powershell
.\Collect-PurviewAssessment.ps1 -Profile Full -LookbackDays 30 `
  -InsiderRiskExportPath "C:\Secure\InsiderRiskPolicyExport.zip"
```

## 8. Review the collected evidence

Every execution creates a timestamped folder:

```text
Collected Data\<RunId>\
```

Open `Collected Data\<RunId>\Run-Manifest.json` first. Confirm:

- connection states;
- every source status (`Observed`, `NotObserved`, `Unavailable`, or `NotCollected`);
- record counts and controlled error messages;
- whether case names or role-group identities were persisted;
- the scoring-configuration hash and collector version.

`NotObserved` means the query completed successfully and returned no objects. `Unavailable` normally means a missing command, permission, license, connection or collection error. Do not interpret either state as a security score without reviewing the evidence.

## 9. Generate or regenerate the base HTML report

The collector automatically calls `Export-PurviewHtmlReport.ps1` at the end of a run. The expected files are:

```text
Exported Data\Purview-Assessment-<RunId>.html
Exported Data\Purview-Assessment-Latest.html
```

If automatic report generation failed, or evidence was replaced after a controlled retry, run:

```powershell
.\Export-PurviewHtmlReport.ps1 `
  -RunPath ".\Collected Data\<RunId>" `
  -ExportedDataPath ".\Exported Data"
```

Replace `<RunId>` with the exact timestamped folder name.

## 10. Generate the linked report suite

For a completed **Full** collection, generate the enhanced three-report suite:

```powershell
.\Export-PurviewReportSuite.ps1
```

When exactly one valid run exists under `Collected Data`, the script selects it automatically. When more than one run exists, specify the intended run explicitly so that evidence from different tenants or collection windows is not mixed:

```powershell
.\Export-PurviewReportSuite.ps1 `
  -RunPath ".\Collected Data\<RunId>" `
  -OutputPath ".\Exported Data"
```

This creates:

- `Purview-Executive-Overview-<RunId>.html`
- `Purview-Data-Protection-Deep-Dive-<RunId>.html`
- `Purview-Governance-Operations-<RunId>.html`
- matching `Latest` copies

Each report contains direct links to the other two reports. Open the Executive Overview first. The report content is pre-rendered in HTML, so the complete evidence baseline remains visible even when a browser blocks local inline JavaScript; JavaScript adds the enhanced filters and charts when available. The suite is optimized for Full evidence; use the base report for partial Basic, Intermediate or Custom collections that do not include the operational sources.

## 11. Exact execution order

1. Open PowerShell 7 and change to this release folder.
2. Run `Unblock-File -Path .\*.ps1`.
3. Read `PRINCIPLE-OF-LEAST-PRIVILEGE.md`.
4. Review tenant-specific values in `scoring-config.json` and read `SCORING-METHODOLOGY.md`.
5. Confirm or install the required modules.
6. Optionally run the Full dry run.
7. Run `Collect-PurviewAssessment.ps1` and complete sign-ins manually.
8. Review `Collected Data\<RunId>\Run-Manifest.json`.
9. Confirm that the base HTML report exists; regenerate it if necessary.
10. For Full evidence, run `Export-PurviewReportSuite.ps1`.
11. Open the Executive Overview and use its links to move between the three reports.

## 12. Release contents

Only the files required for collection, scoring documentation, and report generation are included. Historical source collectors, prior tenant evidence, prior HTML reports, tenant-specific analysis scripts, and ZIP archives are intentionally excluded.

