# Microsoft Purview Score Card

Model version: **1.0.1**

Reference date: **2026-08-27**

Suggested owner: **DPO / Cybersecurity Lead**

## 1. Purpose and limitations

This model measures the initial Microsoft Purview posture by combining four types of evidence:

1. Control configuration.
2. Coverage of users, licenses, workloads, and data.
3. Observed adoption and operational effectiveness.
4. Governance, monitoring, and continuous improvement.

The result is a technical and risk prioritization aid; **it is not an ISO certification, a legal opinion on GDPR, or a compliance audit**. Standards provide traceability and do not replace a formal assessment.

## 2. Standards foundation

The model is based on:

- [ISO/IEC 27001:2022](https://www.iso.org/standard/27001): information security management system requirements, risk-based approach, and continual improvement.
- [ISO/IEC 27002:2022](https://www.iso.org/standard/75652.html): control guidance, especially inventory, classification, labeling, access control, data leakage prevention, logging, and monitoring.
- [ISO/IEC 42001:2023](https://www.iso.org/standard/42001): AI management systems, governance, risk, traceability, transparency, and continual improvement. This is the specific reference used for the “ISO 42000” family mentioned in the scope.
- [NIST Cybersecurity Framework 2.0](https://www.nist.gov/publications/nist-cybersecurity-framework-csf-20): Govern, Identify, Protect, Detect, Respond, and Recover functions.
- [NIST Privacy Framework](https://www.nist.gov/privacy-framework): data inventory and mapping, governance, control, and protection of personal data.
- [General Data Protection Regulation, GDPR](https://eur-lex.europa.eu/legal-content/EN/TXT/PDF/?uri=CELEX%3A32016R0679): principles and obligations including Articles 5, 24, 25, 30, and 32.

### High-level mapping

| Dimension | ISO/IEC 27001/27002 | ISO/IEC 42001 | NIST CSF / Privacy Framework | GDPR |
|---|---|---|---|---|
| Governance and inventory | Context, leadership, risk assessment; controls 5.9, 5.12, 5.13 | AI data governance, accountability, and traceability | Govern; Identify / Identify-P | Arts. 5, 24, 30 |
| Coverage and licensing | ISMS scope and risk treatment | AI system scope and affected parties | Govern; Identify | Arts. 24, 25, 32 |
| Configured protection | Controls 5.15, 5.31, 5.33, 8.10, 8.12, and 8.24 | Controls proportionate to data/AI risk | Protect / Protect-P; Control-P | Arts. 5(1)(c), 5(1)(f), 25, 32 |
| Adoption and effectiveness | Monitoring, measurement, and performance evaluation | Monitoring AI performance and risk | Identify, Protect, Detect | Arts. 24, 25, 32 |
| Monitoring and response | Controls 8.15 and 8.16; incidents and improvement | Traceability, incidents, and continual improvement | Detect, Respond, Recover | Arts. 32 and 33 |

## 3. Assessment principles

1. **Do not confuse presence with effectiveness.** A policy being present does not demonstrate population coverage or risk reduction.
2. **Do not score missing evidence as noncompliance.** `Unavailable` and `NotCollected` are excluded from the score denominator and reduce confidence.
3. **Data minimization.** The collector stores aggregates whenever possible and avoids UPNs, paths, file names, and content.
4. **Explicit denominators.** Every rate must retain its numerator, denominator, time window, and source.
5. **Traceability.** Every manual value requires a rationale, evidence reference, approver, and date.
6. **Comparability.** Rates from different windows, populations, or sources are not compared without normalization.
7. **Risk before volume.** More rules or DLP matches do not necessarily mean greater maturity.

## 4. Two separate results

### 4.1 Posture Score (0–100)

Each applicable metric receives a maturity level from 0 to 4:

| Level | Interpretation |
|---:|---|
| 0 | Observed evidence confirms the control is absent or has no coverage. |
| 1 | Initial: isolated control, pilot, or low coverage. |
| 2 | Defined: documented control with partial coverage. |
| 3 | Managed: broad coverage, repeatable operation, and recent evidence. |
| 4 | Measured/optimized: target coverage, effectiveness measurement, and continual improvement. |

The normalized metric calculation is:

```text
MetricScore = (Level / 4) × MetricWeight
PostureScore = sum(applicable MetricScore) / sum(applicable Weight) × 100
```

All metric weights total 100. If a metric is not applicable or its source is unavailable, no level is assigned and it is excluded from the denominator.

### 4.2 Evidence Confidence (0–100)

This measures the proportion of the model supported by sufficient evidence:

```text
EvidenceConfidence = sum(Weight with valid evidence) / sum(Weight expected for profile) × 100
```

Evidence states:

| State | Use |
|---|---|
| `Observed` | Collected directly from Microsoft 365/Purview. |
| `Imported` | External file or export with date and provenance. |
| `ManualApproved` | Manual assertion with evidence, approver, and date. |
| `NotObserved` | The query completed and confirmed zero/absence; it may score 0. |
| `Unavailable` | Missing license, permission, module, API, or capability; not scored. |
| `NotCollected` | Outside the profile or intentionally skipped; not scored. |

A high Posture Score with low confidence must be reported as a **provisional result**.

## 5. Interpretation bands

These bands are internal model conventions, not maturity levels defined by ISO, NIST, or GDPR.

| Score | Level | Risk interpretation |
|---:|---|---|
| 0–29 | Ad hoc | High exposure; controls are absent or cannot be demonstrated. |
| 30–49 | Basic | Initial controls with material coverage gaps. |
| 50–69 | Defined | Consistent baseline with incomplete adoption or monitoring. |
| 70–84 | Managed | Broad, measurable operation with targeted improvements remaining. |
| 85–100 | Optimized | Controls are measured, reviewed, and continually improved. |

## 6. Dimensions and metrics

Exact thresholds and editable weights are defined in `scoring-config.json`.

### 6.1 Governance and inventory — 15 points

| ID | Weight | Metric | Primary evidence |
|---|---:|---|---|
| GOV-01 | 4 | Inventory of Purview capabilities and evidence sources | Collector manifest and executed sources |
| GOV-02 | 3 | Classification taxonomy with owner and purpose | Labels, descriptions, and DPO validation |
| GOV-03 | 3 | Policy lifecycle hygiene | Status, age, duplicates, mode, and last modified date |
| GOV-04 | 3 | Retention governance and legal obligations | Retention policies/labels and approved manual input |
| GOV-05 | 2 | AI/Copilot data governance | Documented data scope and AI controls |

### 6.2 Coverage and licensing — 25 points

| ID | Weight | Metric | Baseline formula |
|---|---:|---|---|
| COV-01 | 8 | Overall licensed-user coverage | licensed active member users / active member users |
| COV-02 | 7 | Eligible-license coverage for assessed capabilities | users with eligible SKU/plan / target population |
| COV-03 | 5 | Label publishing coverage | users targeted by label policies / target population |
| COV-04 | 5 | DLP workload coverage | target workloads with enabled DLP policy / target workloads |

`COV-02` requires the organization to configure eligible SKUs or service plans. An empty list produces `Unavailable`, not zero.

### 6.3 Configured protection — 20 points

| ID | Weight | Metric | Primary evidence |
|---|---:|---|---|
| PRO-01 | 7 | DLP enforcement maturity | enabled policies/rules, mode, actions, and scope |
| PRO-02 | 5 | Label protection and rights | encryption, permissions, restrictions, expiration, and content |
| PRO-03 | 3 | IRM/RMS configuration | IRM, trusted domains, RMS templates, and transport rules that apply or remove protection |
| PRO-04 | 3 | Lifecycle and retention coverage | retention labels, policies, and rules |
| PRO-05 | 2 | Segregation and conduct controls | Information Barriers and Communication Compliance where applicable |

### 6.4 Adoption and operational effectiveness — 25 points

| ID | Weight | Metric | Formula/criterion |
|---|---:|---|---|
| ADO-01 | 6 | Email labeling rate | labeled email events / comparable email volume |
| ADO-02 | 6 | File labeling coverage | labeled files / active or total files, explicitly identified |
| ADO-03 | 4 | User adoption | users with labeling activity / eligible active users |
| ADO-04 | 4 | DLP telemetry coverage | target workloads with measurable DLP signals / target workloads |
| ADO-05 | 3 | Override/exception quality | justified and reviewed overrides / total overrides |
| ADO-06 | 2 | Measurement availability | observed operational indicators / expected indicators |

DLP match volume is reported as **density per 10,000 operations**, but it is not converted directly into maturity: a high rate may indicate better detection or greater exposure.

### 6.5 Monitoring, response, and improvement — 15 points

| ID | Weight | Metric | Primary evidence |
|---|---:|---|---|
| MON-01 | 4 | Alert and incident coverage | capabilities with alert/triage workflow / target capabilities |
| MON-02 | 3 | Activity Explorer/audit availability | queryable, recent, and consistent telemetry |
| MON-03 | 3 | Cross-validation and aggregated hunting | Advanced Hunting, Content/Data Explorer, and reconciliation |
| MON-04 | 3 | Triage/response SLA compliance | cases handled within SLA / closed cases |
| MON-05 | 2 | Review and improvement cadence | reviews and actions completed within the expected period |

## 7. Collection profiles

| Profile | Objective | Sources |
|---|---|---|
| Basic | Configuration, licensing, and aggregated usage baseline | DLP, labels/policies, SKUs, user summary, email, OneDrive, and SharePoint |
| Intermediate | Add lifecycle, IRM, and operational activity | Basic + IRM, templates and IRM transport rules, retention, sensitive information types, and aggregated Activity Explorer |
| Full | Expanded governance and cross-validation | Intermediate + Information Barriers, Communication Compliance, Advanced Hunting, and configurable Content Explorer |

The profile does not change metric weights. It only defines which evidence can be collected automatically; confidence exposes pending sources.

## 8. Time windows and denominators

Microsoft Graph exposes `D7`, `D30`, `D90`, and `D180` periods for the reports used. For a 60-day request, the collector retrieves `D90` and filters daily rows to the last 60 days. Data is not interpolated.

Official sources for the indicators:

- [Microsoft Graph: email activity counts](https://learn.microsoft.com/en-us/graph/api/reportroot-getemailactivitycounts?view=graph-rest-1.0)
- [Microsoft Graph: OneDrive file counts](https://learn.microsoft.com/en-us/graph/api/reportroot-getonedriveusagefilecounts?view=graph-rest-1.0)
- [Microsoft Graph: SharePoint file counts](https://learn.microsoft.com/en-us/graph/api/reportroot-getsharepointsiteusagefilecounts?view=graph-rest-1.0)
- [Microsoft Graph: subscribed SKUs](https://learn.microsoft.com/en-us/graph/api/subscribedsku-list?view=graph-rest-1.0)
- [Microsoft Graph Security: Advanced Hunting](https://learn.microsoft.com/en-us/graph/api/security-security-runhuntingquery?view=graph-rest-1.0)
- [Export-ActivityExplorerData](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/export-activityexplorerdata?view=exchange-ps)
- [Export-ContentExplorerData](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/exportcontentexplorerdata?view=exchange-ps)
- [Data Explorer](https://learn.microsoft.com/en-us/purview/data-classification-data-explorer)

Calculation rules:

- Email: retain `Send`, `Receive`, `Read`, meetings, and dates separately. For a rate, state whether the denominator is sent, received, or `Send + Receive`.
- Files: do not mix total and active files. Growth is calculated between dates in the same series.
- Labeling: distinguish label applied, changed, downgraded, removed, and auto-applied events.
- DLP: normalize by volume and workload; do not combine incompatible events.
- Content/Data Explorer: these are snapshots and may have latency. Record the extraction time.

## 9. Rules for manual inputs

A manual override is valid only when it includes:

- `score`: integer from 0 to 4.
- `reason`: explanation of the criterion.
- `evidence`: verifiable reference.
- `approvedBy`: accountable approver.
- `approvedOn`: ISO 8601 date.
- `expiresOn`: revalidation date.

Expired overrides must not participate in the score. Changing a weight requires increasing the model version and recording the rationale in `changeLog`.

## 10. Quality and privacy criteria

- Store only local JSON under `Collected Data`.
- Avoid detailed personal data; prefer aggregated counts.
- Apply restricted access and a defined retention period to the repository.
- Record errors and unavailable sources in the manifest.
- Keep the SHA-256 hash of the scoring configuration used for every run.
- Do not enable Advanced Hunting queries unless they have been reviewed to end in aggregation (`summarize`) and avoid identities or content.
- Do not interpret a missing license or permission as the absence of a control.

## 11. Risks the score should expose

1. **False sense of coverage:** policies in simulation mode, narrow scope, or unlicensed users.
2. **Overprotection:** excessive encryption or restrictions that prevent collaboration and recovery.
3. **Underprotection:** labels published without encryption, DLP without actions, or workloads out of scope.
4. **Insufficient telemetry:** inability to demonstrate adoption, detect misuse, or respond to incidents.
5. **Volume bias:** rewarding the number of rules/labels instead of coverage and effectiveness.
6. **AI risk:** sensitive data accessible to AI experiences without verifiable governance, classification, or minimization.

## 12. Recommended cycle

1. Run `Basic` and complete eligible licensing and target population settings.
2. Resolve materially relevant `Unavailable` sources.
3. Run `Intermediate` for retention, IRM, and activity evidence.
4. Selectively enable `Full` sources after reviewing permissions and queries.
5. Calculate score and confidence; validate manual inputs with the DPO and service owners.
6. Record an improvement plan, repeat the measurement, and compare results using the same model version.

