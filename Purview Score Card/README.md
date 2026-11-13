# Microsoft Purview Score Card

Evidence-driven collection, scoring, and reporting toolkit for assessing Microsoft Purview data-protection posture across configuration, coverage, adoption, and operations.

The project is designed for initial assessments, merger and acquisition comparisons, control-baseline reviews, and recurring posture validation. It keeps configuration evidence separate from operational effectiveness and never treats missing evidence as a security failure or a zero score.

## Contents

- `ReadFirst.md`: exact execution order, menu description, authentication guidance, output review, and report-generation commands.
- `SCORING-METHODOLOGY.md`: criteria, formulas, dimensions, standards mapping, and interpretation rules.
- `PRINCIPLE-OF-LEAST-PRIVILEGE.md`: minimum permissions by profile, Microsoft Graph scopes, and Entra, Purview, Exchange, and Defender roles.
- `scoring-config.json`: weights, thresholds, profiles, eligible licenses, optional sources, and manual overrides.
- `scoring-config.schema.json`: basic structural validation for the configuration.
- `Collect-PurviewAssessment.ps1`: interactive and parameter-driven collector.
- `Export-PurviewHtmlReport.ps1`: creates a self-contained HTML report from a collection run.
- `Export-PurviewReportSuite.ps1`: creates the linked Executive, Data Protection, and Governance & Operations reports from a completed Full run.
- `Collected Data`: one JSON folder per run, created automatically.
- `Exported Data`: versioned HTML reports and a `Latest` copy, created automatically.

## Core capabilities

| Area | What the toolkit assesses |
| --- | --- |
| DLP architecture | Policies, detailed rules, policy and rule state, distribution evidence, actions, exceptions, population scope, workload bindings, sensitive-information references, and semantic overlap candidates. |
| Workload coverage | Exchange Online, SharePoint Online, OneDrive, Teams, Endpoint DLP, Microsoft 365 Copilot, and Fabric/Power BI evidence in the enhanced report suite. |
| Sensitive information types | Built-in and tenant-published rule packages, nested predicates, `AdvancedRule` references, confidence thresholds, and checks for rules requesting an unavailable H/M/L confidence pattern. |
| Information Protection | Sensitivity labels, parent/child hierarchy, content types, visual markings, encryption, rights definitions, principals, container controls, publication policies, targets, and distribution state. |
| Licensing and population | Aggregated active-member, guest, disabled-user, eligible-license, SKU, and service-plan coverage without persisting user-level assignments. |
| Usage and adoption | Aggregated Exchange, OneDrive, SharePoint, Activity Explorer, Advanced Hunting, and optional Content Explorer signals for 30-, 60-, or 90-day assessment windows where the source supports them. |
| Information governance | Retention labels, policies and rules; IRM/RMS configuration and templates; and relevant mail-flow rules. |
| Advanced governance | Information Barriers, Communication Compliance, eDiscovery case inventory, Insider Risk case inventory or authorized policy export, and Purview role groups. |
| Reporting | A base score-card report plus linked Executive, Data Protection Deep Dive, and Governance & Operations HTML reports. The enhanced reports include a static evidence view so local-browser JavaScript restrictions do not hide the assessment. |
| Evidence quality | Per-source status, duration, record count, controlled errors, configuration hash, collector version, evidence confidence, and explicit distinction among `Observed`, `NotObserved`, `Unavailable`, and `NotCollected`. |

## Assessment model

The score card uses a configurable 0–4 maturity scale and produces two deliberately separate indicators:

- **Posture Score (0–100):** weighted maturity of controls supported by collected or approved evidence.
- **Evidence Confidence (0–100):** proportion of the assessment model backed by valid evidence.

The default model is informed by ISO/IEC 27001 and the ISO/IEC 27000 family, ISO/IEC 42001, NIST Cybersecurity Framework concepts, NIST Privacy Framework concepts, and GDPR data-protection principles. These mappings provide assessment context; the output is not certification, legal advice, or proof of regulatory compliance.

## Scope of this release

This release defines the model and collects the evidence used by the Score Card. It does not present a final score when there are not enough observed values. This prevents unavailable sources from being treated as false zeroes.

The model keeps two separate results:

- `Posture Score`: maturity of observed controls, from 0 to 100.
- `Evidence Confidence`: proportion of the model supported by valid evidence, from 0 to 100.

## Requirements

- PowerShell 7 or later.
- An account with the appropriate read-only roles for the capabilities being collected.
- Modules:
  - `ExchangeOnlineManagement`
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Users`
  - `Microsoft.Graph.Identity.DirectoryManagement`
  - `Microsoft.Graph.Reports`

The script does not install modules unless `-InstallMissingModules` is specified.

Baseline Microsoft Graph delegated permissions:

- `Organization.Read.All`
- `LicenseAssignment.Read.All`
- `User.Read.All`
- `Reports.Read.All`

When Advanced Hunting is enabled in the Full profile, `ThreatHunting.Read.All` is also requested. Final permissions and licensing must be validated against the tenant role model and the principle of least privilege.

## Running the collector

Interactive menu (Basic, Intermediate, Full, or a custom selection of capability groups):

```powershell
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1"
```

The custom menu can independently select DLP/SITs, Information Protection, usage and licensing, IRM/retention, advanced governance, eDiscovery/Insider Risk, Purview role groups, and diagnostic configuration export.

30-day baseline:

```powershell
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1" -Profile Basic -LookbackDays 30
```

60-day Intermediate assessment:

```powershell
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1" -Profile Intermediate -LookbackDays 60
```

90-day Full assessment, installing missing modules for the current user:

```powershell
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1" -Profile Full -LookbackDays 90 -InstallMissingModules
```

Validate the execution plan without signing in:

```powershell
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1" -Profile Full -LookbackDays 90 -DryRun
```

If the WAM flow does not display a sign-in window, use:

```powershell
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1" -Profile Basic -LookbackDays 30 -DeviceAuthentication
```

Microsoft Graph displays a device code. For Exchange/Purview, the parameter disables WAM and uses the alternative interactive flow supported by the module.

Intentionally exclude a source:

```powershell
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1" -Profile Basic -SkipGraph
```

An intentional exclusion is recorded as `NotCollected`; a module, permission, licensing, or connection failure is recorded as `Unavailable`.

## Collection profiles

### Basic

- DLP policies queried individually with extended properties and distribution detail.
- DLP rules queried individually, including `AdvancedRule`, full property bags, sensitive information references, and blocking/restriction action evidence.
- Sensitive information types and parsed rule-package XML.
- Cross-validation of rule confidence references against custom/modified SIT H/M/L patterns.
- Sensitivity labels and publishing policies.
- Organization, SKUs, and aggregated user/license summary.
- Aggregated email, OneDrive, and SharePoint counts.

### Intermediate

Includes Basic and adds:

- IRM, trusted RMS publishing domains, and RMS templates.
- Mail flow rules that apply or remove IRM/OME protection.
- Retention labels, policies, and rules.
- Activity Explorer data aggregated in memory, without persisting user-level records.

### Full

Includes Intermediate and adds:

- Information Barriers segments and policies.
- Communication Compliance policies.
- Configurable, aggregated Advanced Hunting.
- Content Explorer counts by configured label and workload.
- eDiscovery and Insider Risk case inventory with case names masked by default.
- Microsoft Purview role groups with member counts; identities are excluded by default.
- Optional import of an administrator-provided Insider Risk policy export.
- Full-fidelity `Export-PurviewConfig` diagnostic archive for DLP, MIP labels, classification, and DLM when the cmdlet is available.

### Privacy-sensitive optional switches

Case names and role-group member identities are not persisted by default:

```powershell
# Use only with Legal/DPO approval and a protected output directory.
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1" -Profile Full `
  -IncludeCaseNames -IncludeRoleGroupMembers
```

To import a policy configuration ZIP/XML exported by an authorized Insider Risk administrator:

```powershell
pwsh -NoProfile -File ".\Collect-PurviewAssessment.ps1" -Profile Full `
  -InsiderRiskExportPath "C:\Secure\InsiderRiskPolicyExport.zip"
```

Microsoft does not expose a supported public PowerShell cmdlet for complete Insider Risk policy configuration. The local import path avoids undocumented endpoints and unnecessary runtime elevation.

## Configuration required before scoring

### Eligible licensing

In `scoring-config.json`, complete one or both arrays:

```json
"eligibleLicensing": {
  "targetPopulation": "activeMemberUsers",
  "skuPartNumbers": ["ENTERPRISEPREMIUM"],
  "servicePlanNames": [],
  "emptyConfigurationBehavior": "Unavailable"
}
```

The configured SKU must reflect the contracts, add-ons, and capabilities actually being assessed. The public configuration intentionally leaves both arrays empty to avoid embedding a tenant-specific licensing assumption. Until at least one eligible SKU or service plan is configured, `COV-02` remains `Unavailable`.

### Advanced Hunting

Advanced Hunting is enabled for the Full profile with an aggregated `CloudAppEvents` query grouped by action type. Every additional query must be reviewed and end in aggregation:

```json
"advancedHunting": {
  "enabled": true,
  "requireSummarizeOperator": true,
  "queries": [
    {
      "name": "Reviewed aggregate query",
      "enabled": true,
      "query": "<available table> | where Timestamp > ago(30d) | summarize EventCount=count() by bin(Timestamp, 1d)"
    }
  ]
}
```

The availability of `CloudAppEvents` depends on tenant licensing, retention, and permissions. The collector rejects queries without `summarize` while the safeguard is enabled.

### Content Explorer

Content Explorer is enabled, but the public configuration intentionally contains no tenant-specific label names. Add only the labels or other supported tags approved for aggregate collection, and review the list whenever the tenant taxonomy changes:

```json
"contentExplorer": {
  "enabled": true,
  "pageSize": 1,
  "workloads": ["EXO", "ODB", "SPO", "Teams"],
  "tags": [
    {
      "tagType": "Sensitivity",
      "tagName": "Confidential",
      "workloads": ["EXO", "ODB", "SPO"]
    }
  ]
}
```

The query stores only counts and pagination metadata, not the matched items.

### Manual overrides

Every valid override must contain:

```json
"MON-05": {
  "score": 3,
  "reason": "Formal quarterly review completed.",
  "evidence": "GRC-2026-Q3 minutes",
  "approvedBy": "DPO",
  "approvedOn": "2026-08-27",
  "expiresOn": "2026-11-30"
}
```

Observed evidence must not be replaced with a manual opinion unless the rationale is recorded.

## Outputs

Each execution creates:

```text
Collected Data/
  20260827T120000Z_Basic_a1b2c3d4/
    Score-Configuration.json
    Run-Manifest.json
    DLPPolicies.json
    DLPRules.json
    SensitiveInformationTypeRulePackages.json
    DlpRuleSitValidation.json
    SIT-RulePackage-<name>.xml
    Purview-Diagnostic-Configuration.zip
    ...
```

`Run-Manifest.json` records each source status, duration, count, controlled errors, version, and the SHA-256 hash of the scoring configuration used.

Files use atomic replacement and `ConvertTo-Json -Depth 100`; the workflow does not use `Add-Content` or Log Analytics.

At completion, the collector also creates:

```text
Exported Data/
  Purview-Assessment-<RunId>.html
  Purview-Assessment-Latest.html
  Purview-Assessment-Latest-DryRun.html
```

`-DryRun` executions never replace the `Latest` report from a real collection.

For a completed Full collection, generate the linked report suite:

```powershell
pwsh -NoProfile -File ".\Export-PurviewReportSuite.ps1"
```

When exactly one valid run exists under `Collected Data`, it is selected automatically. If multiple runs exist, provide `-RunPath` explicitly. The suite creates versioned and `Latest` copies of:

- `Purview-Executive-Overview-<RunId>.html`
- `Purview-Data-Protection-Deep-Dive-<RunId>.html`
- `Purview-Governance-Operations-<RunId>.html`

To regenerate the HTML for an existing run:

```powershell
pwsh -NoProfile -File ".\Export-PurviewHtmlReport.ps1" `
  -RunPath ".\Collected Data\<RunId>" `
  -ExportedDataPath ".\Exported Data"
```

## Time-window considerations

- Graph Reports supports `D30` and `D90`, but not `D60`.
- For 60 days, the collector downloads `D90` and filters daily rows to the requested window.
- Activity Explorer is limited to 30 days by default, even when the profile uses 60 or 90 days.
- Advanced Hunting receives a 30-, 60-, or 90-day `timespan`, subject to actual licensing and retention.
- Content/Data Explorer is a snapshot and may have reporting latency.

## Privacy and operations

- The directory summary does not persist users, UPNs, or individual license assignments.
- Activity Explorer aggregates records in memory and stores counts only.
- Policy and label names are retained because they are configuration evidence. Tenant-originated names are intentionally not translated in the English report.
- eDiscovery and Insider Risk case names are masked unless `-IncludeCaseNames` is explicitly used.
- Purview role-group member identities are omitted unless `-IncludeRoleGroupMembers` is explicitly used.
- Protect `Collected Data` with restricted access and a defined retention period.
- Review the manifest before using the evidence for compliance or risk decisions.

## License

This project is distributed under the repository-level [LICENSE](../LICENSE).

