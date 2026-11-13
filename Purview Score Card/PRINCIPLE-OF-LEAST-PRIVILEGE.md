# Principle of Least Privilege for Microsoft Purview Score Card

Document version: **1.1**

Validation date: **2026-11-11**

Scope: manual execution of `Collect-PurviewAssessment.ps1`

Suggested owner: **DPO / Cybersecurity Lead**

## 1. Purpose

This document defines the minimum permissions required to run the Microsoft Purview collector manually. The assessment covers the `Basic`, `Intermediate`, and `Full` profiles and explicitly distinguishes between:

- Microsoft Entra administrative roles.
- Microsoft Graph delegated OAuth permissions.
- Microsoft Purview role groups.
- Exchange Online role groups.
- Microsoft Defender XDR Unified RBAC, when enabled.
- Service licensing and capability availability.

Assigning an Entra role does not automatically grant Microsoft Graph scopes. Likewise, a Graph scope does not grant access to Microsoft Purview or Exchange Online cmdlets.

## 2. Executive conclusion

There is no single Microsoft Entra role that can run the complete `Full` profile under a strictly read-only model.

The recommended practical set for a complete manual run is:

1. Microsoft Entra `Global Reader`.
2. Microsoft Entra `Compliance Administrator`.
3. Microsoft Purview `Content Explorer List Viewer`, only when Content Explorer is enabled.
4. `eDiscovery Manager` for the operator's own/assigned cases, or the eDiscovery Administrator assignment for tenant-wide case inventory.
5. `Insider Risk Management Auditors` for report-level visibility; use `Insider Risk Management` or `Insider Risk Management Admins` only when configuration export or policy administration is required.
6. Microsoft Purview `Role Management` only when the optional `PurviewRoleGroups` source is selected.
7. Prior administrative consent for the Microsoft Graph delegated permissions requested by the script.

`Global Administrator`, `Exchange Administrator`, `Security Administrator`, and `Content Explorer Content Viewer` are not required.

`Compliance Administrator` includes management capabilities. Therefore, the set above is the practical minimum when using built-in Entra roles, but it is not the absolute granular minimum. Organizations with strict separation-of-duties requirements should use the service-specific role groups in section 7.

## 3. Minimum matrix by profile

| Profile | Minimum practical roles and groups | Covered capabilities |
|---|---|---|
| `Basic` | Entra `Global Reader` + Entra `Compliance Administrator` | DLP policies and rules, sensitivity labels, publishing policies, organization, users, licenses, and aggregated Microsoft 365 reports. |
| `Intermediate` | The roles above | Basic + IRM/RMS, transport rules, retention, sensitive information types, and Activity Explorer. |
| `Full` | The roles above + capability-specific roles for selected optional sources | Intermediate + Information Barriers, Communication Compliance, Advanced Hunting, Content Explorer, eDiscovery/Insider Risk case inventory, Purview role groups, and diagnostic exports. |

### Rationale for the Entra roles

- `Global Reader` provides directory and subscription read access, satisfies the role condition for aggregated Microsoft Graph reports, maps to `View-Only Organization Management` in Exchange Online, and provides read access to Advanced Hunting.
- `Compliance Administrator` provides cross-solution access to Purview configuration, Activity Explorer, Information Barriers, and Communication Compliance.
- `Content Explorer List Viewer` is required because the Entra roles that provide access to the Content Explorer interface do not, by themselves, grant access to the item list.

Microsoft documents limitations for `Global Reader` in Purview. It must not be used as the collector's only role.

## 4. Microsoft Graph delegated permissions

The script requests these scopes through `Connect-MgGraph`:

| Scope | Profile | Collector use | Admin consent |
|---|---|---|---|
| `Organization.Read.All` | All | Read the organization name, identifier, verified domains, and creation date. | Yes |
| `LicenseAssignment.Read.All` | All | Read purchased SKUs and assignments required to calculate coverage. | Yes |
| `User.Read.All` | All | Read users, status, type, assigned licenses, and assigned plans. | Yes |
| `Reports.Read.All` | All | Read aggregated email, OneDrive, and SharePoint counts. | Yes |
| `ThreatHunting.Read.All` | Full, when Advanced Hunting is enabled | Execute `POST /security/runHuntingQuery`. | Yes |

Consent should be granted in advance to the Microsoft Graph PowerShell client. The operator does not need to be a Global Administrator after consent has been granted.

The scopes remain in the process context because the script uses `ContextScope = Process`.

## 5. Evidence-source permission mapping

| Collector source | Profile | Required permission or role |
|---|---|---|
| `DLPPolicies`, `DLPRules` | Basic | Entra `Compliance Administrator` or Purview `View-Only DLP Compliance Management`. Detailed collection now queries every object by identity and requests DLP distribution detail. |
| `SensitivityLabels`, `LabelPolicies` | Basic | Entra `Compliance Administrator` or Purview `Information Protection Readers`. |
| `Organization` | Basic | `Organization.Read.All`; `Global Reader` or `Directory Readers`. |
| `SubscribedSkus` | Basic | `LicenseAssignment.Read.All`; `Global Reader` or `Directory Readers`. |
| `DirectoryCoverage` | Basic | `User.Read.All` and `LicenseAssignment.Read.All`; `Global Reader` or `Directory Readers`. |
| `EmailActivityCounts`, `OneDriveFileCounts`, `SharePointFileCounts` | Basic | `Reports.Read.All` and a supported Usage Reports role. `Global Reader` is sufficient for tenant-level aggregated data. |
| `IRMConfiguration`, `RMSTrustedPublishingDomains`, `RMSTemplates`, `IRMTransportRules` | Intermediate | Exchange `View-Only Organization Management`, inherited through Entra `Global Reader` or assigned directly in Exchange Online. |
| `RetentionLabels`, `RetentionPolicies`, `RetentionRules` | Intermediate | Entra `Compliance Administrator` or a custom group containing `View-Only Record Management`. |
| `SensitiveInformationTypes`, `SensitiveInformationTypeRulePackages`, `DlpRuleSitValidation` | Basic | Entra `Compliance Administrator` or Purview `Information Protection Readers`. Rule-package XML is read locally to validate custom/modified SIT confidence patterns and rule references. |
| `ActivityExplorerAggregate` | Intermediate | Entra `Compliance Administrator` or a role/group supported by Activity Explorer. |
| `InformationBarrierSegments`, `InformationBarrierPolicies` | Full | Entra `Compliance Administrator` or Purview `IB Compliance Management`. |
| `CommunicationCompliancePolicies` | Full | Entra `Compliance Administrator` or Purview `Communication Compliance Admins`. `Communication Compliance Viewers` provides report access but does not guarantee PowerShell access to policy configuration. |
| `AdvancedHuntingAggregate` | Full | `ThreatHunting.Read.All` and Entra `Global Reader`/`Security Reader`, or a Defender XDR URBAC role with Advanced Hunting access. |
| `ContentExplorerAggregate` | Full | Purview `Content Explorer List Viewer`. `Content Explorer Content Viewer` is not required. |
| `eDiscoveryCases` | Full/custom | Purview `eDiscovery Manager` for cases available to that manager. Use the eDiscovery Administrator assignment only when a tenant-wide case inventory is required. |
| `InsiderRiskCases` | Full/custom | Purview `Insider Risk Management Auditors` for report visibility where supported. If the cmdlet is unavailable with that role, use a time-bound `Insider Risk Management` assignment; do not default to Global Administrator. |
| `ImportedInsiderRiskPolicyExport` | Full/custom | No live service permission is used by the collector. The administrator creating the portal export needs `Insider Risk Management` or `Insider Risk Management Admins`; the collector imports the administrator-provided local export. |
| `PurviewRoleGroups` | Full/custom | Purview `Role Management`, normally through `Organization Management`, to enumerate role groups. Member identities are not persisted unless `-IncludeRoleGroupMembers` is explicitly specified. |
| `PurviewDiagnosticExport` | Full/custom | The same Purview read permissions used for DLP, MIP labels, classification, and DLM. Availability also requires a recent ExchangeOnlineManagement module that exposes `Export-PurviewConfig`. |

## 6. Special considerations

### Content Explorer

`Export-ContentExplorerData` accesses the list of classified items. Although the collector persists only counts and pagination metadata, records can exist transiently in memory while the query runs.

Therefore:

- Assign `Content Explorer List Viewer`.
- Do not assign `Content Explorer Content Viewer` unless there is a separate requirement to view or download content.
- Do not grant content privileges as a workaround for configuration or licensing errors.

### Activity Explorer

Activity Explorer requires explicit assignment to a supported role. Access can take time to propagate after the operator is added to a Purview role group.

### Advanced Hunting

The `ThreatHunting.Read.All` scope authorizes the API call, but the user must also have access to the queried tables. When Microsoft Defender XDR Unified RBAC is enabled, URBAC can restrict tables even when the user has an Entra role.

### Communication Compliance

Communication Compliance maintains solution-specific permissions. `Global Administrator` must not be used as a permanent substitute. For this collector, `Compliance Administrator` covers configuration access, but it also grants administrative capabilities.

### Missing cmdlets

A result such as `Missing command(s): Get-RMSTrustedPublishingDomain` does not prove a permission failure. Verify module version and cmdlet availability in Exchange Online before elevating privileges.

### eDiscovery and Insider Risk privacy

The collector masks case names by default and stores a deterministic case key, status, and dates. Use `-IncludeCaseNames` only with Legal/DPO approval and a protected output directory. An eDiscovery Manager sees only cases available to that user; an eDiscovery Administrator can see all cases.

Microsoft does not currently expose a supported public PowerShell cmdlet for a complete Insider Risk policy configuration export. For that reason, the collector supports an administrator-provided local export through `-InsiderRiskExportPath` instead of elevating the runtime account or using undocumented endpoints.

### Role group membership

The default `PurviewRoleGroups` collection stores role names and member counts only. `-IncludeRoleGroupMembers` persists names and email addresses and should be used only when the assessment explicitly requires identity-level access review.

## 7. Strict granular privilege model

If the organization does not allow `Compliance Administrator`, create an operator identity with these service-specific assignments:

| Service | Recommended role or group |
|---|---|
| Microsoft Entra | `Directory Readers` |
| Microsoft Entra / Microsoft 365 Reports | `Usage Summary Reports Reader`; use `Reports Reader` only when the required report is not available to the former. |
| Microsoft Purview DLP | `View-Only DLP Compliance Management` |
| Microsoft Purview Information Protection | `Information Protection Readers` |
| Microsoft Purview Records Management | Custom group containing `View-Only Record Management` |
| Activity Explorer | Purview `Security Reader` or the Information Protection role combination documented for Activity Explorer |
| Exchange Online | `View-Only Organization Management` |
| Information Barriers | `IB Compliance Management` |
| Communication Compliance | `Communication Compliance Admins` |
| Microsoft Defender XDR | Entra `Security Reader` or a read-only Advanced Hunting URBAC permission |
| Content Explorer | `Content Explorer List Viewer` |
| eDiscovery | `eDiscovery Manager`; add the eDiscovery Administrator assignment only for tenant-wide visibility |
| Insider Risk | `Insider Risk Management Auditors` for report visibility; time-bound `Insider Risk Management` or `Insider Risk Management Admins` for configuration export |
| Purview role-group inventory | Custom/temporary group containing `Role Management`, or time-bound `Organization Management` |

This model assigns more groups but reduces cross-solution access. Some capabilities, including Information Barriers and Communication Compliance policy configuration, do not provide a built-in purely read-only role for every cmdlet used by the collector.

## 8. Recommended manual-run procedure

1. Use a named operator account that is separate from the daily administrative account.
2. Preapprove the Microsoft Graph delegated scopes.
3. Assign roles through Microsoft Entra Privileged Identity Management whenever possible.
4. Activate `Global Reader` and `Compliance Administrator` only for the collection window.
5. Activate only the optional capability roles selected in the custom menu; do not grant eDiscovery, Insider Risk, Role Management, or Content Explorer permissions when those sources are not selected.
6. Confirm `Content Explorer List Viewer` only when Content Explorer is enabled.
7. Allow permissions to propagate. Purview solution role assignments can take up to 30 minutes.
8. Run `-DryRun` first to validate the plan without authentication.
9. Run the required profile with interactive authentication or `-DeviceAuthentication`.
10. Review `Run-Manifest.json`; do not convert `Unavailable` into a posture score of zero.
11. Deactivate PIM assignments or remove temporary roles after collection.

## 9. Preflight checklist

Before a live collection, confirm:

- [ ] PowerShell 7 or later is installed.
- [ ] `ExchangeOnlineManagement` and the required Microsoft Graph modules are installed.
- [ ] Administrative consent exists for every scope used by the selected profile.
- [ ] Entra roles are active, not merely eligible in PIM.
- [ ] Purview role-group assignments have propagated.
- [ ] Required licensing exists for Activity Explorer, Communication Compliance, Information Barriers, Content Explorer, and Advanced Hunting.
- [ ] Advanced Hunting access includes the configured table, currently `CloudAppEvents`.
- [ ] `Content Explorer List Viewer` is active for Full.
- [ ] The operator is an `eDiscovery Manager`, or has a time-bound eDiscovery Administrator assignment when tenant-wide case coverage is required.
- [ ] The selected Insider Risk role matches the requested evidence; policy export requires an administrator-capable Insider Risk role.
- [ ] `Role Management` is active only when `PurviewRoleGroups` is selected.
- [ ] `-IncludeCaseNames` and `-IncludeRoleGroupMembers` are disabled unless explicitly approved.
- [ ] The local `Collected Data` path is protected by ACLs and a defined retention policy.

## 10. Official references

- [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions)
- [Microsoft Entra built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference)
- [Authorization for Microsoft Graph Usage Reports](https://learn.microsoft.com/en-us/graph/reportroot-authorization)
- [Microsoft Graph: List subscribedSkus](https://learn.microsoft.com/en-us/graph/api/subscribedsku-list?view=graph-rest-1.0)
- [Microsoft Graph: runHuntingQuery](https://learn.microsoft.com/en-us/graph/api/security-security-runhuntingquery?view=graph-rest-1.0)
- [Advanced Hunting access](https://learn.microsoft.com/en-us/defender-xdr/advanced-hunting-overview)
- [Exchange Online permissions](https://learn.microsoft.com/en-us/exchange/permissions-exo/permissions-exo)
- [Activity Explorer permissions](https://learn.microsoft.com/en-us/purview/data-classification-activity-explorer)
- [Content Explorer permissions](https://learn.microsoft.com/en-us/purview/data-classification-content-explorer)
- [Communication Compliance permissions](https://learn.microsoft.com/en-us/purview/communication-compliance-permissions)
- [Information Barriers permissions](https://learn.microsoft.com/en-us/purview/information-barriers-edit-segments-policies)
- [Records Management permissions](https://learn.microsoft.com/en-us/purview/get-started-with-records-management)
- [Get-DlpCompliancePolicy distribution detail](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-dlpcompliancepolicy?view=exchange-ps)
- [Export-PurviewConfig](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/export-purviewconfig?view=exchange-ps)
- [Assign permissions in eDiscovery](https://learn.microsoft.com/en-us/purview/edisc-permissions)
- [Assign permissions in Insider Risk Management](https://learn.microsoft.com/en-us/purview/insider-risk-management-permissions)

## 11. Security statement

This document defines a technical baseline. It does not replace service-owner approval, DPO review, separation-of-duties analysis, or internal privileged-access requirements. Every elevation must be temporary, traceable, and proportionate to the profile being executed.

