#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RunPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Exported Data')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Document {
    param([string]$Name)
    $path = Join-Path $RunPath ($Name + '.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
}

function As-Array {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value)
    }
    @($Value)
}

function As-Bool {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    [string]$Value -match '^(?i:true|1|yes)$'
}

function Value-Of {
    param([AllowNull()]$Object, [string[]]$Keys)
    if ($Object -isnot [Collections.IDictionary]) { return $null }
    foreach ($key in $Keys) {
        if ($Object.Contains($key)) { return $Object[$key] }
    }
    $null
}

function ConvertTo-HtmlSafe {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-StaticValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -or $Value -is [ValueType]) { return (ConvertTo-HtmlSafe $Value) }
    if ($Value -is [Collections.IDictionary]) { return (ConvertTo-HtmlSafe ($Value | ConvertTo-Json -Compress -Depth 20)) }
    $items = @($Value | ForEach-Object {
        if ($_ -is [Collections.IDictionary]) { $_ | ConvertTo-Json -Compress -Depth 20 } else { [string]$_ }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    ConvertTo-HtmlSafe ($items -join '; ')
}

function New-StaticTable {
    param(
        [object[]]$Rows,
        [Collections.IDictionary[]]$Columns
    )
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($column in $Columns) { [void]$builder.Append('<th>' + (ConvertTo-HtmlSafe $column['Header']) + '</th>') }
    [void]$builder.Append('</tr></thead><tbody>')
    foreach ($row in @($Rows)) {
        [void]$builder.Append('<tr>')
        foreach ($column in $Columns) {
            $value = if ($row -is [Collections.IDictionary]) { Value-Of $row @([string]$column['Key']) } else { $row.([string]$column['Key']) }
            [void]$builder.Append('<td>' + (Format-StaticValue $value) + '</td>')
        }
        [void]$builder.Append('</tr>')
    }
    [void]$builder.Append('</tbody></table></div>')
    $builder.ToString()
}

function New-StaticMetric {
    param([string]$Label, [AllowNull()]$Value, [string]$Note = '')
    '<div class="metric"><small>' + (ConvertTo-HtmlSafe $Label) + '</small><strong>' + (ConvertTo-HtmlSafe $Value) + '</strong><em>' + (ConvertTo-HtmlSafe $Note) + '</em></div>'
}

function Get-LabelActions {
    param([Collections.IDictionary]$Label)
    $result = [Collections.Generic.List[object]]::new()
    foreach ($raw in @(As-Array $Label['LabelActions'])) {
        $action = $raw
        if ($raw -is [string]) {
            try { $action = $raw | ConvertFrom-Json -AsHashtable -Depth 30 } catch { continue }
        }
        if ($action -isnot [Collections.IDictionary]) { continue }
        $settings = @{}
        foreach ($setting in @(As-Array $action['Settings'])) {
            if ($setting -is [Collections.IDictionary] -and $setting['Key']) {
                $settings[[string]$setting['Key'].ToLowerInvariant()] = [string]$setting['Value']
            }
        }
        $result.Add([ordered]@{ type=[string]$action['Type']; subtype=[string]$action['SubType']; settings=$settings })
    }
    @($result)
}

function Get-PolicyWorkloads {
    param([Collections.IDictionary]$Policy)
    $name = [string]$Policy['Name']
    $declared = [string]$Policy['Workload']
    $result = [Collections.Generic.List[string]]::new()
    if (As-Bool $Policy['CopilotTenantWide']) { $result.Add('Copilot') }
    if ($name -match '^(?i)EXO\b|Exchange') { $result.Add('EXO') }
    if ($name -match '^(?i)SPO\b|SharePoint') { $result.Add('SPO') }
    if ($name -match '^(?i)ODB\b|OneDrive') { $result.Add('ODB') }
    if ($name -match '^(?i)Teams\b' -or $name -match '(?i)Teams and Exchange') { $result.Add('Teams') }
    if ($name -match '(?i)Endpoint|EDLP|AI sites' -and $declared -match 'EndpointDevices') { $result.Add('Endpoint') }
    if ($name -match '(?i)Teams and Exchange') { $result.Add('EXO') }
    if ($result.Count -eq 0) {
        if ($declared -match 'Applications') { $result.Add('Copilot') }
        if ($declared -match 'EndpointDevices') { $result.Add('Endpoint') }
        if ($declared -match 'Teams') { $result.Add('Teams') }
    }
    @($result | Sort-Object -Unique)
}

function Get-ActionText {
    param([Collections.IDictionary]$Rule)
    $signals = @(As-Array $Rule['ActionSignals'])
    $names = @($signals | ForEach-Object { [string](Value-Of $_ @('property','Property')) } | Where-Object { $_ })
    $display = [Collections.Generic.List[string]]::new()
    if (As-Bool $Rule['HasBlockingOrRestrictionAction']) { $display.Add('Block / restrict') }
    if ($names -contains 'GenerateIncidentReport') { $display.Add('Incident report') }
    if ($names -contains 'GenerateAlert') { $display.Add('Alert') }
    if ($names -contains 'NotifyUser') { $display.Add('User notification') }
    if ($names -contains 'NotifyAllowOverride') { $display.Add('Override') }
    if ($display.Count -eq 0 -and $signals.Count) { $display.Add('Other response action') }
    if ($display.Count -eq 0) { $display.Add('No response action evidenced') }
    @($display | Sort-Object -Unique)
}

function Get-RuleReferences {
    param([Collections.IDictionary]$Rule)
    @(
        foreach ($ref in @(As-Array $Rule['SensitiveInformationReferences'])) {
            if ($ref -isnot [Collections.IDictionary]) { continue }
            $id = [string](Value-Of $ref @('id','Id','SitId'))
            $name = [string](Value-Of $ref @('name','Name','SitName'))
            $min = Value-Of $ref @('minConfidence','minconfidence','MinConfidence')
            $level = [string](Value-Of $ref @('confidenceLevel','confidencelevel','ConfidenceLevel'))
            $count = Value-Of $ref @('minCount','mincount','MinCount')
            [ordered]@{ id=$id; name=$name; minConfidence=$min; confidenceLevel=$level; minCount=$count }
        }
    )
}

function Write-Report {
    param(
        [string]$Path,
        [string]$Title,
        [string]$Kicker,
        [string]$Subtitle,
        [string]$ActivePage,
        [string]$PageScript,
        [string]$DataJson,
        [string]$FallbackHtml,
        [string]$MetaHtml
    )
    $template = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>__TITLE__</title>
<style>
:root{--ink:#172033;--muted:#647187;--navy:#102743;--navy2:#1c466e;--blue:#2968df;--bg:#f4f7fb;--card:#fff;--line:#dbe4ef;--good:#147a57;--warn:#a76508;--bad:#b33843;--info:#245eaa;--soft:#edf3fb}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--ink);font-family:Segoe UI,Arial,sans-serif;line-height:1.45}a{color:var(--blue)}.hero{background:linear-gradient(125deg,var(--navy),var(--navy2));color:#fff;padding:34px max(4vw,24px) 28px}.eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:12px;color:#bed4eb}.hero h1{margin:7px 0 9px;font-size:clamp(26px,3vw,38px);line-height:1.12}.hero p{margin:0;max-width:1050px;color:#dce8f4}.meta{display:flex;gap:9px;flex-wrap:wrap;margin-top:18px}.meta span{border:1px solid #ffffff28;background:#ffffff12;border-radius:999px;padding:6px 10px;font-size:12px}.suite-nav{position:sticky;top:0;z-index:20;display:flex;gap:8px;align-items:center;overflow:auto;padding:10px max(4vw,24px);background:#fff;border-bottom:1px solid var(--line);box-shadow:0 2px 10px #13243b0a}.suite-nav a{white-space:nowrap;text-decoration:none;color:var(--muted);font-weight:650;padding:9px 12px;border-radius:8px}.suite-nav a.active{background:#e8f0ff;color:#1d55b2}.suite-nav .spacer{flex:1}.suite-nav .raw{font-size:12px}main{max-width:1600px;margin:auto;padding:24px max(4vw,24px) 60px}.section{margin:0 0 26px}.section-head{display:flex;justify-content:space-between;gap:18px;align-items:end;margin-bottom:12px}.section-head h2{margin:0;font-size:22px}.section-head p{margin:4px 0 0;color:var(--muted);max-width:920px}.grid{display:grid;gap:14px}.grid.two{grid-template-columns:repeat(2,minmax(0,1fr))}.grid.three{grid-template-columns:repeat(3,minmax(0,1fr))}.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(165px,1fr));gap:11px}.card{background:var(--card);border:1px solid var(--line);border-radius:13px;padding:18px;box-shadow:0 5px 18px #142b4508}.card h3{margin:0 0 9px;font-size:17px}.metric{background:#f8fafe;border:1px solid var(--line);border-radius:10px;padding:14px}.metric small{display:block;color:var(--muted);margin-bottom:5px}.metric strong{display:block;font-size:24px;line-height:1.2;overflow-wrap:anywhere}.metric em{display:block;color:var(--muted);font-size:12px;font-style:normal;margin-top:5px}.callout{padding:13px 15px;border-left:4px solid var(--info);background:#eef4fd;border-radius:7px}.callout.warn{border-color:var(--warn);background:#fff6e7}.callout.bad{border-color:var(--bad);background:#fff0f2}.callout.good{border-color:var(--good);background:#eaf8f2}.badge{display:inline-block;padding:3px 8px;border-radius:999px;font-size:11px;font-weight:700;background:#edf1f6;color:#526174;white-space:nowrap}.badge.good{background:#dff4eb;color:#096744}.badge.warn{background:#fff0d4;color:#8b5100}.badge.bad{background:#fde5e8;color:#982b37}.badge.info{background:#e4efff;color:#1d57a5}.chips{display:flex;gap:4px;flex-wrap:wrap}.chip{background:#eef2f7;border-radius:999px;padding:2px 7px;font-size:11px}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:10px;background:#fff}table{width:100%;border-collapse:collapse;font-size:12.5px}th,td{padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top;text-align:left;max-width:520px;overflow-wrap:anywhere}th{background:#edf2f8;color:#40506a;position:sticky;top:0;z-index:1}tbody tr:hover{background:#f8fbff}.filters{display:flex;gap:10px;flex-wrap:wrap;align-items:end;margin:0 0 12px}.filters label{display:grid;gap:4px;color:var(--muted);font-size:12px}.filters select,.filters input{min-width:170px;border:1px solid var(--line);border-radius:8px;padding:8px 9px;background:#fff;color:var(--ink)}.filters .count{margin-left:auto;color:var(--muted);padding:8px 0}.bar-row{display:grid;grid-template-columns:minmax(150px,260px) 1fr 58px;gap:9px;align-items:center;margin:8px 0}.bar-label{font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.bar-track{height:10px;background:#e8edf4;border-radius:999px;overflow:hidden}.bar-fill{height:100%;background:#2d69d7;border-radius:999px}.bar-value{text-align:right;font-variant-numeric:tabular-nums;font-size:12px}.workload-grid{display:grid;grid-template-columns:repeat(7,minmax(120px,1fr));gap:8px;overflow:auto}.workload{min-width:120px;border:1px solid var(--line);border-radius:10px;padding:12px;background:#fafcff}.workload strong{display:block;margin-bottom:8px}.workload small{display:block;color:var(--muted);margin-top:7px}.meter{height:8px;background:#e8edf4;border-radius:99px;overflow:hidden;margin:7px 0}.meter span{display:block;height:100%;background:#2d69d7}.muted{color:var(--muted)}details summary{cursor:pointer;color:var(--blue);font-weight:600}.priority{margin:0;padding-left:22px}.priority li{margin:0 0 9px}.footer{margin-top:30px;color:var(--muted);font-size:12px}.footnav{display:flex;gap:10px;flex-wrap:wrap;margin-top:16px}.footnav a{text-decoration:none;border:1px solid var(--line);background:#fff;padding:8px 11px;border-radius:8px}.hidden{display:none!important}@media(max-width:900px){.grid.two,.grid.three{grid-template-columns:1fr}.workload-grid{grid-template-columns:repeat(7,150px)}.bar-row{grid-template-columns:120px 1fr 45px}}@media print{.suite-nav,.filters{display:none}.hero{padding:22px}main{padding:16px}.card{box-shadow:none;break-inside:avoid}.table-wrap{overflow:visible}th{position:static}}
</style></head><body>
<header class="hero"><div class="eyebrow">__KICKER__</div><h1>__TITLE__</h1><p>__SUBTITLE__</p><div class="meta" id="meta">__META__</div></header>
<nav class="suite-nav" aria-label="Report suite"><a data-page="executive" href="__EXECUTIVE__">Executive overview</a><a data-page="protection" href="__PROTECTION__">Data protection deep dive</a><a data-page="governance" href="__GOVERNANCE__">Governance &amp; operations</a><span class="spacer"></span><a class="raw" href="__RAW__">Collected evidence</a></nav>
<main id="app">__FALLBACK__</main>
<script>const DATA=__DATA__;
const $=s=>document.querySelector(s), arr=v=>v==null?[]:Array.isArray(v)?v:[v];
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function badge(v){const x=String(v??'Unknown');let c='';if(/Observed|Success|Enforced|Organization-wide|Supported|Active protection|Complete/i.test(x))c='good';else if(/Unavailable|Gap|Failed|Missing|Disabled|Not collected|No response/i.test(x))c='bad';else if(/Pending|Test|Simulation|Scoped|Inconclusive|Unknown|NotObserved|Not observed/i.test(x))c='warn';else c='info';return `<span class="badge ${c}">${esc(x)}</span>`}
function chips(xs){return `<div class="chips">${arr(xs).map(x=>`<span class="chip">${esc(x)}</span>`).join('')}</div>`}
function metric(label,value,note=''){return `<div class="metric"><small>${esc(label)}</small><strong>${esc(value)}</strong><em>${esc(note)}</em></div>`}
function table(headers,rows){return `<div class="table-wrap"><table><thead><tr>${headers.map(h=>`<th>${esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>`}
function bars(items,label='name',value='value'){const max=Math.max(1,...items.map(x=>Number(x[value])||0));return items.map(x=>`<div class="bar-row"><div class="bar-label" title="${esc(x[label])}">${esc(x[label])}</div><div class="bar-track"><div class="bar-fill" style="width:${Math.round((Number(x[value])||0)/max*100)}%"></div></div><div class="bar-value">${esc(x[value])}</div></div>`).join('')}
document.querySelector(`[data-page="__ACTIVE__"]`).classList.add('active');
$('#meta').innerHTML=`<span>Run: ${esc(DATA.run.id)}</span><span>Profile: ${esc(DATA.run.profile)}</span><span>Window: ${esc(DATA.run.lookback)} days</span><span>Generated: ${esc(DATA.run.generated)}</span>`;
__PAGE_SCRIPT__
</script></body></html>
'@
    $html = $template.Replace('__TITLE__',$Title).Replace('__KICKER__',$Kicker).Replace('__SUBTITLE__',$Subtitle).Replace('__META__',$MetaHtml).Replace('__FALLBACK__',$FallbackHtml).Replace('__ACTIVE__',$ActivePage).Replace('__DATA__',$DataJson).Replace('__PAGE_SCRIPT__',$PageScript).Replace('__EXECUTIVE__',$script:ExecutiveName).Replace('__PROTECTION__',$script:ProtectionName).Replace('__GOVERNANCE__',$script:GovernanceName).Replace('__RAW__',$script:RawRelative)
    [IO.File]::WriteAllText($Path, $html, [Text.UTF8Encoding]::new($false))
}

if ([string]::IsNullOrWhiteSpace($RunPath)) {
    $collectedDataPath = Join-Path $PSScriptRoot 'Collected Data'
    $runCandidates = @(
        Get-ChildItem -LiteralPath $collectedDataPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Run-Manifest.json') -PathType Leaf }
    )
    if ($runCandidates.Count -eq 1) {
        $RunPath = $runCandidates[0].FullName
        Write-Host "Using the only collected run: $RunPath" -ForegroundColor Cyan
    } elseif ($runCandidates.Count -eq 0) {
        throw "No collected run containing Run-Manifest.json was found under: $collectedDataPath"
    } else {
        $choices = ($runCandidates.FullName | Sort-Object) -join [Environment]::NewLine
        throw "Multiple collected runs were found. Re-run with -RunPath and select one of these paths:$([Environment]::NewLine)$choices"
    }
}
$RunPath = [IO.Path]::GetFullPath($RunPath)
if (-not (Test-Path -LiteralPath $RunPath -PathType Container)) { throw "Run path not found: $RunPath" }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$manifest = Read-Document 'Run-Manifest'
if ($null -eq $manifest) { throw 'Run-Manifest.json is required.' }
$runId = [string]$manifest['runId']
$script:ExecutiveName = "Purview-Executive-Overview-$runId.html"
$script:ProtectionName = "Purview-Data-Protection-Deep-Dive-$runId.html"
$script:GovernanceName = "Purview-Governance-Operations-$runId.html"
$script:RawRelative = '../Collected Data/' + $runId + '/Run-Manifest.json'

$docs = @{}
foreach ($name in @('DLPPolicies','DLPRules','SensitiveInformationTypeRulePackages','SensitivityLabels','LabelPolicies','DirectoryCoverage','SubscribedSkus','EmailActivityCounts','OneDriveFileCounts','SharePointFileCounts','ActivityExplorerAggregate','AdvancedHuntingAggregate','ContentExplorerAggregate','IRMConfiguration','RMSTemplates','IRMTransportRules','RetentionLabels','RetentionPolicies','RetentionRules','InformationBarrierSegments','InformationBarrierPolicies','CommunicationCompliancePolicies','eDiscoveryCases','InsiderRiskCases','PurviewRoleGroups','PurviewDiagnosticExport')) { $docs[$name] = Read-Document $name }

$rawPolicies = @(As-Array (Value-Of $docs.DLPPolicies @('data')))
$rawRules = @(As-Array (Value-Of $docs.DLPRules @('data')))
$rulePackages = @(As-Array (Value-Of $docs.SensitiveInformationTypeRulePackages @('data')))
$policyMap = @{}; foreach ($p in $rawPolicies) { $policyMap[[string]$p.Guid] = $p }
$packageMap = @{}; foreach ($s in $rulePackages) { if ($s.SitId) { $packageMap[[string]$s.SitId] = $s } }

$policies = @(
    foreach ($p in $rawPolicies) {
        $workloads = @(Get-PolicyWorkloads $p)
        $related = @($rawRules | Where-Object { [string]$_.Policy -eq [string]$p.Guid })
        $scope = if (As-Bool $p.CopilotTenantWide) { 'Organization-wide' } elseif ($workloads.Count) { 'Workload inferred; population not exported' } else { 'Scope not evidenced' }
        [ordered]@{name=[string]$p.Name;guid=[string]$p.Guid;enabled=(As-Bool $p.Enabled);mode=[string]$p.Mode;workloads=$workloads;declared=[string]$p.Workload;scope=$scope;scopeEvidence=[string]$p.ScopeClassification;copilotTenantWide=(As-Bool $p.CopilotTenantWide);distribution=[string]$p.DistributionStatus;priority=$p.Priority;rules=$related.Count;changed=[string]$p.WhenChangedUTC;comment=[string]$p.Comment}
    }
)

$rules = @(
    foreach ($r in $rawRules) {
        $p = $policyMap[[string]$r.Policy]
        $workloads = if ($p) { @(Get-PolicyWorkloads $p) } else { @() }
        $refs = @(Get-RuleReferences $r)
        $enabled = -not (As-Bool $r.Disabled)
        $policyEnabled = $null -ne $p -and (As-Bool $p.Enabled) -and [string]$p.Mode -ne 'Disable'
        $simulation = $policyEnabled -and [string]$p.Mode -match '^Test'
        $blocking = As-Bool $r.HasBlockingOrRestrictionAction
        $actions = @(Get-ActionText $r)
        $state = if (-not $enabled) {'Rule disabled'} elseif (-not $policyEnabled) {'Policy disabled / unresolved'} elseif ($simulation -and $blocking) {'Simulation with blocking configured'} elseif ($simulation) {'Simulation / audit'} elseif ($blocking) {'Enforced prevention'} elseif ($actions -notcontains 'No response action evidenced') {'Active detection / notification'} else {'Active; no response action evidenced'}
        $validation = @(
            foreach ($ref in $refs) {
                $pkg = $packageMap[[string]$ref.id]
                $required = 0
                if ($ref.minConfidence -as [int]) { $required = [int]$ref.minConfidence }
                elseif ($ref.confidenceLevel -match '(?i)Low') { $required = 65 }
                elseif ($ref.confidenceLevel -match '(?i)Medium') { $required = 75 }
                elseif ($ref.confidenceLevel -match '(?i)High') { $required = 85 }
                $levels = if ($pkg) { @($pkg.PatternConfidenceLevels | ForEach-Object { [int]$_ }) } else { @() }
                $status = if (-not $pkg) {'Definition not resolved'} elseif ($required -eq 0) {'Confidence not specified'} elseif ($required -in $levels) {'Supported'} else {'Requested confidence missing'}
                [ordered]@{id=$ref.id;name=$ref.name;required=$required;available=$levels;status=$status}
            }
        )
        $badRefs = @($validation | Where-Object status -eq 'Requested confidence missing').Count
        [ordered]@{name=[string]$r.Name;guid=[string]$r.Guid;policy=$(if($p){[string]$p.Name}else{[string]$r.Policy});policyGuid=[string]$r.Policy;enabled=$enabled;effective=($enabled -and $policyEnabled);simulation=$simulation;blocking=$blocking;state=$state;workloads=$workloads;scope=$(if($r.AccessScope){[string]$r.AccessScope}elseif($p -and (As-Bool $p.CopilotTenantWide)){'Organization-wide'}else{'Policy scope'});sitCount=$refs.Count;sits=$refs;validation=$validation;validationIssues=$badRefs;actions=$actions;severity=[string]$r.ReportSeverityLevel;priority=$r.Priority;changed=[string]$r.WhenChangedUTC;predicate=[string](Value-Of $r @('PredicateEvidenceStatus','ConditionEvidenceStatus'))}
    }
)

$expectedWorkloads = @('EXO','SPO','ODB','Teams','Endpoint','Copilot','Fabric and Power BI')
$coverageList = [Collections.Generic.List[object]]::new()
foreach ($w in $expectedWorkloads) {
        $wp = @($policies | Where-Object { $w -in @($_.workloads) })
        $wr = @($rules | Where-Object { $_.effective -and $w -in @($_.workloads) })
        $block = @($wr | Where-Object { $_.blocking -and -not $_.simulation })
        $sim = @($wr | Where-Object simulation)
        $active = @($wr | Where-Object { -not $_.simulation })
        $posture = if ($block.Count) {'Enforced prevention'} elseif ($active.Count) {'Active detection / notification'} elseif ($sim.Count) {'Simulation only'} elseif ($wp.Count) {'Configured but inactive'} else {'Gap / not evidenced'}
        $wideCount = @($wp | Where-Object { $_.scope -eq 'Organization-wide' }).Count
        $scopeText = if ($wideCount) {'Organization-wide evidenced'} elseif ($wp.Count) {'Population scope not exported'} else {'Not evidenced'}
        $coverageList.Add([ordered]@{workload=$w;posture=$posture;policies=$wp.Count;rules=$wr.Count;blocking=$block.Count;simulation=$sim.Count;scope=$scopeText})
}
$coverage = @($coverageList)
if ($coverage.Count -ne $expectedWorkloads.Count) { throw "Coverage model expected $($expectedWorkloads.Count) workloads and produced $($coverage.Count)." }

$sitOccurrences = @{}
foreach ($r in $rules) { foreach ($s in $r.sits) { $key = if ($s.name) {[string]$s.name}else{[string]$s.id}; if (-not $sitOccurrences.ContainsKey($key)) { $sitOccurrences[$key] = [ordered]@{name=$key;occurrences=0;rules=[Collections.Generic.HashSet[string]]::new();workloads=[Collections.Generic.HashSet[string]]::new()} }; $x=$sitOccurrences[$key]; $x.occurrences++; [void]$x.rules.Add($r.name); foreach($w in $r.workloads){[void]$x.workloads.Add($w)} } }
$topSits = @($sitOccurrences.Values | Sort-Object occurrences -Descending | Select-Object -First 15 | ForEach-Object {[ordered]@{name=$_.name;occurrences=$_.occurrences;rules=@($_.rules);workloads=@($_.workloads)}})

$duplicateCandidates = @(
    $rules | Group-Object {
        $ids = @($_.sits | ForEach-Object { $_.id + ':' + $_.minConfidence } | Sort-Object)
        (@($_.workloads | Sort-Object) -join ',') + '|' + $_.scope + '|' + $_.blocking + '|' + ($ids -join ',')
    } | Where-Object Count -gt 1 | ForEach-Object { [ordered]@{count=$_.Count;rules=@($_.Group.name);policies=@($_.Group.policy | Sort-Object -Unique);workloads=@($_.Group.workloads | ForEach-Object { $_ } | Sort-Object -Unique);interpretation='Semantic overlap candidate; validate purpose, direction, exceptions and action before consolidation.'} }
)

$rawLabels = @(As-Array (Value-Of $docs.SensitivityLabels @('data')))
$rawLabelPolicies = @(As-Array (Value-Of $docs.LabelPolicies @('data')))
$labels = @(
    foreach ($l in $rawLabels) {
        $actions = @(Get-LabelActions $l)
        $types = @($actions | ForEach-Object { [string](Value-Of $_ @('type')) } | Where-Object { $_ } | Sort-Object -Unique)
        $enc = @($actions | Where-Object type -eq 'encrypt')
        $activeEnc = @($enc | Where-Object { [string](Value-Of $_.settings @('disabled')) -notmatch '^(?i:true)$' -and [string](Value-Of $_.settings @('templatearchived')) -notmatch '^(?i:true)$' })
        $rights = [Collections.Generic.List[string]]::new(); $principals = [Collections.Generic.List[string]]::new(); $permission='No active encryption action observed'
        foreach($e in $activeEnc){ $defs=[string](Value-Of $e.settings @('rightsdefinitions')); if($defs){ try{ foreach($d in @($defs|ConvertFrom-Json -AsHashtable -Depth 20)){ if($d.Identity){$principals.Add([string]$d.Identity)}; if($d.Rights){$rights.Add([string]$d.Rights)} } }catch{} }; $ptype=[string](Value-Of $e.settings @('protectiontype')); $template=[string](Value-Of $e.settings @('templateid')); if($ptype -eq 'userdefined'){$permission='User-defined recipients; prompt/encrypt-only configuration'}elseif($template){$permission='Template-based rights protection'}else{$permission='Active encryption'} }
        $matches = @($rawLabelPolicies | Where-Object { $refs=@(@(As-Array $_.Labels)+@(As-Array $_.ScopedLabels)); [string]$l.Guid -in $refs -or [string]$l.Name -in $refs -or [string]$l.DisplayName -in $refs })
        [ordered]@{name=[string]$l.DisplayName;guid=[string]$l.Guid;parent=[string]$l.ParentLabelDisplayName;isParent=(As-Bool $l.IsParent);contentTypes=[string]$l.ContentType;workload=[string]$l.Workload;actions=$types;encrypted=($activeEnc.Count -gt 0);marking=(@($types|Where-Object{$_ -match 'marking|watermark'}).Count -gt 0);container=(@($types|Where-Object{$_ -match 'protectgroup|protectsite|protectteams'}).Count -gt 0);permission=$permission;principals=@($principals|Sort-Object -Unique);rights=@($rights|Sort-Object -Unique);publicationPolicies=@($matches | ForEach-Object { [string](Value-Of $_ @('Name')) } | Where-Object { $_ });published=($matches.Count -gt 0);priority=$l.Priority;changed=[string]$l.WhenChangedUTC}
    }
)

$labelPolicies = @(
    foreach($p in $rawLabelPolicies){ $targets=@(@(As-Array $p.ExchangeLocation)+@(As-Array $p.ModernGroupLocation)); $targetText=@($targets|ForEach-Object{if($_-is[Collections.IDictionary]){[string](Value-Of $_ @('Name','DisplayName','Identity'))}else{[string]$_}}); $scope=if('All' -in $targetText){'Organization-wide'}elseif($targetText.Count){'Scoped'}else{'Scope not evidenced'}; [ordered]@{name=[string]$p.Name;enabled=(As-Bool $p.Enabled);mode=[string]$p.Mode;distribution=[string]$p.DistributionStatus;scope=$scope;targets=$targetText;labels=@(@(As-Array $p.Labels)+@(As-Array $p.ScopedLabels)|Sort-Object -Unique);workload=[string]$p.Workload;changed=[string]$p.WhenChangedUTC} }
)

$evidence = @($manifest.evidence | ForEach-Object { [ordered]@{source=[string](Value-Of $_ @('source','name'));service=[string](Value-Of $_ @('service'));status=[string](Value-Of $_ @('status'));records=(Value-Of $_ @('recordCount','records'));seconds=(Value-Of $_ @('durationSeconds'));details=[string](Value-Of $_ @('details','note','message'))} })
$summary = $manifest.summary
$confidence = if([int]$summary.sourceCount){[math]::Round((([int]$summary.observed+[int]$summary.notObserved)/[int]$summary.sourceCount)*100,1)}else{0}
$directoryData = Value-Of $docs.DirectoryCoverage @('data')
$activityData = Value-Of $docs.ActivityExplorerAggregate @('data')
$huntingData = Value-Of $docs.AdvancedHuntingAggregate @('data')
$emailData = Value-Of $docs.EmailActivityCounts @('data')
$oneDriveData = Value-Of $docs.OneDriveFileCounts @('data')
$sharePointData = Value-Of $docs.SharePointFileCounts @('data')
$directory = if ($directoryData) { $directoryData } else { [ordered]@{activeMemberUsers=0;activeGuestUsers=0;disabledUsers=0;activeTargetUsersWithEligibleSkuOrPlan=0;eligibleLicenseCoverageRatio=0} }
$activity = if ($activityData) { $activityData } else { [ordered]@{totalRecords=0;distinctUserCount=0;truncated=$false;effectiveLookbackDays=0;activityCounts=@();workloadCounts=@();labelCounts=@()} }
$hunting = if ($huntingData) { $huntingData } else { [ordered]@{name='Not available';results=@()} }
$content = @(As-Array (Value-Of $docs.ContentExplorerAggregate @('data')))
$email = if ($emailData) { $emailData } else { [ordered]@{totals=[ordered]@{Send=0;Receive=0;Read=0}} }
$onedrive = if ($oneDriveData) { $oneDriveData } else { [ordered]@{totals=[ordered]@{Total=0;Active=0}} }
$sharepoint = if ($sharePointData) { $sharePointData } else { [ordered]@{totals=[ordered]@{Total=0;Active=0}} }
$roleGroups = @(As-Array (Value-Of $docs.PurviewRoleGroups @('data')) | ForEach-Object {[ordered]@{name=[string]$_.Name;type=[string]$_.RoleGroupType;roles=@($_.Roles);roleCount=@($_.Roles).Count;memberCount=$_.MemberCount;managedByCount=$_.ManagedByCount;identitiesPersisted=(As-Bool $_.MemberIdentitiesPersisted)}})

$data = [ordered]@{
    run=[ordered]@{id=$runId;profile=[string]$manifest.profile;lookback=$manifest.lookbackDays;generated=[DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC');collector=[string]$manifest.collectorVersion;confidence=$confidence;summary=$summary}
    evidence=$evidence;expectedWorkloads=$expectedWorkloads;policies=$policies;rules=$rules;coverage=$coverage;topSits=$topSits;duplicateCandidates=$duplicateCandidates
    sitPackages=[ordered]@{count=$rulePackages.Count;tenantPackageFlagged=@($rulePackages|Where-Object IsCustomOrModified).Count;entPrefix=@($rulePackages|Where-Object{$_.SitName -match '^(?i)Ent-'}).Count;missingAnyStandard=@($rulePackages|Where-Object{$_.MissingStandardConfidenceLevels}).Count;items=@($rulePackages|ForEach-Object{[ordered]@{name=$_.SitName;id=$_.SitId;levels=@($_.PatternConfidenceLevels);recommended=$_.RecommendedConfidence;missing=@($_.MissingStandardConfidenceLevels);tenantPackageFlag=(As-Bool $_.IsCustomOrModified)}})}
    labels=$labels;labelPolicies=$labelPolicies
    directory=$directory;skus=@(As-Array (Value-Of $docs.SubscribedSkus @('data')));email=$email;onedrive=$onedrive;sharepoint=$sharepoint;activity=$activity;hunting=$hunting;content=$content
    irm=$(if((Value-Of $docs.IRMConfiguration @('data'))){Value-Of $docs.IRMConfiguration @('data')}else{[ordered]@{AzureRMSLicensingEnabled=$false;InternalLicensingEnabled=$false;ExternalLicensingEnabled=$false;TransportDecryptionSetting='Not available';JournalReportDecryptionEnabled=$false}});rmsTemplates=@(As-Array (Value-Of $docs.RMSTemplates @('data')));irmRules=@(As-Array (Value-Of $docs.IRMTransportRules @('data')));retentionLabels=@(As-Array (Value-Of $docs.RetentionLabels @('data')));retentionPolicies=@(As-Array (Value-Of $docs.RetentionPolicies @('data')));retentionRules=@(As-Array (Value-Of $docs.RetentionRules @('data')));ibSegments=@(As-Array (Value-Of $docs.InformationBarrierSegments @('data')));ibPolicies=@(As-Array (Value-Of $docs.InformationBarrierPolicies @('data')));communication=@(As-Array (Value-Of $docs.CommunicationCompliancePolicies @('data')));ediscovery=@(As-Array (Value-Of $docs.eDiscoveryCases @('data')));insider=@(As-Array (Value-Of $docs.InsiderRiskCases @('data')));roleGroups=$roleGroups;diagnostic=(Value-Of $docs.PurviewDiagnosticExport @('data'))
}
$json = ($data | ConvertTo-Json -Depth 100 -Compress).Replace('</script>','<\/script>')

# Pre-render the complete evidence baseline. Browsers may block or abort inline JavaScript
# for local file:// reports; JavaScript enhances these sections but is no longer required
# to see the collected data.
$generatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')
$staticMeta = '<span>Run: ' + (ConvertTo-HtmlSafe $runId) + '</span><span>Profile: ' + (ConvertTo-HtmlSafe $manifest.profile) + '</span><span>Window: ' + (ConvertTo-HtmlSafe $manifest.lookbackDays) + ' days</span><span>Generated: ' + (ConvertTo-HtmlSafe $generatedUtc) + '</span>'
$effectiveRules = @($rules | Where-Object { $_['effective'] }).Count
$enforcedRules = @($rules | Where-Object { $_['effective'] -and $_['blocking'] -and -not $_['simulation'] }).Count
$simulationRules = @($rules | Where-Object { $_['simulation'] }).Count
$sitReferenceCount = ($rules | ForEach-Object { [int]$_['sitCount'] } | Measure-Object -Sum).Sum
$confidenceIssueCount = ($rules | ForEach-Object { [int]$_['validationIssues'] } | Measure-Object -Sum).Sum
$enforcedWorkloads = @($coverage | Where-Object { $_['posture'] -eq 'Enforced prevention' }).Count

$policyStaticRows = @(
    foreach ($policy in $policies) {
        [ordered]@{
            Policy = $policy['name']; Enabled = $policy['enabled']; Mode = $policy['mode']; Workloads = $policy['workloads']
            Scope = $policy['scope']; ScopeEvidence = $policy['scopeEvidence']; Rules = $policy['rules']
            Distribution = $policy['distribution']; Changed = $policy['changed']
        }
    }
)
$ruleStaticRows = @(
    foreach ($rule in $rules) {
        $sitText = @(
            foreach ($sit in @($rule['sits'])) {
                $confidenceText = if ($null -ne $sit['minConfidence'] -and [string]$sit['minConfidence']) { $sit['minConfidence'] } else { $sit['confidenceLevel'] }
                if ($confidenceText) { "$($sit['name']) [$confidenceText]" } else { [string]$sit['name'] }
            }
        )
        [ordered]@{
            Rule = $rule['name']; Policy = $rule['policy']; State = $rule['state']; Workloads = $rule['workloads']; Scope = $rule['scope']
            SITCount = $rule['sitCount']; SensitiveData = $sitText; Actions = $rule['actions']; ConfidenceIssues = $rule['validationIssues']; Changed = $rule['changed']
        }
    }
)
$labelStaticRows = @(
    foreach ($label in $labels) {
        $protection = @(
            if ($label['encrypted']) { 'Encryption' }
            if ($label['marking']) { 'Marking' }
            if ($label['container']) { 'Container control' }
        )
        if (-not $protection.Count) { $protection = @('No active protection action observed') }
        [ordered]@{
            Label = $label['name']; Parent = $label['parent']; ContentTypes = $label['contentTypes']; Protection = $protection
            Permission = $label['permission']; Principals = $label['principals']; Rights = $label['rights']; Published = $label['published']
            PublicationPolicies = $label['publicationPolicies']; Changed = $label['changed']
        }
    }
)
$labelPolicyStaticRows = @(
    foreach ($policy in $labelPolicies) {
        [ordered]@{ Policy=$policy['name']; Enabled=$policy['enabled']; Mode=$policy['mode']; Scope=$policy['scope']; Targets=$policy['targets']; Labels=$policy['labels']; Distribution=$policy['distribution']; Workload=$policy['workload'] }
    }
)
$duplicateStaticRows = @(
    foreach ($item in $duplicateCandidates) {
        [ordered]@{ Count=$item['count']; Rules=$item['rules']; Policies=$item['policies']; Workloads=$item['workloads']; Interpretation=$item['interpretation'] }
    }
)

$coverageTable = New-StaticTable -Rows $coverage -Columns @(
    [ordered]@{Header='Workload';Key='workload'},[ordered]@{Header='Posture';Key='posture'},[ordered]@{Header='Policies';Key='policies'},[ordered]@{Header='Effective rules';Key='rules'},[ordered]@{Header='Blocking';Key='blocking'},[ordered]@{Header='Simulation';Key='simulation'},[ordered]@{Header='Scope evidence';Key='scope'}
)
$evidenceTable = New-StaticTable -Rows $evidence -Columns @(
    [ordered]@{Header='Source';Key='source'},[ordered]@{Header='Service';Key='service'},[ordered]@{Header='Status';Key='status'},[ordered]@{Header='Records';Key='records'},[ordered]@{Header='Seconds';Key='seconds'},[ordered]@{Header='Details';Key='details'}
)
$policyTable = New-StaticTable -Rows $policyStaticRows -Columns @(
    [ordered]@{Header='Policy';Key='Policy'},[ordered]@{Header='Enabled';Key='Enabled'},[ordered]@{Header='Mode';Key='Mode'},[ordered]@{Header='Workloads';Key='Workloads'},[ordered]@{Header='Scope';Key='Scope'},[ordered]@{Header='Scope evidence';Key='ScopeEvidence'},[ordered]@{Header='Rules';Key='Rules'},[ordered]@{Header='Distribution';Key='Distribution'},[ordered]@{Header='Last changed';Key='Changed'}
)
$ruleTable = New-StaticTable -Rows $ruleStaticRows -Columns @(
    [ordered]@{Header='Rule';Key='Rule'},[ordered]@{Header='Policy';Key='Policy'},[ordered]@{Header='State';Key='State'},[ordered]@{Header='Workloads';Key='Workloads'},[ordered]@{Header='Scope';Key='Scope'},[ordered]@{Header='SITs';Key='SITCount'},[ordered]@{Header='Sensitive data and confidence';Key='SensitiveData'},[ordered]@{Header='Actions';Key='Actions'},[ordered]@{Header='Confidence issues';Key='ConfidenceIssues'},[ordered]@{Header='Last changed';Key='Changed'}
)
$topSitTable = New-StaticTable -Rows $topSits -Columns @(
    [ordered]@{Header='Sensitive information type';Key='name'},[ordered]@{Header='References';Key='occurrences'},[ordered]@{Header='Rules';Key='rules'},[ordered]@{Header='Workloads';Key='workloads'}
)
$duplicateTable = New-StaticTable -Rows $duplicateStaticRows -Columns @(
    [ordered]@{Header='Candidate rules';Key='Count'},[ordered]@{Header='Rules';Key='Rules'},[ordered]@{Header='Policies';Key='Policies'},[ordered]@{Header='Workloads';Key='Workloads'},[ordered]@{Header='Interpretation';Key='Interpretation'}
)
$labelTable = New-StaticTable -Rows $labelStaticRows -Columns @(
    [ordered]@{Header='Label';Key='Label'},[ordered]@{Header='Parent';Key='Parent'},[ordered]@{Header='Content types';Key='ContentTypes'},[ordered]@{Header='Protection';Key='Protection'},[ordered]@{Header='Permission model';Key='Permission'},[ordered]@{Header='Principals';Key='Principals'},[ordered]@{Header='Rights';Key='Rights'},[ordered]@{Header='Published';Key='Published'},[ordered]@{Header='Publication policies';Key='PublicationPolicies'},[ordered]@{Header='Last changed';Key='Changed'}
)
$labelPolicyTable = New-StaticTable -Rows $labelPolicyStaticRows -Columns @(
    [ordered]@{Header='Policy';Key='Policy'},[ordered]@{Header='Enabled';Key='Enabled'},[ordered]@{Header='Mode';Key='Mode'},[ordered]@{Header='Scope';Key='Scope'},[ordered]@{Header='Targets';Key='Targets'},[ordered]@{Header='Labels';Key='Labels'},[ordered]@{Header='Distribution';Key='Distribution'},[ordered]@{Header='Workload';Key='Workload'}
)

$executiveFallback = @"
<section class="section"><div class="callout"><strong>Static evidence view.</strong> This complete baseline remains visible even when a local browser blocks interactive JavaScript.</div></section>
<section class="section"><div class="section-head"><div><h2>CISO decision view</h2><p>Current evidence separates configuration, scope, enforcement and collection quality.</p></div></div><div class="metrics">
$(New-StaticMetric 'Evidence confidence' ($confidence.ToString('0.0') + '%') (([int]$summary.observed + [int]$summary.notObserved).ToString() + ' supported source results'))
$(New-StaticMetric 'Minimum workloads enforced' ($enforcedWorkloads.ToString() + ' / ' + $expectedWorkloads.Count) 'Enforced-prevention evidence')
$(New-StaticMetric 'Effective DLP rules' ($effectiveRules.ToString() + ' / ' + $rules.Count) ($enforcedRules.ToString() + ' enforced blocking; ' + $simulationRules + ' simulation'))
$(New-StaticMetric 'Information Protection' ($labels.Count.ToString() + ' labels') (@($labels | Where-Object { $_['encrypted'] }).Count.ToString() + ' encrypted'))
$(New-StaticMetric 'Licensed population' (([math]::Round(([double]$directory['eligibleLicenseCoverageRatio']) * 100,1)).ToString() + '%') ($directory['activeTargetUsersWithEligibleSkuOrPlan'].ToString() + ' of ' + $directory['activeMemberUsers'] + ' active members'))
</div></section>
<section class="section"><div class="section-head"><div><h2>Minimum workload baseline</h2><p>EXO, SPO, ODB, Teams, Endpoint, Copilot, and Fabric and Power BI.</p></div></div>$coverageTable</section>
<section class="section"><div class="section-head"><div><h2>Evidence matrix</h2><p>Unavailable sources reduce confidence; NotObserved means the supported query succeeded with zero results.</p></div></div>$evidenceTable</section>
<div class="footer">Source run: $(ConvertTo-HtmlSafe $runId).<div class="footnav"><a href="$(ConvertTo-HtmlSafe $script:ProtectionName)">Open the data protection deep dive →</a><a href="$(ConvertTo-HtmlSafe $script:GovernanceName)">Open governance &amp; operations →</a></div></div>
"@

$protectionFallback = @"
<section class="section"><div class="callout"><strong>Static evidence view.</strong> All policy, rule, SIT, label and publication rows are pre-rendered. Interactive filters will replace this view when JavaScript is available.</div></section>
<section class="section"><div class="section-head"><div><h2>Data protection summary</h2><p>Configuration, enforcement, scope and sensitive-data validation are evaluated separately.</p></div></div><div class="metrics">
$(New-StaticMetric 'DLP policies' $policies.Count (@($policies | Where-Object { $_['distribution'] -eq 'Success' }).Count.ToString() + ' distribution Success'))
$(New-StaticMetric 'DLP rules' $rules.Count ($effectiveRules.ToString() + ' effective'))
$(New-StaticMetric 'Blocking rules' $enforcedRules ($simulationRules.ToString() + ' rules in simulation'))
$(New-StaticMetric 'SIT references' $sitReferenceCount ($topSits.Count.ToString() + ' top types summarized below'))
$(New-StaticMetric 'Confidence mismatches' $confidenceIssueCount 'Rule requirements compared with package definitions'))
$(New-StaticMetric 'Sensitivity labels' $labels.Count (@($labels | Where-Object { $_['published'] }).Count.ToString() + ' published'))
</div></section>
<section class="section"><div class="section-head"><div><h2>Policy scope and distribution</h2><p>Copilot tenant-wide evidence is read from the embedded service location. Other workload scope is reported only when evidenced.</p></div></div>$policyTable</section>
<section class="section"><div class="section-head"><div><h2>Rule explorer — complete static inventory</h2><p>Every collected rule is listed with workload, scope, action, sensitive-information types and confidence-validation findings.</p></div></div>$ruleTable</section>
<section class="section"><div class="section-head"><div><h2>Top sensitive data evaluated</h2><p>Frequency is based on rule references, not event volume.</p></div></div>$topSitTable</section>
<section class="section"><div class="section-head"><div><h2>Potential duplicate or overlap candidates</h2><p>Merger duplicates must be reviewed for owner, direction, exceptions and telemetry before consolidation.</p></div></div>$duplicateTable</section>
<section class="section"><div class="section-head"><div><h2>Information Protection labels</h2><p>Protection, permissions, principals, rights and publication coverage.</p></div></div>$labelTable</section>
<section class="section"><div class="section-head"><div><h2>Label publication policies</h2><p>Policy reach and distribution evidence.</p></div></div>$labelPolicyTable</section>
<div class="footer">Sensitive information is derived from nested rule predicates and AdvancedRule. Raw user content is not included.<div class="footnav"><a href="$(ConvertTo-HtmlSafe $script:ExecutiveName)">← Executive overview</a><a href="$(ConvertTo-HtmlSafe $script:GovernanceName)">Governance &amp; operations →</a></div></div>
"@

$activityTable = New-StaticTable -Rows @($activity['activityCounts']) -Columns @(
    [ordered]@{Header='Activity';Key='activity'},[ordered]@{Header='Count';Key='count'}
)
$activityWorkloadTable = New-StaticTable -Rows @($activity['workloadCounts']) -Columns @(
    [ordered]@{Header='Workload';Key='workload'},[ordered]@{Header='Count';Key='count'}
)
$retentionPolicyTable = New-StaticTable -Rows @(As-Array (Value-Of $docs.RetentionPolicies @('data'))) -Columns @(
    [ordered]@{Header='Policy';Key='Name'},[ordered]@{Header='Enabled';Key='Enabled'},[ordered]@{Header='Mode';Key='Mode'},[ordered]@{Header='Workload';Key='Workload'},[ordered]@{Header='Distribution';Key='DistributionStatus'}
)
$roleGroupTable = New-StaticTable -Rows $roleGroups -Columns @(
    [ordered]@{Header='Role group';Key='name'},[ordered]@{Header='Type';Key='type'},[ordered]@{Header='Roles';Key='roles'},[ordered]@{Header='Role count';Key='roleCount'},[ordered]@{Header='Members';Key='memberCount'},[ordered]@{Header='Managed by';Key='managedByCount'},[ordered]@{Header='Identities persisted';Key='identitiesPersisted'}
)
$governanceFallback = @"
<section class="section"><div class="callout"><strong>Static evidence view.</strong> Coverage, activity, lifecycle, investigation and role evidence remains available without JavaScript.</div></section>
<section class="section"><div class="section-head"><div><h2>Coverage and operating evidence</h2><p>Population, usage and governance objects use different denominators and are not combined into a misleading adoption rate.</p></div></div><div class="metrics">
$(New-StaticMetric 'Active members' $directory['activeMemberUsers'] ($directory['activeGuestUsers'].ToString() + ' active guests; ' + $directory['disabledUsers'] + ' disabled users'))
$(New-StaticMetric 'Eligible license coverage' (([math]::Round(([double]$directory['eligibleLicenseCoverageRatio']) * 100,1)).ToString() + '%') ($directory['activeTargetUsersWithEligibleSkuOrPlan'].ToString() + ' users'))
$(New-StaticMetric 'Email activity' (($email['totals']['Send']).ToString() + ' sent') (($email['totals']['Receive']).ToString() + ' received'))
$(New-StaticMetric 'OneDrive files' $onedrive['totals']['Total'] ($onedrive['totals']['Active'].ToString() + ' active'))
$(New-StaticMetric 'SharePoint files' $sharepoint['totals']['Total'] ($sharepoint['totals']['Active'].ToString() + ' active'))
$(New-StaticMetric 'Activity Explorer' $activity['totalRecords'] ($activity['distinctUserCount'].ToString() + ' distinct users'))
</div></section>
<section class="section grid two"><div class="card"><h3>Activity Explorer signals</h3>$activityTable</div><div class="card"><h3>Activity by workload</h3>$activityWorkloadTable</div></section>
<section class="section"><div class="section-head"><div><h2>Retention policies</h2><p>Pending values are reported as collected and are not automatically interpreted as failures.</p></div></div>$retentionPolicyTable</section>
<section class="section"><div class="section-head"><div><h2>Purview role groups</h2><p>Role definitions and aggregate membership counts; identities remain excluded unless explicitly collected.</p></div></div>$roleGroupTable</section>
<section class="section"><div class="section-head"><div><h2>Evidence and collection diagnostics</h2></div></div>$evidenceTable</section>
<div class="footer">This report contains aggregate operational evidence and configuration metadata only.<div class="footnav"><a href="$(ConvertTo-HtmlSafe $script:ProtectionName)">← Data protection deep dive</a><a href="$(ConvertTo-HtmlSafe $script:ExecutiveName)">Executive overview</a></div></div>
"@

$executiveScript = @'
const c=DATA.run.confidence, cov=DATA.coverage, enforced=cov.filter(x=>x.posture==='Enforced prevention').length, active=cov.filter(x=>!/Gap|inactive/.test(x.posture)).length;
const supported=(Number(DATA.run.summary.observed)||0)+(Number(DATA.run.summary.notObserved)||0), sourceCount=Number(DATA.run.summary.sourceCount)||0;
const gapNames=cov.filter(x=>/Gap/.test(x.posture)).map(x=>x.workload), simulationNames=cov.filter(x=>/Simulation/.test(x.posture)).map(x=>x.workload), detectionNames=cov.filter(x=>/Active detection/.test(x.posture)).map(x=>x.workload);
const copilotWide=DATA.policies.some(p=>p.copilotTenantWide), copilotPrevention=DATA.rules.filter(r=>r.workloads.includes('Copilot')&&r.effective&&r.blocking&&!r.simulation).length;
const conclusion=enforced===DATA.expectedWorkloads.length?'All minimum workloads show enforced-prevention evidence.':`${enforced} of ${DATA.expectedWorkloads.length} minimum workloads show enforced-prevention evidence.`;
const detail=[copilotWide?`Copilot tenant-wide scope is evidenced${copilotPrevention?` with ${copilotPrevention} enforced restriction rule(s)`:''}.`:'Copilot tenant-wide scope is not evidenced.',gapNames.length?`Not evidenced: ${gapNames.join(', ')}.`:'No minimum workload is a complete evidence gap.',simulationNames.length?`Simulation only: ${simulationNames.join(', ')}.`:'',detectionNames.length?`Detection without proven prevention: ${detectionNames.join(', ')}.`:''].filter(Boolean).join(' ');
const orgLabelPolicies=DATA.labelPolicies.filter(x=>x.scope==='Organization-wide'&&x.enabled).length;
const blocking=DATA.rules.filter(x=>x.effective&&x.blocking&&!x.simulation).length, sim=DATA.rules.filter(x=>x.simulation).length;
const dlpSignals=(DATA.activity.activityCounts||[]).find(x=>/DLP rule matched/i.test(x.activity))?.count||0, labelApplied=(DATA.activity.activityCounts||[]).find(x=>/Label applied/i.test(x.activity))?.count||0;
const workloadCards=cov.map(x=>`<div class="workload"><strong>${esc(x.workload)}</strong>${badge(x.posture)}<small>${x.policies} policies · ${x.rules} effective rules · ${x.blocking} blocking</small><small>${esc(x.scope)}</small></div>`).join('');
const evidenceRows=DATA.evidence.map(x=>`<tr><td>${esc(x.source)}</td><td>${esc(x.service)}</td><td>${badge(x.status)}</td><td>${esc(x.records)}</td><td>${esc(x.details)}</td></tr>`);
const priorities=[['Approve the target control baseline','Define mandatory workloads, data classes, action modes, exceptions, owners and migration milestones.'],['Validate workload bindings',copilotWide?'Copilot includes explicit tenant-wide scope evidence; validate explicit target populations for other workloads whose bindings were not exported.':'Validate Copilot and non-Copilot target populations because organization-wide scope was not fully evidenced.'],['Move measured controls to prevention',simulationNames.length||detectionNames.length?`Review simulation/detection-only workloads: ${[...simulationNames,...detectionNames].join(', ')}.`:'Maintain prevention with measured false-positive, override and incident outcomes.'],['Review SIT validation evidence',`This suite cross-checks ${DATA.rules.reduce((a,r)=>a+r.sitCount,0)} rule references against ${DATA.sitPackages.count} package definitions.`],['Measure adoption and outcomes','Use DLP matches, label application, overrides, incidents and response SLA—not configuration counts—as the effectiveness layer.']];
$('#app').innerHTML=`
<section class="section"><div class="section-head"><div><h2>CISO decision view</h2><p>Configuration, population, telemetry and governance evidence are kept separate. This is an initial control posture, not certification.</p></div></div><div class="callout warn"><strong>Executive conclusion: ${esc(conclusion)}</strong> ${esc(detail)}</div><div class="metrics" style="margin-top:14px">${metric('Evidence confidence',c+'%',supported+' of '+sourceCount+' sources returned a supported result')}${metric('DLP workload posture',enforced+' / '+DATA.expectedWorkloads.length+' enforced',active+' / '+DATA.expectedWorkloads.length+' active or simulated')}${metric('Effective DLP rules',DATA.rules.filter(x=>x.effective).length+' / '+DATA.rules.length,blocking+' enforced blocking · '+sim+' simulation')}${metric('Information Protection',DATA.labels.length+' labels',DATA.labels.filter(x=>x.encrypted).length+' encrypted · '+orgLabelPolicies+' org-wide publication policies')}${metric('Licensed population',Math.round((DATA.directory.eligibleLicenseCoverageRatio||0)*100)+'%',DATA.directory.activeTargetUsersWithEligibleSkuOrPlan+' of '+DATA.directory.activeMemberUsers+' active members')}${metric(DATA.run.lookback+'-day signals',dlpSignals+' DLP matches',labelApplied+' label applications')}</div></section>
<section class="section"><div class="section-head"><div><h2>Minimum workload baseline</h2><p>Status requires an effective policy/rule relationship; declarations alone do not count as enforced prevention.</p></div></div><div class="workload-grid">${workloadCards}</div></section>
<section class="section grid two"><div class="card"><h3>What changed from the earlier report</h3><ul class="priority"><li>Copilot is now proven <strong>organization-wide</strong> through the embedded location object (<code>Tenant: All</code>).</li><li>Copilot prevention is detected through <code>RestrictAccess</code>; it is no longer misclassified by looking only at <code>BlockAccess</code>.</li><li>Sensitive-data references are recovered from nested predicates and <code>AdvancedRule</code>: ${DATA.rules.reduce((a,r)=>a+r.sitCount,0)} total uses across ${DATA.rules.filter(r=>r.sitCount).length} rules.</li><li>Distribution now uses the detailed policy object; all ${DATA.policies.length} DLP policies report ${DATA.policies.filter(p=>p.distribution==='Success').length} successful distributions.</li></ul></div><div class="card"><h3>Immediate CISO priorities</h3><ol class="priority">${priorities.map(x=>`<li><strong>${esc(x[0])}.</strong> ${esc(x[1])}</li>`).join('')}</ol></div></section>
<section class="section grid two"><div class="card"><h3>Operational indicators</h3>${bars([{name:'DLP rule matches',value:dlpSignals},{name:'Label applied',value:labelApplied},{name:'Copilot interactions',value:(DATA.activity.activityCounts||[]).find(x=>/Copilot Interaction/i.test(x.activity))?.count||0},{name:'Label apply failures',value:(DATA.activity.activityCounts||[]).find(x=>/Label apply failed/i.test(x.activity))?.count||0}])}<p class="muted">Activity Explorer aggregate, ${DATA.activity.effectiveLookbackDays||DATA.run.lookback} days. Counts are signals, not incident outcomes.</p></div><div class="card"><h3>Executive evidence boundary</h3><ul class="priority"><li>The formal Posture Score remains pending whenever required manual governance, exception-quality or SLA evidence is incomplete.</li><li>Content Explorer totals are sampled per configured tag/workload and must not be treated as full estate totals.</li><li>Role-group membership identities are not persisted by default; ${DATA.roleGroups.length} role definitions and ${DATA.roleGroups.reduce((a,x)=>a+(Number(x.memberCount)||0),0)} member record(s) were captured.</li><li>${DATA.insider.length?'Insider Risk case inventory was observed; full policy configuration still requires an authorized export.':'Insider Risk cases were not observed and full policy configuration was not collected.'}</li></ul></div></section>
<section class="section"><div class="section-head"><div><h2>Evidence matrix</h2><p>Unavailable evidence reduces confidence; a successful zero-result query is shown as NotObserved rather than a failure.</p></div></div>${table(['Source','Service','Status','Records','Details'],evidenceRows)}</section>
<div class="footer">Source run: ${esc(DATA.run.id)} · Collector ${esc(DATA.run.collector)}. This report is an architectural assessment, not legal advice or an ISO certification.<div class="footnav"><a href="${esc(document.querySelector('[data-page=protection]').href)}">Open the data protection deep dive →</a><a href="${esc(document.querySelector('[data-page=governance]').href)}">Open governance & operations →</a></div></div>`;
'@

$protectionScript = @'
function ruleRows(items){return items.map(r=>`<tr><td><strong>${esc(r.name)}</strong><br><small>${esc(r.policy)}</small></td><td>${badge(r.state)}</td><td>${chips(r.workloads)}</td><td>${badge(r.scope)}</td><td><strong>${r.sitCount}</strong>${r.sitCount?`<details><summary>View SITs</summary>${chips(r.sits.map(s=>`${s.name} · ${s.confidenceLevel||s.minConfidence}`))}</details>`:''}</td><td>${chips(r.actions)}</td><td>${r.validationIssues?badge(r.validationIssues+' missing confidence checks'):badge(r.sitCount?'Supported / no missing check':'No SIT reference')}</td></tr>`)}
function updateRules(){const q=$('#rq').value.toLowerCase(),w=$('#rw').value,s=$('#rs').value,b=$('#rb').value,v=$('#rv').value;const x=DATA.rules.filter(r=>(!q||JSON.stringify(r).toLowerCase().includes(q))&&(!w||r.workloads.includes(w))&&(!s||r.state===s)&&(!b||String(r.blocking)===b)&&(!v||(v==='issues'?r.validationIssues>0:v==='none'?r.sitCount===0:r.sitCount>0)));$('#rc').textContent=x.length+' rules';$('#rt').innerHTML=table(['Rule / policy','State','Workload','Scope','Sensitive data','Actions','SIT confidence'],ruleRows(x));}
function updateLabels(){const q=$('#lq').value.toLowerCase(),p=$('#lp').value;const x=DATA.labels.filter(l=>(!q||JSON.stringify(l).toLowerCase().includes(q))&&(!p||(p==='encrypted'&&l.encrypted)||(p==='marking'&&l.marking)||(p==='container'&&l.container)||(p==='none'&&!l.encrypted&&!l.marking&&!l.container)));$('#lc').textContent=x.length+' labels';$('#lt').innerHTML=table(['Label','Parent / content','Protection','Permission model','Publication','Last changed'],x.map(l=>`<tr><td><strong>${esc(l.name)}</strong><br><small>${esc(l.guid)}</small></td><td>${esc(l.parent||'—')}<br><small>${esc(l.contentTypes)}</small></td><td>${chips([l.encrypted?'Encryption':null,l.marking?'Marking':null,l.container?'Container control':null].filter(Boolean))||'None'}</td><td>${esc(l.permission)}${l.principals.length?`<details><summary>${l.principals.length} principal(s)</summary>${chips(l.principals)}${chips(l.rights)}</details>`:''}</td><td>${l.published?badge('Published'):badge('Not referenced')}<br><small>${esc(l.publicationPolicies.join('; '))}</small></td><td>${esc(l.changed)}</td></tr>`));}
const top=DATA.topSits.slice(0,10), validationIssues=DATA.rules.reduce((n,r)=>n+r.validationIssues,0), copilot=DATA.rules.filter(r=>r.workloads.includes('Copilot'));
const copilotWide=DATA.policies.some(p=>p.copilotTenantWide), copilotBlocking=copilot.filter(r=>r.blocking&&!r.simulation&&r.effective).length;
$('#app').innerHTML=`
<section class="section"><div class="section-head"><div><h2>DLP architecture at a glance</h2><p>Policy scope, rule enforcement, sensitive-data predicates and confidence compatibility are evaluated independently.</p></div></div><div class="metrics">${metric('DLP policies',DATA.policies.length,DATA.policies.filter(p=>p.distribution==='Success').length+' distribution Success')}${metric('DLP rules',DATA.rules.length,DATA.rules.filter(r=>r.effective).length+' effective')}${metric('Blocking rules',DATA.rules.filter(r=>r.blocking&&!r.simulation&&r.effective).length,DATA.rules.filter(r=>r.blocking&&r.simulation).length+' configured in simulation')}${metric('SIT references',DATA.rules.reduce((a,r)=>a+r.sitCount,0),new Set(DATA.rules.flatMap(r=>r.sits.map(s=>s.id))).size+' unique identifiers')}${metric('Confidence mismatches',validationIssues,'Reconstructed from package XML')}${metric('Overlap candidates',DATA.duplicateCandidates.length,'Review before consolidation')}</div></section>
<section class="section grid two"><div class="card"><h3>Copilot scope and prevention</h3><div class="callout ${copilotWide&&copilotBlocking?'good':'warn'}"><strong>${copilotWide?'Tenant-wide scope is evidenced.':'Tenant-wide scope is not evidenced.'}</strong> ${copilotBlocking} Copilot rule(s) use blocking/restriction actions in enforced policies.${copilotWide?' The detailed policy object exports <code>Tenant: All</code>.':''}</div>${table(['Rule','State','SITs','Action'],copilot.map(r=>`<tr><td>${esc(r.name)}</td><td>${badge(r.state)}</td><td>${r.sitCount}</td><td>${chips(r.actions)}</td></tr>`))}</div><div class="card"><h3>Top sensitive data evaluated</h3>${bars(top,'name','occurrences')}<p class="muted">Rule-reference frequency, not event frequency.</p></div></section>
<section class="section"><div class="section-head"><div><h2>Policy scope and distribution</h2><p>Copilot scope is observed directly. For several non-Copilot workloads the target population is not present in the detailed export; workload intent is derived from the policy family/name and declared workload.</p></div></div>${table(['Policy','Status / mode','Workload interpretation','Scope','Rules','Distribution','Last changed'],DATA.policies.map(p=>`<tr><td><strong>${esc(p.name)}</strong><br><small>${esc(p.comment)}</small></td><td>${badge(p.enabled?'Enabled':'Disabled')} ${badge(p.mode)}</td><td>${chips(p.workloads)}<small class="muted">Declared: ${esc(p.declared)}</small></td><td>${badge(p.scope)}<br><small>${esc(p.scopeEvidence)}</small></td><td>${p.rules}</td><td>${badge(p.distribution)}</td><td>${esc(p.changed)}</td></tr>`))}</section>
<section class="section"><div class="section-head"><div><h2>Rule explorer</h2><p>Filter by effective state, workload, blocking behavior and sensitive-data evidence.</p></div></div><div class="filters"><label>Search<input id="rq" type="search" placeholder="Rule, policy, SIT, action"></label><label>Workload<select id="rw"><option value="">All</option>${DATA.expectedWorkloads.map(x=>`<option>${esc(x)}</option>`).join('')}</select></label><label>State<select id="rs"><option value="">All</option>${[...new Set(DATA.rules.map(r=>r.state))].sort().map(x=>`<option>${esc(x)}</option>`).join('')}</select></label><label>Blocking<select id="rb"><option value="">All</option><option value="true">Blocking/restricting</option><option value="false">Non-blocking</option></select></label><label>SIT evidence<select id="rv"><option value="">All</option><option value="present">Has SITs</option><option value="none">No SIT</option><option value="issues">Confidence issue</option></select></label><span id="rc" class="count"></span></div><div id="rt"></div></section>
<section class="section grid two"><div class="card"><h3>SIT package confidence review</h3><div class="callout warn"><strong>Origin classification is inconclusive.</strong> The collector marked all ${DATA.sitPackages.tenantPackageFlagged} package records as custom/modified because they came from a tenant-published package, but the package also contains standard Microsoft names. Therefore this report validates confidence levels without claiming that every record is tenant-created.</div><div class="metrics" style="margin-top:12px">${metric('Definitions parsed',DATA.sitPackages.count,'Package XML')}${metric('Ent- prefix found',DATA.sitPackages.entPrefix,'No matching prefix in this run')}${metric('Missing one H/M/L level',DATA.sitPackages.missingAnyStandard,'Not necessarily an error unless a rule calls that level')}</div></div><div class="card"><h3>Potential duplicate / overlap families</h3><p class="muted">Candidates share workload, scope, blocking mode and SIT thresholds. Merger duplicates require owner and telemetry review before retirement.</p>${DATA.duplicateCandidates.length?table(['Rules','Policies','Workload','Interpretation'],DATA.duplicateCandidates.slice(0,15).map(x=>`<tr><td>${x.count}<details><summary>View</summary>${x.rules.map(esc).join('<br>')}</details></td><td>${x.policies.map(esc).join('<br>')}</td><td>${chips(x.workloads)}</td><td>${esc(x.interpretation)}</td></tr>`)):'<div class="callout good">No exact semantic overlap candidate was produced by the available fingerprint.</div>'}</div></section>
<section class="section"><div class="section-head"><div><h2>Information Protection</h2><p>Labels are separated by marking, encryption, container controls and publication reach.</p></div></div><div class="metrics">${metric('Labels',DATA.labels.length,DATA.labels.filter(l=>l.isParent).length+' parent/group labels')}${metric('Published labels',DATA.labels.filter(l=>l.published).length,DATA.labelPolicies.length+' publication policies')}${metric('Encrypted labels',DATA.labels.filter(l=>l.encrypted).length,'Active encryption action')}${metric('Marking labels',DATA.labels.filter(l=>l.marking).length,'Header, footer or watermark')}${metric('Container controls',DATA.labels.filter(l=>l.container).length,'Sites, groups or Teams')}</div><div class="filters" style="margin-top:14px"><label>Search<input id="lq" type="search" placeholder="Label, parent, rights, policy"></label><label>Protection<select id="lp"><option value="">All</option><option value="encrypted">Encryption</option><option value="marking">Marking</option><option value="container">Container control</option><option value="none">No active action</option></select></label><span id="lc" class="count"></span></div><div id="lt"></div></section>
<section class="section"><div class="section-head"><div><h2>Publication policy scope</h2></div></div>${table(['Policy','Status','Scope','Targets','Labels','Distribution','Workload'],DATA.labelPolicies.map(p=>`<tr><td><strong>${esc(p.name)}</strong></td><td>${badge(p.enabled?'Enabled':'Disabled')} ${badge(p.mode)}</td><td>${badge(p.scope)}</td><td>${chips(p.targets)}</td><td>${p.labels.length}<details><summary>View</summary>${chips(p.labels)}</details></td><td>${badge(p.distribution)}</td><td>${esc(p.workload)}</td></tr>`))}</section>
<div class="footer">Sensitive information is derived from nested rule predicates and AdvancedRule. Raw user content is not included.<div class="footnav"><a href="${esc(document.querySelector('[data-page=executive]').href)}">← Executive overview</a><a href="${esc(document.querySelector('[data-page=governance]').href)}">Governance & operations →</a></div></div>`;
['rq','rw','rs','rb','rv'].forEach(id=>$('#'+id).addEventListener(id==='rq'?'input':'change',updateRules));['lq','lp'].forEach(id=>$('#'+id).addEventListener(id==='lq'?'input':'change',updateLabels));updateRules();updateLabels();
'@

$governanceScript = @'
const act=DATA.activity.activityCounts||[], workloads=DATA.activity.workloadCounts||[], hunting=DATA.hunting.results||[];
const contentTotals=[...new Map(DATA.content.map(x=>[x.workload,0])).keys()].map(w=>({name:w,value:DATA.content.filter(x=>x.workload===w).reduce((a,x)=>a+(Number(x.totalCount)||0),0)}));
const roleRows=DATA.roleGroups.filter(x=>x.roleCount||x.memberCount).map(x=>`<tr><td><strong>${esc(x.name)}</strong></td><td>${esc(x.type)}</td><td>${x.roleCount}<details><summary>View roles</summary>${chips(x.roles)}</details></td><td>${x.memberCount}</td><td>${x.managedByCount}</td><td>${x.identitiesPersisted?badge('Persisted'):badge('Not persisted')}</td></tr>`);
const evidenceRows=DATA.evidence.map(x=>`<tr><td>${esc(x.source)}</td><td>${badge(x.status)}</td><td>${esc(x.records)}</td><td>${esc(x.seconds)}</td><td>${esc(x.details)}</td></tr>`);
$('#app').innerHTML=`
<section class="section"><div class="section-head"><div><h2>Coverage and operating evidence</h2><p>Population coverage, product usage, protection signals and governance objects are presented without converting incomparable denominators into a single adoption rate.</p></div></div><div class="metrics">${metric('Active members',DATA.directory.activeMemberUsers,DATA.directory.activeGuestUsers+' active guests · '+DATA.directory.disabledUsers+' disabled users')}${metric('Eligible license coverage',Math.round((DATA.directory.eligibleLicenseCoverageRatio||0)*100)+'%',DATA.directory.activeTargetUsersWithEligibleSkuOrPlan+' users')}${metric('Email activity (30d)',(DATA.email.totals?.Send||0)+' sent', (DATA.email.totals?.Receive||0)+' received · '+(DATA.email.totals?.Read||0)+' read events')}${metric('OneDrive files',DATA.onedrive.totals?.Total||0,(DATA.onedrive.totals?.Active||0)+' active')}${metric('SharePoint files',DATA.sharepoint.totals?.Total||0,(DATA.sharepoint.totals?.Active||0)+' active')}${metric('Activity Explorer',DATA.activity.totalRecords||0,(DATA.activity.distinctUserCount||0)+' distinct users · truncated: '+DATA.activity.truncated)}</div></section>
<section class="section grid two"><div class="card"><h3>Activity Explorer — top signals</h3>${bars(act.slice(0,12),'activity','count')}<p class="muted">${DATA.activity.effectiveLookbackDays||DATA.run.lookback}-day aggregate; detailed records were not persisted.</p></div><div class="card"><h3>Activity by workload</h3>${bars(workloads,'workload','count')}<p class="muted">Endpoint dominates the event volume. This is not equivalent to coverage or prevention effectiveness.</p></div></section>
<section class="section grid two"><div class="card"><h3>Advanced Hunting — top actions</h3>${bars(hunting.slice(0,12).map(x=>({name:x.ActionType,value:x.EventCount})))}<p class="muted">Aggregate CloudAppEvents query; no event-level content is retained.</p></div><div class="card"><h3>Content Explorer sampling</h3>${bars(contentTotals)}<div class="callout warn">Content Explorer used a page size of one for each configured tag/workload query. These counts are sampling/cross-validation evidence, not a complete inventory.</div></div></section>
<section class="section"><div class="section-head"><div><h2>Retention and rights management</h2></div></div><div class="grid two"><div class="card"><h3>IRM / RMS posture</h3><div class="metrics">${metric('Azure RMS licensing',DATA.irm.AzureRMSLicensingEnabled?'Enabled':'Disabled','Internal: '+DATA.irm.InternalLicensingEnabled+' · External: '+DATA.irm.ExternalLicensingEnabled)}${metric('RMS templates',DATA.rmsTemplates.length,'Distributed templates observed')}${metric('IRM transport rules',DATA.irmRules.length,'Zero is a successful NotObserved result')}${metric('Transport decryption',DATA.irm.TransportDecryptionSetting||'Unknown','Journal report decryption: '+DATA.irm.JournalReportDecryptionEnabled)}</div>${table(['Template','Type','Description'],DATA.rmsTemplates.map(x=>`<tr><td>${esc(x.Name)}</td><td>${esc(x.Type)}</td><td>${esc(x.Description)}</td></tr>`))}</div><div class="card"><h3>Retention inventory</h3><div class="metrics">${metric('Retention labels',DATA.retentionLabels.length,'Lifecycle tags')}${metric('Retention policies',DATA.retentionPolicies.length,DATA.retentionPolicies.filter(x=>x.Enabled).length+' enabled')}${metric('Retention rules',DATA.retentionRules.length,DATA.retentionRules.filter(x=>!x.Disabled).length+' enabled')}</div>${table(['Policy','Mode','Workload','Distribution'],DATA.retentionPolicies.map(x=>`<tr><td>${esc(x.Name)}</td><td>${badge(x.Mode)}</td><td>${esc(x.Workload)}</td><td>${badge(x.DistributionStatus||'Unknown')}</td></tr>`))}<div class="callout warn" style="margin-top:12px">Retention policies report Pending through the standard property. No embedded corrected distribution detail was collected for retention, so this suite does not infer failure.</div></div></div></section>
<section class="section"><div class="section-head"><div><h2>Investigations, segregation and conduct</h2></div></div><div class="metrics">${metric('eDiscovery cases',DATA.ediscovery.length,DATA.ediscovery.filter(x=>x.Status==='Active').length+' active · names not persisted')}${metric('Insider Risk cases',DATA.insider.length,'NotObserved in this run')}${metric('Communication Compliance',DATA.communication.length,DATA.communication.filter(x=>x.Enabled).length+' enabled policies')}${metric('Information Barriers',DATA.ibPolicies.length+' policies',DATA.ibSegments.length+' segments')}${metric('Purview role groups',DATA.roleGroups.length,DATA.roleGroups.reduce((a,x)=>a+(Number(x.memberCount)||0),0)+' members persisted')}</div><div class="grid two" style="margin-top:14px"><div class="card"><h3>eDiscovery cases</h3>${table(['Type','Case key','Status','Name persistence'],DATA.ediscovery.map(x=>`<tr><td>${esc(x.CaseType)}</td><td>${esc(x.CaseKey)}</td><td>${badge(x.Status)}</td><td>${badge(x.CaseNamesPersisted?'Persisted':'Not persisted')}</td></tr>`))}</div><div class="card"><h3>Communication Compliance</h3>${DATA.communication.length?table(['Policy','Enabled','Workload','Changed'],DATA.communication.map(x=>`<tr><td>${esc(x.Name)}</td><td>${badge(x.Enabled?'Enabled':'Disabled')}</td><td>${esc(x.Workload)}</td><td>${esc(x.WhenChangedUTC)}</td></tr>`)):'<div class="callout">No policies observed.</div>'}</div></div></section>
<section class="section"><div class="section-head"><div><h2>Purview role groups</h2><p>Role definitions were collected. Member and manager identities were not requested/persisted, so least-privilege membership cannot be assessed from this run.</p></div></div>${table(['Role group','Type','Roles','Members','Managed by','Identity detail'],roleRows)}</section>
<section class="section"><div class="section-head"><div><h2>Evidence and collection diagnostics</h2><p>Use this section to decide which source needs recollection or a manual evidence supplement.</p></div></div>${table(['Source','Status','Records','Seconds','Details'],evidenceRows)}</section>
<section class="section"><div class="card"><h3>Architectural next actions</h3><ol class="priority"><li>Re-run SIT inventory after correcting hashtable serialization and confidence-level conversion; compare the reconstructed findings in the deep dive.</li><li>Enable role-group member collection only in a controlled run with explicit approval, then assess privileged membership, empty administrative groups and separation of duties.</li><li>Import the Insider Risk policy export if governance review is in scope; current evidence covers no policy detail.</li><li>Define comparable denominators before publishing labeling rates: Activity Explorer label events, Graph file totals and Content Explorer sampled counts are not directly interchangeable.</li><li>Attach case SLA and incident disposition evidence before computing monitoring and response scores.</li></ol></div></section>
<div class="footer">This report contains aggregate operational evidence and configuration metadata only.<div class="footnav"><a href="${esc(document.querySelector('[data-page=protection]').href)}">← Data protection deep dive</a><a href="${esc(document.querySelector('[data-page=executive]').href)}">Executive overview</a></div></div>`;
'@

Write-Report -Path (Join-Path $OutputPath $script:ExecutiveName) -Title 'Microsoft Purview Executive Overview' -Kicker 'CISO decision view · merger control baseline' -Subtitle 'Current-state assessment across DLP, Information Protection, coverage, telemetry, governance and evidence quality.' -ActivePage 'executive' -PageScript $executiveScript -DataJson $json -FallbackHtml $executiveFallback -MetaHtml $staticMeta
Write-Report -Path (Join-Path $OutputPath $script:ProtectionName) -Title 'Microsoft Purview Data Protection Deep Dive' -Kicker 'DLP & Information Protection architecture' -Subtitle 'Detailed policy, rule, workload, sensitive-data, confidence, protection-rights and overlap analysis.' -ActivePage 'protection' -PageScript $protectionScript -DataJson $json -FallbackHtml $protectionFallback -MetaHtml $staticMeta
Write-Report -Path (Join-Path $OutputPath $script:GovernanceName) -Title 'Microsoft Purview Governance & Operations' -Kicker 'Coverage, adoption, lifecycle and investigation evidence' -Subtitle 'Licensing, activity, retention, IRM, investigations, role groups and collection diagnostics.' -ActivePage 'governance' -PageScript $governanceScript -DataJson $json -FallbackHtml $governanceFallback -MetaHtml $staticMeta

Copy-Item -LiteralPath (Join-Path $OutputPath $script:ExecutiveName) -Destination (Join-Path $OutputPath 'Purview-Executive-Overview-Latest.html') -Force
Copy-Item -LiteralPath (Join-Path $OutputPath $script:ProtectionName) -Destination (Join-Path $OutputPath 'Purview-Data-Protection-Deep-Dive-Latest.html') -Force
Copy-Item -LiteralPath (Join-Path $OutputPath $script:GovernanceName) -Destination (Join-Path $OutputPath 'Purview-Governance-Operations-Latest.html') -Force

[pscustomobject]@{
    RunId = $runId
    Executive = (Join-Path $OutputPath $script:ExecutiveName)
    DataProtection = (Join-Path $OutputPath $script:ProtectionName)
    GovernanceOperations = (Join-Path $OutputPath $script:GovernanceName)
}

