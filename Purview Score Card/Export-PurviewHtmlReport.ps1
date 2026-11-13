#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunPath,

    [string]$ExportedDataPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-HtmlSafe {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-DisplayText {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-ObjectValue {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Property)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Property] }
    $itemProperty = $Object.PSObject.Properties[$Property]
    if ($null -eq $itemProperty) { return $null }
    return $itemProperty.Value
}

function ConvertTo-HtmlTable {
    param(
        [AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][object[]]$Columns,
        [string]$EmptyMessage = 'No records were observed.'
    )

    $items = @($Rows)
    if ($items.Count -eq 0) { return '<div class="empty">' + (ConvertTo-HtmlSafe $EmptyMessage) + '</div>' }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($column in $Columns) { [void]$builder.Append('<th>' + (ConvertTo-HtmlSafe $column.Label) + '</th>') }
    [void]$builder.Append('</tr></thead><tbody>')
    foreach ($row in $items) {
        [void]$builder.Append('<tr>')
        foreach ($column in $Columns) {
            $value = Get-ObjectValue -Object $row -Property ([string]$column.Property)
            [void]$builder.Append('<td>' + (ConvertTo-HtmlSafe (ConvertTo-DisplayText $value)) + '</td>')
        }
        [void]$builder.Append('</tr>')
    }
    [void]$builder.Append('</tbody></table></div>')
    return $builder.ToString()
}

function ConvertTo-KeyValueCards {
    param([AllowNull()]$Object, [Parameter(Mandatory)][object[]]$Fields)
    if ($null -eq $Object) { return '<div class="empty">Source unavailable.</div>' }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('<div class="metric-grid">')
    foreach ($field in $Fields) {
        $value = Get-ObjectValue -Object $Object -Property ([string]$field.Property)
        [void]$builder.Append('<div class="metric"><span>' + (ConvertTo-HtmlSafe $field.Label) + '</span><strong>' + (ConvertTo-HtmlSafe (ConvertTo-DisplayText $value)) + '</strong></div>')
    }
    [void]$builder.Append('</div>')
    return $builder.ToString()
}

function Write-AtomicText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString('N')))
    try {
        Set-Content -LiteralPath $temporaryPath -Value $Content -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

$resolvedRunPath = (Resolve-Path -LiteralPath $RunPath).Path
$manifestPath = Join-Path $resolvedRunPath 'Run-Manifest.json'
$configurationPath = Join-Path $resolvedRunPath 'Score-Configuration.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Run manifest not found: $manifestPath" }
if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { throw "Score configuration snapshot not found: $configurationPath" }
if ([string]::IsNullOrWhiteSpace($ExportedDataPath)) { $ExportedDataPath = Join-Path $PSScriptRoot 'Exported Data' }

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
$configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json -Depth 100
$evidence = @{}
foreach ($item in @($manifest.evidence)) {
    $path = Join-Path $resolvedRunPath ([string]$item.file)
    if (Test-Path -LiteralPath $path -PathType Leaf) { $evidence[[string]$item.name] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 100 -AsHashtable }
}

function Get-EvidenceRows {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $evidence.ContainsKey($Name)) { return @() }
    return @($evidence[$Name].data)
}

$validStatuses = @('Observed', 'NotObserved', 'Imported', 'ManualApproved')
$validEvidenceCount = @($manifest.evidence | Where-Object { $_.status -in $validStatuses }).Count
$sourceCount = [int]$manifest.summary.sourceCount
$evidenceConfidence = if ($sourceCount -gt 0) { [Math]::Round(($validEvidenceCount / $sourceCount) * 100, 1) } else { 0 }
$dlpPolicies = @(Get-EvidenceRows 'DLPPolicies')
$dlpRules = @(Get-EvidenceRows 'DLPRules')
$labels = @(Get-EvidenceRows 'SensitivityLabels')
$labelPolicies = @(Get-EvidenceRows 'LabelPolicies')
$skus = @(Get-EvidenceRows 'SubscribedSkus')
$directoryCoverage = @(Get-EvidenceRows 'DirectoryCoverage') | Select-Object -First 1
$emailActivity = @(Get-EvidenceRows 'EmailActivityCounts') | Select-Object -First 1
$oneDriveActivity = @(Get-EvidenceRows 'OneDriveFileCounts') | Select-Object -First 1
$sharePointActivity = @(Get-EvidenceRows 'SharePointFileCounts') | Select-Object -First 1

$dlpPolicyTable = ConvertTo-HtmlTable -Rows $dlpPolicies -Columns @(
    [pscustomobject]@{ Property = 'Name'; Label = 'Policy' }, [pscustomobject]@{ Property = 'Enabled'; Label = 'Enabled' }, [pscustomobject]@{ Property = 'Mode'; Label = 'Mode' }, [pscustomobject]@{ Property = 'Workload'; Label = 'Workload' }, [pscustomobject]@{ Property = 'ScopeClassification'; Label = 'Application / Copilot scope' }, [pscustomobject]@{ Property = 'CopilotTenantWide'; Label = 'Copilot tenant-wide' }, [pscustomobject]@{ Property = 'Priority'; Label = 'Priority' }, [pscustomobject]@{ Property = 'DistributionStatus'; Label = 'Distribution detail' }, [pscustomobject]@{ Property = 'DistributionResults'; Label = 'Distribution results' }, [pscustomobject]@{ Property = 'WhenChangedUTC'; Label = 'Last changed' }
)
$dlpRuleTable = ConvertTo-HtmlTable -Rows $dlpRules -Columns @(
    [pscustomobject]@{ Property = 'Name'; Label = 'Rule' }, [pscustomobject]@{ Property = 'Policy'; Label = 'Policy' }, [pscustomobject]@{ Property = 'Disabled'; Label = 'Disabled' }, [pscustomobject]@{ Property = 'Mode'; Label = 'Mode' }, [pscustomobject]@{ Property = 'Priority'; Label = 'Priority' }, [pscustomobject]@{ Property = 'SensitiveInformationReferenceCount'; Label = 'Sensitive types' }, [pscustomobject]@{ Property = 'SensitiveInformationReferences'; Label = 'SIT references / confidence' }, [pscustomobject]@{ Property = 'HasBlockingOrRestrictionAction'; Label = 'Blocking / restriction action' }, [pscustomobject]@{ Property = 'ActionSignals'; Label = 'Action evidence' }, [pscustomobject]@{ Property = 'NotifyUser'; Label = 'User notification' }, [pscustomobject]@{ Property = 'GenerateAlert'; Label = 'Alert' }
)
$labelTable = ConvertTo-HtmlTable -Rows $labels -Columns @(
    [pscustomobject]@{ Property = 'DisplayName'; Label = 'Label' }, [pscustomobject]@{ Property = 'ParentLabelDisplayName'; Label = 'Parent' }, [pscustomobject]@{ Property = 'Priority'; Label = 'Priority' }, [pscustomobject]@{ Property = 'ContentType'; Label = 'Content type' }, [pscustomobject]@{ Property = 'Tooltip'; Label = 'Description' }, [pscustomobject]@{ Property = 'LabelActions'; Label = 'Actions / protection' }
)
$labelPolicyTable = ConvertTo-HtmlTable -Rows $labelPolicies -Columns @(
    [pscustomobject]@{ Property = 'Name'; Label = 'Policy' }, [pscustomobject]@{ Property = 'Enabled'; Label = 'Enabled' }, [pscustomobject]@{ Property = 'Mode'; Label = 'Mode' }, [pscustomobject]@{ Property = 'Labels'; Label = 'Labels' }, [pscustomobject]@{ Property = 'ExchangeLocation'; Label = 'Exchange scope' }, [pscustomobject]@{ Property = 'DistributionStatus'; Label = 'Distribution' }
)
$skuTable = ConvertTo-HtmlTable -Rows $skus -Columns @(
    [pscustomobject]@{ Property = 'SkuPartNumber'; Label = 'SKU' }, [pscustomobject]@{ Property = 'CapabilityStatus'; Label = 'Status' }, [pscustomobject]@{ Property = 'ConsumedUnits'; Label = 'Consumed' }, [pscustomobject]@{ Property = 'PrepaidUnits'; Label = 'Available' }
)
$directoryCards = ConvertTo-KeyValueCards -Object $directoryCoverage -Fields @(
    [pscustomobject]@{ Property = 'activeMemberUsers'; Label = 'Active member users' }, [pscustomobject]@{ Property = 'activeMemberUsersWithAnyLicense'; Label = 'Active licensed users' }, [pscustomobject]@{ Property = 'generalLicenseCoverageRatio'; Label = 'General license coverage' }, [pscustomobject]@{ Property = 'activeGuestUsers'; Label = 'Active guests' }, [pscustomobject]@{ Property = 'disabledUsers'; Label = 'Disabled users' }, [pscustomobject]@{ Property = 'eligibleLicenseEvidenceStatus'; Label = 'Eligible Purview license' }
)
$emailTotals = Get-ObjectValue -Object $emailActivity -Property 'totals'
$oneDriveTotals = Get-ObjectValue -Object $oneDriveActivity -Property 'totals'
$sharePointTotals = Get-ObjectValue -Object $sharePointActivity -Property 'totals'
$emailCards = ConvertTo-KeyValueCards -Object $emailTotals -Fields @(
    [pscustomobject]@{ Property = 'Send'; Label = 'Emails sent' }, [pscustomobject]@{ Property = 'Receive'; Label = 'Emails received' }, [pscustomobject]@{ Property = 'Read'; Label = 'Emails read' }, [pscustomobject]@{ Property = 'Meeting Created'; Label = 'Meetings created' }
)
$oneDriveCards = ConvertTo-KeyValueCards -Object $oneDriveTotals -Fields @([pscustomobject]@{ Property = 'Total'; Label = 'Total files' }, [pscustomobject]@{ Property = 'Active'; Label = 'Active files' })
$sharePointCards = ConvertTo-KeyValueCards -Object $sharePointTotals -Fields @([pscustomobject]@{ Property = 'Total'; Label = 'Total files' }, [pscustomobject]@{ Property = 'Active'; Label = 'Active files' })

$evidenceRows = foreach ($item in @($manifest.evidence)) { [pscustomobject]@{ name = $item.name; source = $item.source; status = $item.status; recordCount = $item.recordCount; durationSeconds = $item.durationSeconds; message = $item.message } }
$evidenceTable = ConvertTo-HtmlTable -Rows @($evidenceRows) -Columns @(
    [pscustomobject]@{ Property = 'name'; Label = 'Source' }, [pscustomobject]@{ Property = 'source'; Label = 'Service' }, [pscustomobject]@{ Property = 'status'; Label = 'Status' }, [pscustomobject]@{ Property = 'recordCount'; Label = 'Records' }, [pscustomobject]@{ Property = 'durationSeconds'; Label = 'Seconds' }, [pscustomobject]@{ Property = 'message'; Label = 'Details' }
)
$dimensionRows = foreach ($dimension in @($configuration.dimensions)) { [pscustomobject]@{ id = $dimension.id; name = $dimension.name; weight = $dimension.weight; metrics = @($dimension.metrics).Count; metricIds = (@($dimension.metrics | ForEach-Object id) -join ', ') } }
$dimensionTable = ConvertTo-HtmlTable -Rows @($dimensionRows) -Columns @(
    [pscustomobject]@{ Property = 'id'; Label = 'Dimension' }, [pscustomobject]@{ Property = 'name'; Label = 'Name' }, [pscustomobject]@{ Property = 'weight'; Label = 'Weight' }, [pscustomobject]@{ Property = 'metrics'; Label = 'Metrics' }, [pscustomobject]@{ Property = 'metricIds'; Label = 'IDs' }
)
$extendedNames = @('IRMConfiguration', 'RMSTrustedPublishingDomains', 'RMSTemplates', 'IRMTransportRules', 'RetentionLabels', 'RetentionPolicies', 'RetentionRules', 'SensitiveInformationTypes', 'SensitiveInformationTypeRulePackages', 'DlpRuleSitValidation', 'ActivityExplorerAggregate', 'InformationBarrierSegments', 'InformationBarrierPolicies', 'CommunicationCompliancePolicies', 'AdvancedHuntingAggregate', 'ContentExplorerAggregate', 'eDiscoveryCases', 'InsiderRiskCases', 'ImportedInsiderRiskPolicyExport', 'PurviewRoleGroups', 'PurviewDiagnosticExport')
$extendedRows = foreach ($name in $extendedNames) { $item = @($manifest.evidence | Where-Object name -eq $name) | Select-Object -First 1; if ($null -ne $item) { [pscustomobject]@{ capability = $name; status = $item.status; records = $item.recordCount; detail = $item.message } } }
$extendedTable = ConvertTo-HtmlTable -Rows @($extendedRows) -Columns @(
    [pscustomobject]@{ Property = 'capability'; Label = 'Capability' }, [pscustomobject]@{ Property = 'status'; Label = 'Status' }, [pscustomobject]@{ Property = 'records'; Label = 'Records' }, [pscustomobject]@{ Property = 'detail'; Label = 'Details' }
) -EmptyMessage 'The selected profile does not include extended capabilities.'

$generatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')
$reportName = 'Purview-Assessment-{0}.html' -f $manifest.runId
$reportPath = Join-Path $ExportedDataPath $reportName
$latestName = if ([bool]$manifest.dryRun) { 'Purview-Assessment-Latest-DryRun.html' } else { 'Purview-Assessment-Latest.html' }
$latestPath = Join-Path $ExportedDataPath $latestName
$statusClass = if ($evidenceConfidence -ge 90) { 'good' } elseif ($evidenceConfidence -ge 60) { 'warn' } else { 'bad' }

$html = @"
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Microsoft Purview Assessment</title>
<style>:root{--navy:#132238;--blue:#2764e7;--bg:#f4f7fb;--card:#fff;--text:#172133;--muted:#627086;--line:#dde5ef;--good:#16845b;--warn:#b46b0b;--bad:#b73a45}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:Segoe UI,Arial,sans-serif}header{background:linear-gradient(120deg,var(--navy),#234d79);color:#fff;padding:34px 5vw 28px}header h1{margin:0 0 8px;font-size:30px}header p{margin:0;color:#dbe7f5}.meta{margin-top:18px;display:flex;gap:18px;flex-wrap:wrap;font-size:13px}.meta span{background:#ffffff18;padding:7px 10px;border:1px solid #ffffff25;border-radius:8px}.tabs{position:sticky;top:0;z-index:5;background:#fff;border-bottom:1px solid var(--line);display:flex;gap:4px;padding:10px 5vw;overflow:auto}.tabs button{border:0;background:transparent;padding:10px 14px;color:var(--muted);font-weight:600;cursor:pointer;border-radius:8px;white-space:nowrap}.tabs button.active{background:#e9f0ff;color:var(--blue)}main{padding:24px 5vw 60px;max-width:1600px;margin:auto}.panel{display:none}.panel.active{display:block}.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px;margin-bottom:18px;box-shadow:0 5px 18px #18324a0a}.card h2,.card h3{margin-top:0}.score-grid,.metric-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.score,.metric{background:#f8fafe;border:1px solid var(--line);border-radius:11px;padding:15px}.score span,.metric span{display:block;color:var(--muted);font-size:12px;margin-bottom:7px}.score strong{font-size:28px}.metric strong{font-size:18px;overflow-wrap:anywhere}.good{color:var(--good)}.warn{color:var(--warn)}.bad{color:var(--bad)}.note{padding:13px 15px;border-left:4px solid var(--blue);background:#edf3ff;border-radius:6px;color:#30435d}.empty{padding:18px;color:var(--muted);background:#f8fafe;border-radius:8px}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:10px}table{width:100%;border-collapse:collapse;font-size:13px}th{background:#edf2f8;text-align:left;color:#405069;position:sticky;top:0}th,td{padding:10px 11px;border-bottom:1px solid var(--line);vertical-align:top;max-width:460px;overflow-wrap:anywhere}tr:last-child td{border-bottom:0}tbody tr:hover{background:#f8fbff}.footer{color:var(--muted);font-size:12px;margin-top:30px}code{font-family:Cascadia Mono,Consolas,monospace}</style></head><body>
<header><h1>Microsoft Purview Score Card</h1><p>Observed evidence report — DLP, Information Protection, coverage, and telemetry</p><div class="meta"><span>Run: $(ConvertTo-HtmlSafe $manifest.runId)</span><span>Profile: $(ConvertTo-HtmlSafe $manifest.profile)</span><span>Window: $(ConvertTo-HtmlSafe $manifest.lookbackDays) days</span><span>Generated: $generatedAt</span></div></header>
<nav class="tabs"><button class="active" data-tab="summary">Executive summary</button><button data-tab="dlp">DLP</button><button data-tab="ip">Information Protection</button><button data-tab="coverage">Coverage and usage</button><button data-tab="extended">Extended Purview</button><button data-tab="evidence">Evidence</button><button data-tab="model">Scoring model</button></nav><main>
<section id="summary" class="panel active"><div class="card"><h2>Executive summary</h2><div class="score-grid"><div class="score"><span>Evidence confidence</span><strong class="$statusClass">$evidenceConfidence%</strong></div><div class="score"><span>Observed sources</span><strong>$($manifest.summary.observed)</strong></div><div class="score"><span>Unavailable sources</span><strong>$($manifest.summary.unavailable)</strong></div><div class="score"><span>DLP policies</span><strong>$($dlpPolicies.Count)</strong></div><div class="score"><span>DLP rules</span><strong>$($dlpRules.Count)</strong></div><div class="score"><span>Sensitivity labels</span><strong>$($labels.Count)</strong></div></div></div><div class="card"><h3>Interpretation</h3><div class="note">The Posture Score is not inferred from the number of policies. It is calculated only when coverage, protection, adoption, and monitoring metrics have sufficient evidence or an approved manual input. Unavailable sources reduce evidence confidence but do not automatically produce a zero score.</div></div><div class="card"><h3>Connections</h3><div class="metric-grid"><div class="metric"><span>Security & Compliance</span><strong>$(ConvertTo-HtmlSafe $manifest.connections.complianceReady)</strong></div><div class="metric"><span>Exchange Online</span><strong>$(ConvertTo-HtmlSafe $manifest.connections.exchangeOnlineReady)</strong></div><div class="metric"><span>Microsoft Graph</span><strong>$(ConvertTo-HtmlSafe $manifest.connections.graphReady)</strong></div></div></div></section>
<section id="dlp" class="panel"><div class="card"><h2>DLP policies</h2>$dlpPolicyTable</div><div class="card"><h2>DLP rules</h2>$dlpRuleTable</div></section>
<section id="ip" class="panel"><div class="card"><h2>Sensitivity labels</h2>$labelTable</div><div class="card"><h2>Label publishing policies</h2>$labelPolicyTable</div></section>
<section id="coverage" class="panel"><div class="card"><h2>Directory coverage</h2>$directoryCards</div><div class="card"><h2>Purchased licenses</h2>$skuTable</div><div class="card"><h2>Email — $($manifest.lookbackDays) days</h2>$emailCards</div><div class="card"><h2>OneDrive</h2>$oneDriveCards</div><div class="card"><h2>SharePoint</h2>$sharePointCards</div></section>
<section id="extended" class="panel"><div class="card"><h2>Extended capabilities</h2>$extendedTable</div></section><section id="evidence" class="panel"><div class="card"><h2>Evidence matrix</h2>$evidenceTable</div></section><section id="model" class="panel"><div class="card"><h2>Assessment dimensions</h2>$dimensionTable</div><div class="card"><h3>Score status</h3><div class="note">Model version $(ConvertTo-HtmlSafe $configuration.model.version). The posture score remains pending until the metrics have sufficient evidence. Current evidence confidence: $evidenceConfidence%.</div></div></section><div class="footer">Source: local JSON files under <code>Collected Data</code>. This report does not constitute ISO certification or legal advice.</div></main>
<script>document.querySelectorAll('.tabs button').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('.tabs button').forEach(x=>x.classList.remove('active'));document.querySelectorAll('.panel').forEach(x=>x.classList.remove('active'));button.classList.add('active');document.getElementById(button.dataset.tab).classList.add('active');window.scrollTo({top:0,behavior:'smooth'});}));</script></body></html>
"@

Write-AtomicText -Path $reportPath -Content $html
Copy-Item -LiteralPath $reportPath -Destination $latestPath -Force
$manifest | Add-Member -NotePropertyName report -NotePropertyValue ([pscustomobject]@{
    status = 'Created'
    path = $reportPath
    latestPath = $latestPath
}) -Force
Write-AtomicText -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 100)
Write-Host "HTML report created: $reportPath"
Write-Output $reportPath

