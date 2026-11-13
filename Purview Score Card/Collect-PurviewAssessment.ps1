#requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('Basic', 'Intermediate', 'Full')]
    [string]$Profile,

    [ValidateSet(30, 60, 90)]
    [int]$LookbackDays = 30,

    [string]$ScoreConfigPath,

    [string]$CollectedDataPath,

    [string]$ExportedDataPath,

    [switch]$InstallMissingModules,

    [switch]$SkipGraph,

    [switch]$SkipCompliance,

    [string[]]$OnlySources,

    [switch]$SkipExchangeOnlineConnection,

    [switch]$DeviceAuthentication,

    [switch]$IncludeRoleGroupMembers,

    [switch]$IncludeCaseNames,

    [string]$InsiderRiskExportPath,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CollectorVersion = '1.2.0'
$script:RunItems = [System.Collections.Generic.List[object]]::new()
$script:RunMessages = [System.Collections.Generic.List[object]]::new()
$script:RunStartedUtc = [DateTime]::UtcNow
$script:ReportPath = $null
$script:OnlySources = @($OnlySources | ForEach-Object { $_ -split ',' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$script:InteractiveOnlySources = @()
$script:DlpDetailedRules = @()
$script:SensitiveInformationTypes = @()
$script:SensitiveInformationTypeDefinitions = @()

function Select-CollectionProfile {
    Write-Host ''
    Write-Host 'Microsoft Purview Score Card'
    Write-Host '1. Basic        - DLP, labels, licensing, and aggregated usage'
    Write-Host '2. Intermediate - Basic + IRM, retention, and Activity Explorer'
    Write-Host '3. Full         - Intermediate + Information Barriers, Communication Compliance, eDiscovery, role groups, and cross-validation'
    Write-Host '4. Custom       - Select one or more collection groups'
    Write-Host ''

    do {
        $selection = Read-Host 'Select 1, 2, 3, or 4'
    } until ($selection -in @('1', '2', '3', '4'))

    switch ($selection) {
        '1' { return 'Basic' }
        '2' { return 'Intermediate' }
        '3' { return 'Full' }
        '4' {
            Write-Host ''
            Write-Host 'Collection groups (comma-separated):'
            Write-Host '1. DLP and sensitive information types'
            Write-Host '2. Information Protection labels and publishing policies'
            Write-Host '3. Licensing, directory coverage, and Microsoft 365 usage'
            Write-Host '4. IRM, retention, and Activity Explorer'
            Write-Host '5. Information Barriers and Communication Compliance'
            Write-Host '6. Insider Risk and eDiscovery case inventory'
            Write-Host '7. Microsoft Purview role groups'
            Write-Host '8. Purview diagnostic configuration export'
            do {
                $customSelection = Read-Host 'Select one or more groups, for example 1,2,6,7'
                $numbers = @($customSelection -split '[,; ]+' | Where-Object { $_ -in @('1','2','3','4','5','6','7','8') } | Sort-Object -Unique)
            } until ($numbers.Count -gt 0)
            $sourceGroups = @{
                '1' = @('SensitiveInformationTypes','SensitiveInformationTypeRulePackages','DLPPolicies','DLPRules','DlpRuleSitValidation')
                '2' = @('SensitivityLabels','LabelPolicies')
                '3' = @('Organization','SubscribedSkus','DirectoryCoverage','EmailActivityCounts','OneDriveFileCounts','SharePointFileCounts')
                '4' = @('IRMConfiguration','RMSTrustedPublishingDomains','RMSTemplates','IRMTransportRules','RetentionLabels','RetentionPolicies','RetentionRules','ActivityExplorerAggregate')
                '5' = @('InformationBarrierSegments','InformationBarrierPolicies','CommunicationCompliancePolicies')
                '6' = @('eDiscoveryCases','InsiderRiskCases','ImportedInsiderRiskPolicyExport')
                '7' = @('PurviewRoleGroups')
                '8' = @('PurviewDiagnosticExport')
            }
            $script:InteractiveOnlySources = @($numbers | ForEach-Object { $sourceGroups[$_] } | Sort-Object -Unique)
            return 'Full'
        }
    }
}

function Get-ProfileRank {
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name) {
        'Basic' { return 1 }
        'Intermediate' { return 2 }
        'Full' { return 3 }
        default { throw "Unknown profile: $Name" }
    }
}

function Assert-ScoreConfiguration {
    param([Parameter(Mandatory)]$Configuration)

    $dimensionWeight = [double](($Configuration.dimensions | Measure-Object -Property weight -Sum).Sum)
    $allMetrics = @($Configuration.dimensions | ForEach-Object { @($_.metrics) })
    $metricWeight = [double](($allMetrics | Measure-Object -Property weight -Sum).Sum)

    if ([Math]::Abs($dimensionWeight - 100) -gt 0.001) {
        throw "Dimension weights must total 100; current total is $dimensionWeight."
    }
    if ([Math]::Abs($metricWeight - 100) -gt 0.001) {
        throw "Metric weights must total 100; current total is $metricWeight."
    }

    $metricIds = @($allMetrics | ForEach-Object { [string]$_.id })
    $duplicateIds = @($metricIds | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    if ($duplicateIds.Count -gt 0) {
        throw ('Duplicate metric IDs: ' + ($duplicateIds -join ', '))
    }

    foreach ($dimension in $Configuration.dimensions) {
        $childWeight = [double](($dimension.metrics | Measure-Object -Property weight -Sum).Sum)
        if ([Math]::Abs($childWeight - [double]$dimension.weight) -gt 0.001) {
            throw "Metrics in dimension '$($dimension.id)' total $childWeight but dimension weight is $($dimension.weight)."
        }
    }

    $requiredOverrideFields = @($Configuration.manualOverrideRequirements.requiredFields)
    foreach ($property in $Configuration.manualOverrides.PSObject.Properties) {
        if ($null -eq $property.Value) { continue }
        $missingFields = @($requiredOverrideFields | Where-Object { -not $property.Value.PSObject.Properties[$_] })
        if ($missingFields.Count -gt 0) {
            throw "Manual override '$($property.Name)' is missing: $($missingFields -join ', ')."
        }
        $score = [double]$property.Value.score
        if ($score -lt [double]$Configuration.manualOverrideRequirements.scoreMinimum -or $score -gt [double]$Configuration.manualOverrideRequirements.scoreMaximum) {
            throw "Manual override '$($property.Name)' has an out-of-range score."
        }
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$InputObject
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString('N')))
    try {
        $json = $InputObject | ConvertTo-Json -Depth 100
        Set-Content -LiteralPath $temporaryPath -Value $json -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Add-RunMessage {
    param(
        [Parameter(Mandatory)][ValidateSet('Information', 'Warning', 'Error')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    $script:RunMessages.Add([pscustomobject]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level = $Level
        message = $Message
    })
}

function Save-Evidence {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Status,
        [AllowNull()]$Data,
        [string]$Message,
        [double]$DurationSeconds = 0
    )

    $recordCount = 0
    if ($null -ne $Data) { $recordCount = @($Data).Count }
    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $fileName = "$safeName.json"
    $path = Join-Path $script:RunPath $fileName

    $envelope = [ordered]@{
        schemaVersion = '1.0.0'
        collectorVersion = $script:CollectorVersion
        collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        profile = $script:SelectedProfile
        lookbackDays = $LookbackDays
        source = $Source
        command = $Command
        evidenceStatus = $Status
        message = $Message
        recordCount = $recordCount
        data = $Data
    }

    Write-AtomicJson -Path $path -InputObject $envelope

    $script:RunItems.Add([pscustomobject]@{
        name = $Name
        source = $Source
        status = $Status
        recordCount = $recordCount
        durationSeconds = [Math]::Round($DurationSeconds, 3)
        file = $fileName
        message = $Message
    })
}

function Invoke-CollectionStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][scriptblock]$Action,
        [string[]]$RequiredCommands = @(),
        [bool]$Enabled = $true,
        [string]$DisabledStatus = 'Unavailable',
        [string]$DisabledReason = 'Source is unavailable.'
    )

    if ($script:OnlySources.Count -gt 0 -and $Name -notin $script:OnlySources) {
        return
    }

    if ($DryRun) {
        Save-Evidence -Name $Name -Source $Source -Command $Command -Status 'NotCollected' -Data $null -Message 'Planned by dry run; no remote connection was made.'
        return
    }

    if (-not $Enabled) {
        Save-Evidence -Name $Name -Source $Source -Command $Command -Status $DisabledStatus -Data $null -Message $DisabledReason
        return
    }

    $missingCommands = @($RequiredCommands | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })
    if ($missingCommands.Count -gt 0) {
        Save-Evidence -Name $Name -Source $Source -Command $Command -Status 'Unavailable' -Data $null -Message ('Missing command(s): ' + ($missingCommands -join ', '))
        return
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $result = @(& $Action)
        $stopwatch.Stop()
        $status = if ($result.Count -eq 0) { 'NotObserved' } else { 'Observed' }
        $message = if ($result.Count -eq 0) { 'The query completed successfully and returned no records.' } else { $null }
        Save-Evidence -Name $Name -Source $Source -Command $Command -Status $status -Data $result -Message $message -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    }
    catch {
        $stopwatch.Stop()
        $detail = '{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message
        Save-Evidence -Name $Name -Source $Source -Command $Command -Status 'Unavailable' -Data $null -Message $detail -DurationSeconds $stopwatch.Elapsed.TotalSeconds
        Add-RunMessage -Level Warning -Message "$Name could not be collected. $detail"
    }
}

function Import-CollectorModule {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        if (-not $InstallMissingModules) {
            throw "Module '$Name' is not installed. Re-run with -InstallMissingModules or install it for CurrentUser."
        }

        Install-Module -Name $Name -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }

    Import-Module -Name $Name -ErrorAction Stop
}

function ConvertTo-PropertyBag {
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return $null }
    $excluded = @('RunspaceId','PSComputerName','PSShowComputerName')
    $bag = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.Name -notin $excluded) { $bag[$property.Name] = $property.Value }
    }
    return $bag
}

function Get-ObjectPropertyValue {
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string[]]$Names)
    if ($null -eq $InputObject) { return $null }
    foreach ($name in $Names) {
        if ($InputObject -is [Collections.IDictionary]) {
            if ($InputObject.Contains($name)) { return $InputObject[$name] }
        }
        elseif ($InputObject.PSObject.Properties[$name]) { return $InputObject.$name }
    }
    return $null
}

function Test-MeaningfulValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -notin @('False','None','0') }
    if ($Value -is [Collections.IEnumerable]) { return @($Value).Count -gt 0 }
    return $true
}

function Get-StringHash {
    param([Parameter(Mandatory)][string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))) }
    finally { $sha.Dispose() }
}

function Add-SitReferencesRecursive {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Results,
        [int]$Depth = 0,
        [string]$Path = '$'
    )
    if ($null -eq $InputObject -or $Depth -gt 30) { return }
    if ($InputObject -is [string]) {
        $trimmed = $InputObject.Trim()
        if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
            try { Add-SitReferencesRecursive -InputObject ($trimmed | ConvertFrom-Json -AsHashtable -Depth 100) -Results $Results -Depth ($Depth + 1) -Path $Path } catch {}
        }
        return
    }
    if ($InputObject -is [Collections.IDictionary]) {
        $lower = @{}
        foreach ($key in $InputObject.Keys) { $lower[[string]$key.ToLowerInvariant()] = $InputObject[$key] }
        $identifier = if ($lower.ContainsKey('id')) { [string]$lower['id'] } elseif ($lower.ContainsKey('name')) { [string]$lower['name'] } else { '' }
        $hasSitShape = $false
        if ($identifier) {
            foreach ($shapeKey in @('mincount','maxcount','confidencelevel','minconfidence','maxconfidence','recommendedconfidence')) {
                if ($lower.ContainsKey($shapeKey)) { $hasSitShape = $true; break }
            }
            if ($Path -match '(?i)ContentContainsSensitiveInformation|SensitiveInformationReferences|SensitiveTypes') { $hasSitShape = $true }
        }
        if ($hasSitShape) {
            $Results.Add([pscustomobject]@{
                id = if ($lower.ContainsKey('id')) { [string]$lower['id'] } else { '' }
                name = if ($lower.ContainsKey('name')) { [string]$lower['name'] } else { '' }
                minCount = if ($lower.ContainsKey('mincount')) { $lower['mincount'] } else { $null }
                maxCount = if ($lower.ContainsKey('maxcount')) { $lower['maxcount'] } else { $null }
                confidenceLevel = if ($lower.ContainsKey('confidencelevel')) { $lower['confidencelevel'] } elseif ($lower.ContainsKey('minconfidence')) { $lower['minconfidence'] } else { $null }
                minConfidence = if ($lower.ContainsKey('minconfidence')) { $lower['minconfidence'] } else { $null }
                maxConfidence = if ($lower.ContainsKey('maxconfidence')) { $lower['maxconfidence'] } else { $null }
                sourcePath = $Path
            })
        }
        foreach ($key in $InputObject.Keys) { Add-SitReferencesRecursive -InputObject $InputObject[$key] -Results $Results -Depth ($Depth + 1) -Path "$Path.$key" }
        return
    }
    if ($InputObject -is [Collections.IEnumerable]) {
        $index = 0
        foreach ($item in $InputObject) {
            Add-SitReferencesRecursive -InputObject $item -Results $Results -Depth ($Depth + 1) -Path "$Path[$index]"
            $index++
        }
        return
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        Add-SitReferencesRecursive -InputObject $property.Value -Results $Results -Depth ($Depth + 1) -Path "$Path.$($property.Name)"
    }
}

function Get-SitReferencesFromRule {
    param([Parameter(Mandatory)]$Rule)
    $results = [Collections.Generic.List[object]]::new()
    foreach ($propertyName in @('ContentContainsSensitiveInformation','AdvancedRule','Conditions','RuleBlob','PolicyRuleBlob')) {
        $value = Get-ObjectPropertyValue -InputObject $Rule -Names $propertyName
        Add-SitReferencesRecursive -InputObject $value -Results $results -Path "`$.$propertyName"
    }
    @($results | Group-Object { '{0}|{1}|{2}|{3}|{4}|{5}' -f $_.id,$_.name,$_.minCount,$_.maxCount,$_.minConfidence,$_.maxConfidence } | ForEach-Object { $_.Group[0] })
}

function Get-DlpPolicyDetails {
    $summaries = @(Get-DlpCompliancePolicy)
    foreach ($summary in $summaries) {
        $identity = [string](Get-ObjectPropertyValue $summary @('Guid','Identity','Id','Name'))
        $detail = $null
        $attempts = @(
            @{ Identity=$identity; DistributionDetail=$true; IncludeExtendedProperties=$true; IncludeRulesMetadata=$true },
            @{ Identity=$identity; DistributionDetail=$true },
            @{ Identity=$identity }
        )
        foreach ($parameters in $attempts) {
            try { $detail = Get-DlpCompliancePolicy @parameters -ErrorAction Stop | Select-Object -First 1; if ($detail) { break } } catch {}
        }
        if (-not $detail) { $detail = $summary }
        $bag = ConvertTo-PropertyBag $detail
        $rawJson = $bag | ConvertTo-Json -Compress -Depth 100
        $copilotId = '470f2276-e011-4e9d-a6ec-20768be3a4b0'
        $copilotObserved = $rawJson -match [regex]::Escape($copilotId) -or $rawJson -match '(?i)Copilot'
        $copilotTenantWide = $copilotObserved -and ($rawJson -match '(?i)"(?:Identity|ImmutableIdentity|Type)"\s*:\s*"(?:All|Tenant)"' -or $rawJson -match '(?i)"Inclusions"\s*:\s*\[\s*\{[^}]*"Type"\s*:\s*"Tenant"')
        [pscustomobject]@{
            Name = [string](Get-ObjectPropertyValue $detail @('Name','DisplayName'))
            Guid = [string](Get-ObjectPropertyValue $detail @('Guid','Identity','Id'))
            Enabled = Get-ObjectPropertyValue $detail @('Enabled')
            Mode = [string](Get-ObjectPropertyValue $detail @('Mode'))
            Workload = [string](Get-ObjectPropertyValue $detail @('Workload'))
            ExchangeLocation = Get-ObjectPropertyValue $detail @('ExchangeLocation')
            SharePointLocation = Get-ObjectPropertyValue $detail @('SharePointLocation')
            OneDriveLocation = Get-ObjectPropertyValue $detail @('OneDriveLocation')
            TeamsLocation = Get-ObjectPropertyValue $detail @('TeamsLocation')
            EndpointDlpLocation = Get-ObjectPropertyValue $detail @('EndpointDlpLocation')
            PowerBIDlpLocation = Get-ObjectPropertyValue $detail @('PowerBIDlpLocation','PowerBILocation')
            Applications = Get-ObjectPropertyValue $detail @('Applications','ApplicationLocation','ThirdPartyAppDlpLocation','Locations')
            Priority = Get-ObjectPropertyValue $detail @('Priority')
            DistributionStatus = [string](Get-ObjectPropertyValue $detail @('DistributionStatus'))
            DistributionResults = Get-ObjectPropertyValue $detail @('DistributionResults')
            DistributionDetailRequested = $true
            CopilotLocationObserved = $copilotObserved
            CopilotTenantWide = $copilotTenantWide
            ScopeClassification = if ($copilotTenantWide) { 'Organization-wide Copilot application scope' } elseif ($copilotObserved) { 'Copilot application scope requires target review' } else { 'No Copilot location detected in detailed policy object' }
            WhenCreatedUTC = Get-ObjectPropertyValue $detail @('WhenCreatedUTC')
            WhenChangedUTC = Get-ObjectPropertyValue $detail @('WhenChangedUTC')
            CreatedBy = [string](Get-ObjectPropertyValue $detail @('CreatedBy'))
            LastModifiedBy = [string](Get-ObjectPropertyValue $detail @('LastModifiedBy'))
            Comment = [string](Get-ObjectPropertyValue $detail @('Comment'))
            AllProperties = $bag
        }
    }
}

function Get-DlpRuleDetails {
    $summaries = @(Get-DlpComplianceRule)
    foreach ($summary in $summaries) {
        $identity = [string](Get-ObjectPropertyValue $summary @('Guid','Identity','Id','Name'))
        try { $detail = Get-DlpComplianceRule -Identity $identity -ErrorAction Stop | Select-Object -First 1 } catch { $detail = $summary }
        if (-not $detail) { $detail = $summary }
        $bag = ConvertTo-PropertyBag $detail
        $sitReferences = @(Get-SitReferencesFromRule -Rule $detail)
        $actionSignals = @(
            foreach ($property in $detail.PSObject.Properties) {
                if ($property.Name -match '(?i)Block|RestrictAccess|Notify|Alert|Incident' -and (Test-MeaningfulValue $property.Value)) {
                    [pscustomobject]@{ property=$property.Name; value=$property.Value }
                }
            }
        )
        $rawJson = $bag | ConvertTo-Json -Compress -Depth 100
        $advancedRuleText = [string](Get-ObjectPropertyValue $detail @('AdvancedRule','RuleBlob','PolicyRuleBlob'))
        $advancedBlocking = ($rawJson -match '(?i)"BlockAccess"\s*:\s*true') -or ($advancedRuleText -match '(?i)"BlockAccess"\s*:\s*true|"(?:setting|action|value)"\s*:\s*"(?:Block|BlockAccess|RestrictAccess)"')
        [pscustomobject]@{
            Name = [string](Get-ObjectPropertyValue $detail @('Name','DisplayName'))
            Guid = [string](Get-ObjectPropertyValue $detail @('Guid','Identity','Id'))
            Policy = Get-ObjectPropertyValue $detail @('Policy')
            Disabled = Get-ObjectPropertyValue $detail @('Disabled')
            Mode = [string](Get-ObjectPropertyValue $detail @('Mode'))
            Priority = Get-ObjectPropertyValue $detail @('Priority')
            Workload = [string](Get-ObjectPropertyValue $detail @('Workload'))
            ContentContainsSensitiveInformation = Get-ObjectPropertyValue $detail @('ContentContainsSensitiveInformation')
            ContentContainsLabel = Get-ObjectPropertyValue $detail @('ContentContainsLabel')
            AdvancedRule = Get-ObjectPropertyValue $detail @('AdvancedRule')
            SensitiveInformationReferences = @($sitReferences)
            SensitiveInformationReferenceCount = $sitReferences.Count
            BlockAccess = Get-ObjectPropertyValue $detail @('BlockAccess')
            BlockAccessScope = Get-ObjectPropertyValue $detail @('BlockAccessScope')
            RestrictAccess = Get-ObjectPropertyValue $detail @('RestrictAccess','RestrictAccessSettings')
            HasBlockingOrRestrictionAction = (([bool](Get-ObjectPropertyValue $detail @('BlockAccess'))) -or $advancedBlocking -or @($actionSignals | Where-Object property -match '(?i)Block|RestrictAccess').Count -gt 0)
            ActionSignals = @($actionSignals)
            NotifyUser = Get-ObjectPropertyValue $detail @('NotifyUser')
            NotifyPolicyTipCustomText = Get-ObjectPropertyValue $detail @('NotifyPolicyTipCustomText')
            GenerateAlert = Get-ObjectPropertyValue $detail @('GenerateAlert')
            GenerateIncidentReport = Get-ObjectPropertyValue $detail @('GenerateIncidentReport')
            IncidentReportContent = Get-ObjectPropertyValue $detail @('IncidentReportContent')
            ReportSeverityLevel = [string](Get-ObjectPropertyValue $detail @('ReportSeverityLevel'))
            AccessScope = [string](Get-ObjectPropertyValue $detail @('AccessScope'))
            WhenCreatedUTC = Get-ObjectPropertyValue $detail @('WhenCreatedUTC')
            WhenChangedUTC = Get-ObjectPropertyValue $detail @('WhenChangedUTC')
            AllProperties = $bag
        }
    }
}

function Get-SensitiveInformationTypeDetails {
    $summaries = @(Get-DlpSensitiveInformationType)
    foreach ($summary in $summaries) {
        $identity = [string](Get-ObjectPropertyValue $summary @('Id','Guid','Identity','Name'))
        try { $detail = Get-DlpSensitiveInformationType -Identity $identity -ErrorAction Stop | Select-Object -First 1 } catch { $detail = $summary }
        if (-not $detail) { $detail = $summary }
        $publisher = [string](Get-ObjectPropertyValue $detail @('Publisher'))
        $package = [string](Get-ObjectPropertyValue $detail @('ClassificationRuleCollectionId','RulePackage'))
        [pscustomobject]@{
            Name = [string](Get-ObjectPropertyValue $detail @('Name','DisplayName'))
            Id = [string](Get-ObjectPropertyValue $detail @('Id','Guid','Identity'))
            Publisher = $publisher
            ClassificationRuleCollectionId = $package
            Description = [string](Get-ObjectPropertyValue $detail @('Description'))
            RecommendedConfidence = Get-ObjectPropertyValue $detail @('RecommendedConfidence')
            IsCustomOrModified = ($publisher -notmatch '(?i)^Microsoft$' -or $package -match '(?i)Custom')
            AllProperties = ConvertTo-PropertyBag $detail
        }
    }
}

function Get-SensitiveInformationTypeRulePackageDefinitions {
    $packages = @(Get-DlpSensitiveInformationTypeRulePackage)
    foreach ($package in $packages) {
        $packageName = [string](Get-ObjectPropertyValue $package @('Name','Identity','Id'))
        $bytes = Get-ObjectPropertyValue $package @('SerializedClassificationRuleCollection')
        if ($null -eq $bytes) { continue }
        [byte[]]$byteArray = $bytes
        $safeName = ($packageName -replace '[^A-Za-z0-9_.-]','_')
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'RulePackage' }
        $rawFile = "SIT-RulePackage-$safeName.xml"
        [IO.File]::WriteAllBytes((Join-Path $script:RunPath $rawFile), $byteArray)
        $xmlText = [Text.Encoding]::Unicode.GetString($byteArray).Trim([char]0xFEFF,[char]0x0000)
        try { [xml]$xml = $xmlText } catch { continue }
        $entities = @($xml.SelectNodes("//*[local-name()='Entity']"))
        foreach ($entity in $entities) {
            $id = [string]$entity.id
            $nameNode = $xml.SelectSingleNode("//*[local-name()='Resource' and @idRef='$id']/*[local-name()='Name' and @default='true']")
            if (-not $nameNode) { $nameNode = $xml.SelectSingleNode("//*[local-name()='Resource' and @idRef='$id']/*[local-name()='Name']") }
            $levels = @($entity.SelectNodes("./*[local-name()='Pattern']") | ForEach-Object { [int]$_.confidenceLevel } | Sort-Object -Unique)
            [pscustomobject]@{
                RulePackage = $packageName
                RulePackageRawFile = $rawFile
                SitId = $id
                SitName = if ($nameNode) { [string]$nameNode.InnerText } else { '' }
                RecommendedConfidence = if ($entity.recommendedConfidence) { [int]$entity.recommendedConfidence } else { $null }
                PatternConfidenceLevels = @($levels)
                HasLowConfidence = 65 -in $levels
                HasMediumConfidence = 75 -in $levels
                HasHighConfidence = 85 -in $levels
                MissingStandardConfidenceLevels = @(@(65,75,85) | Where-Object { $_ -notin $levels })
                IsCustomOrModified = $packageName -ne 'Microsoft Rule Package'
            }
        }
    }
}

function Get-DlpRuleSitValidation {
    $sitById = @{}
    $sitByName = @{}
    foreach ($sit in $script:SensitiveInformationTypes) {
        if ($sit.Id) { $sitById[[string]$sit.Id.ToLowerInvariant()] = $sit }
        if ($sit.Name) { $sitByName[[string]$sit.Name.ToLowerInvariant()] = $sit }
    }
    $definitionById = @{}
    foreach ($definition in $script:SensitiveInformationTypeDefinitions) {
        if ($definition.SitId) { $definitionById[[string]$definition.SitId.ToLowerInvariant()] = $definition }
    }
    foreach ($rule in $script:DlpDetailedRules) {
        foreach ($reference in @($rule.SensitiveInformationReferences)) {
            $idKey = [string]$reference.id.ToLowerInvariant()
            $nameKey = [string]$reference.name.ToLowerInvariant()
            $sit = if ($idKey -and $sitById.ContainsKey($idKey)) { $sitById[$idKey] } elseif ($nameKey -and $sitByName.ContainsKey($nameKey)) { $sitByName[$nameKey] } else { $null }
            $definition = if ($idKey -and $definitionById.ContainsKey($idKey)) { $definitionById[$idKey] } elseif ($sit -and $definitionById.ContainsKey(([string]$sit.Id).ToLowerInvariant())) { $definitionById[([string]$sit.Id).ToLowerInvariant()] } else { $null }
            $requested = @($reference.confidenceLevel,$reference.minConfidence,$reference.maxConfidence | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
            $defined = if ($definition) { @($definition.PatternConfidenceLevels) } else { @() }
            $missingRequested = @($requested | Where-Object { $_ -notin $defined })
            $custom = ($sit -and $sit.IsCustomOrModified) -or ($definition -and $definition.IsCustomOrModified) -or ($sit -and $sit.Name -match '(?i)^Ent-')
            $status = if (-not $sit -and -not $definition) { 'Unresolved SIT reference' }
                elseif ($custom -and -not $definition) { 'Custom SIT definition unavailable' }
                elseif ($missingRequested.Count -gt 0) { 'Rule requests confidence not defined by SIT' }
                elseif ($custom -and @($definition.MissingStandardConfidenceLevels).Count -gt 0) { 'Custom SIT does not define all H/M/L patterns' }
                else { 'Validated' }
            [pscustomobject]@{
                RuleName = $rule.Name
                RuleGuid = $rule.Guid
                SitId = if ($reference.id) { $reference.id } elseif ($sit) { $sit.Id } else { '' }
                SitName = if ($reference.name) { $reference.name } elseif ($sit) { $sit.Name } elseif ($definition) { $definition.SitName } else { '' }
                IsCustomOrModified = [bool]$custom
                RequestedConfidenceLevels = @($requested)
                DefinedPatternConfidenceLevels = @($defined)
                MissingRequestedConfidenceLevels = @($missingRequested)
                MissingStandardConfidenceLevels = if ($definition) { @($definition.MissingStandardConfidenceLevels) } else { @() }
                Status = $status
            }
        }
    }
}

function Get-PurviewRoleGroupInventory {
    $groups = @(Get-RoleGroup -ResultSize Unlimited)
    foreach ($group in $groups) {
        $members = @()
        if (Get-Command Get-RoleGroupMember -ErrorAction SilentlyContinue) {
            try { $members = @(Get-RoleGroupMember -Identity $group.Identity -ResultSize Unlimited -ErrorAction Stop) } catch {}
        }
        [pscustomobject]@{
            Name = [string]$group.Name
            DisplayName = [string]$group.DisplayName
            RoleGroupType = [string]$group.RoleGroupType
            Roles = @($group.Roles | ForEach-Object { [string]$_ })
            MemberCount = $members.Count
            Members = if ($IncludeRoleGroupMembers) { @($members | ForEach-Object { [pscustomobject]@{Name=[string]$_.Name;PrimarySmtpAddress=[string]$_.PrimarySmtpAddress;RecipientType=[string]$_.RecipientType} }) } else { @() }
            MemberIdentitiesPersisted = [bool]$IncludeRoleGroupMembers
            ManagedByCount = @($group.ManagedBy).Count
        }
    }
}

function Get-ComplianceCaseInventory {
    param([Parameter(Mandatory)][string]$CaseType)
    $cases = @(Get-ComplianceCase -CaseType $CaseType)
    foreach ($case in $cases) {
        $identity = [string](Get-ObjectPropertyValue $case @('Identity','Guid','Id','Name'))
        [pscustomobject]@{
            CaseType = $CaseType
            CaseKey = if ($identity) { (Get-StringHash $identity).Substring(0,16) } else { '' }
            Name = if ($IncludeCaseNames) { [string]$case.Name } else { $null }
            Status = [string](Get-ObjectPropertyValue $case @('Status','CaseStatus'))
            CreatedTime = Get-ObjectPropertyValue $case @('CreatedTime','WhenCreatedUTC')
            LastModifiedTime = Get-ObjectPropertyValue $case @('LastModifiedTime','WhenChangedUTC')
            ClosedDateTime = Get-ObjectPropertyValue $case @('ClosedDateTime','ClosedTime')
            CaseNamesPersisted = [bool]$IncludeCaseNames
        }
    }
}

function Import-InsiderRiskPolicyExport {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Insider Risk export not found: $Path" }
    $extension = [IO.Path]::GetExtension($Path)
    $tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('purview-irm-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDirectory | Out-Null
    try {
        $files = @()
        if ($extension -ieq '.zip') {
            Expand-Archive -LiteralPath $Path -DestinationPath $tempDirectory -Force
            $files = @(Get-ChildItem -LiteralPath $tempDirectory -File -Recurse)
        } else { $files = @(Get-Item -LiteralPath $Path) }
        foreach ($file in $files) {
            $imported = $null
            if ($file.Extension -ieq '.xml') {
                try { $imported = Import-Clixml -LiteralPath $file.FullName -ErrorAction Stop } catch { try { $imported = [xml](Get-Content -LiteralPath $file.FullName -Raw) } catch {} }
            }
            [pscustomobject]@{
                SourceArchive = [IO.Path]::GetFileName($Path)
                FileName = $file.Name
                FileType = $file.Extension
                SizeBytes = $file.Length
                Imported = $null -ne $imported
                PropertyNames = if ($imported) { @($imported.PSObject.Properties.Name) } else { @() }
                Data = $imported
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempDirectory) {
            $resolved = (Resolve-Path -LiteralPath $tempDirectory).Path
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
            if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
        }
    }
}

function Get-GraphReportPeriod {
    param([Parameter(Mandatory)][int]$Days)
    if ($Days -eq 30) { return 'D30' }
    return 'D90'
}

function ConvertTo-Int64Safe {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return [int64]0 }
    $number = [int64]0
    if ([int64]::TryParse(([string]$Value), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    return [int64]0
}

function Get-GraphCsvAggregate {
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$ReportName,
        [Parameter(Mandatory)][string[]]$Columns
    )

    $period = Get-GraphReportPeriod -Days $LookbackDays
    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ('purview-{0}.csv' -f ([guid]::NewGuid().ToString('N')))
    try {
        & $CommandName -Period $period -OutFile $tempPath | Out-Null
        $rows = @(Import-Csv -LiteralPath $tempPath)
        $cutoff = [DateTime]::UtcNow.Date.AddDays(-1 * ($LookbackDays - 1))

        if ($LookbackDays -eq 60) {
            $rows = @($rows | Where-Object {
                $reportDate = [DateTime]::MinValue
                [DateTime]::TryParse([string]$_.'Report Date', [ref]$reportDate) -and $reportDate.Date -ge $cutoff
            })
        }

        $totals = [ordered]@{}
        foreach ($column in $Columns) {
            $sum = [int64]0
            foreach ($row in $rows) {
                $sum += ConvertTo-Int64Safe -Value $row.$column
            }
            $totals[$column] = $sum
        }

        $daily = foreach ($row in $rows) {
            $entry = [ordered]@{
                reportDate = $row.'Report Date'
                reportPeriod = $row.'Report Period'
            }
            foreach ($column in $Columns) {
                $entry[$column] = ConvertTo-Int64Safe -Value $row.$column
            }
            [pscustomobject]$entry
        }

        [pscustomobject]@{
            reportName = $ReportName
            requestedLookbackDays = $LookbackDays
            graphPeriodRequested = $period
            filteredFromD90ForSixtyDays = ($LookbackDays -eq 60)
            cutoffDateUtc = $cutoff.ToString('yyyy-MM-dd')
            rowCount = $rows.Count
            totals = [pscustomobject]$totals
            daily = @($daily)
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Get-DirectoryCoverageSummary {
    param([Parameter(Mandatory)]$ScoreConfiguration)

    $skus = @(Get-MgSubscribedSku -All)
    $users = @(Get-MgUser -All -Property Id,AccountEnabled,AssignedLicenses,AssignedPlans,UserType)

    $skuById = @{}
    foreach ($sku in $skus) {
        $skuById[[string]$sku.SkuId] = [string]$sku.SkuPartNumber
    }

    $activeMembers = @($users | Where-Object { $_.AccountEnabled -eq $true -and $_.UserType -eq 'Member' })
    $activeGuests = @($users | Where-Object { $_.AccountEnabled -eq $true -and $_.UserType -eq 'Guest' })
    $activeLicensedMembers = @($activeMembers | Where-Object { @($_.AssignedLicenses).Count -gt 0 })

    $assignmentCounts = @{}
    foreach ($user in $activeMembers) {
        foreach ($license in @($user.AssignedLicenses)) {
            $skuName = $skuById[[string]$license.SkuId]
            if ([string]::IsNullOrWhiteSpace($skuName)) { $skuName = [string]$license.SkuId }
            if (-not $assignmentCounts.ContainsKey($skuName)) { $assignmentCounts[$skuName] = 0 }
            $assignmentCounts[$skuName]++
        }
    }

    $eligibleSkuNames = @($ScoreConfiguration.collection.eligibleLicensing.skuPartNumbers)
    $eligiblePlanNames = @($ScoreConfiguration.collection.eligibleLicensing.servicePlanNames)
    $eligibleConfigured = ($eligibleSkuNames.Count + $eligiblePlanNames.Count) -gt 0
    $eligibleUserCount = $null

    if ($eligibleConfigured) {
        $eligibleSkuIds = @($skus | Where-Object { $_.SkuPartNumber -in $eligibleSkuNames } | ForEach-Object { [string]$_.SkuId })
        $eligibleUserCount = @($activeMembers | Where-Object {
            $user = $_
            $hasSku = @($user.AssignedLicenses | Where-Object { [string]$_.SkuId -in $eligibleSkuIds }).Count -gt 0
            $hasPlan = $false
            if ($eligiblePlanNames.Count -gt 0) {
                $hasPlan = @($user.AssignedPlans | Where-Object {
                    $planName = if ($_.PSObject.Properties['ServicePlanName']) { [string]$_.ServicePlanName } elseif ($_.PSObject.Properties['Service']) { [string]$_.Service } else { '' }
                    $planName -in $eligiblePlanNames -and $_.CapabilityStatus -eq 'Enabled'
                }).Count -gt 0
            }
            $hasSku -or $hasPlan
        }).Count
    }

    [pscustomobject]@{
        totalDirectoryUsers = $users.Count
        activeMemberUsers = $activeMembers.Count
        activeGuestUsers = $activeGuests.Count
        disabledUsers = @($users | Where-Object { $_.AccountEnabled -ne $true }).Count
        activeMemberUsersWithAnyLicense = $activeLicensedMembers.Count
        generalLicenseCoverageRatio = if ($activeMembers.Count -gt 0) { [Math]::Round($activeLicensedMembers.Count / $activeMembers.Count, 6) } else { $null }
        eligibleLicenseConfigurationPresent = $eligibleConfigured
        eligibleSkuPartNumbers = $eligibleSkuNames
        eligibleServicePlanNames = $eligiblePlanNames
        activeTargetUsersWithEligibleSkuOrPlan = $eligibleUserCount
        eligibleLicenseCoverageRatio = if ($eligibleConfigured -and $activeMembers.Count -gt 0) { [Math]::Round($eligibleUserCount / $activeMembers.Count, 6) } else { $null }
        eligibleLicenseEvidenceStatus = if ($eligibleConfigured) { 'Observed' } else { 'Unavailable' }
        eligibleLicenseMessage = if ($eligibleConfigured) { $null } else { 'Configure eligible SKU part numbers or service plan names in scoring-config.json.' }
        activeAssignmentsBySku = @($assignmentCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ skuPartNumber = $_.Name; activeAssignedUsers = $_.Value }
        })
    }
}

function Get-ActivityExplorerAggregate {
    param([Parameter(Mandatory)]$ActivityConfiguration)

    $windowDays = [Math]::Min([int]$ActivityConfiguration.maximumLookbackDays, $LookbackDays)
    $endTime = [DateTime]::UtcNow.AddMinutes(-5)
    $startTime = $endTime.AddDays(-1 * $windowDays).AddMinutes(10)
    $pageSize = [int]$ActivityConfiguration.pageSize
    $maximumPages = [int]$ActivityConfiguration.maximumPages

    $activityCounts = @{}
    $workloadCounts = @{}
    $labelCounts = @{}
    $policyCounts = @{}
    $distinctUsers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $totalRecords = 0
    $pages = 0
    $pageCookie = $null

    do {
        $parameters = @{
            StartTime = $startTime
            EndTime = $endTime
            OutputFormat = 'Json'
            PageSize = $pageSize
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$pageCookie)) {
            $parameters.PageCookie = $pageCookie
        }

        $response = Export-ActivityExplorerData @parameters
        $pages++
        $records = @()
        if ($null -ne $response.ResultData) {
            if ($response.ResultData -is [string]) {
                $records = @($response.ResultData | ConvertFrom-Json)
            }
            else {
                $records = @($response.ResultData)
            }
        }

        foreach ($record in $records) {
            $totalRecords++
            $activity = [string]$record.Activity
            $workload = [string]$record.Workload
            $label = if ($record.PSObject.Properties['SensitivityLabel']) { [string]$record.SensitivityLabel } elseif ($record.PSObject.Properties['LabelName']) { [string]$record.LabelName } else { '' }
            $policy = if ($record.PSObject.Properties['PolicyName']) { [string]$record.PolicyName } else { '' }
            $user = if ($record.PSObject.Properties['UserId']) { [string]$record.UserId } elseif ($record.PSObject.Properties['User']) { [string]$record.User } else { '' }

            foreach ($pair in @(@($activityCounts, $activity), @($workloadCounts, $workload), @($labelCounts, $label), @($policyCounts, $policy))) {
                $table = $pair[0]
                $key = [string]$pair[1]
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                if (-not $table.ContainsKey($key)) { $table[$key] = 0 }
                $table[$key]++
            }
            if (-not [string]::IsNullOrWhiteSpace($user)) { [void]$distinctUsers.Add($user) }
        }

        $pageCookie = if ($response.PSObject.Properties['PageCookie']) { [string]$response.PageCookie } elseif ($response.PSObject.Properties['WaterMark']) { [string]$response.WaterMark } else { $null }
        $morePages = if ($response.PSObject.Properties['MorePagesAvailable']) { [bool]$response.MorePagesAvailable } else { -not [string]::IsNullOrWhiteSpace([string]$pageCookie) }
    } while ($morePages -and $pages -lt $maximumPages)

    $toRows = {
        param($Table, $KeyName)
        @($Table.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            $entry = [ordered]@{ count = $_.Value }
            $entry[$KeyName] = $_.Name
            [pscustomobject]$entry
        })
    }

    [pscustomobject]@{
        startTimeUtc = $startTime.ToString('o')
        endTimeUtc = $endTime.ToString('o')
        requestedLookbackDays = $LookbackDays
        effectiveLookbackDays = $windowDays
        totalRecords = $totalRecords
        pagesRead = $pages
        maximumPages = $maximumPages
        truncated = ($morePages -and $pages -ge $maximumPages)
        distinctUserCount = $distinctUsers.Count
        activityCounts = & $toRows $activityCounts 'activity'
        workloadCounts = & $toRows $workloadCounts 'workload'
        labelCounts = & $toRows $labelCounts 'label'
        policyCounts = & $toRows $policyCounts 'policy'
        detailedRecordsPersisted = $false
    }
}

function Get-AdvancedHuntingAggregate {
    param([Parameter(Mandatory)]$HuntingConfiguration)

    $queries = @($HuntingConfiguration.queries | Where-Object { $_.PSObject.Properties['enabled'] -and $_.enabled -eq $true })
    if ($queries.Count -eq 0) {
        throw 'Advanced Hunting is enabled but no enabled aggregate query is configured.'
    }

    foreach ($item in $queries) {
        $queryText = [string]$item.query
        if ($HuntingConfiguration.requireSummarizeOperator -and $queryText -notmatch '(?i)\bsummarize\b') {
            throw "Advanced Hunting query '$($item.name)' does not contain the required summarize operator."
        }

        $body = @{
            query = $queryText
            timespan = "P${LookbackDays}D"
        } | ConvertTo-Json -Depth 10

        $result = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/security/runHuntingQuery' -Body $body -ContentType 'application/json'
        [pscustomobject]@{
            name = [string]$item.name
            timespan = "P${LookbackDays}D"
            query = $queryText
            schema = $result.schema
            results = $result.results
        }
    }
}

function Get-ContentExplorerAggregate {
    param([Parameter(Mandatory)]$ContentConfiguration)

    $tags = @($ContentConfiguration.tags)
    if ($tags.Count -eq 0) {
        throw 'Content Explorer is enabled but no tags are configured.'
    }

    foreach ($tag in $tags) {
        $workloads = if ($tag.PSObject.Properties['workloads'] -and @($tag.workloads).Count -gt 0) { @($tag.workloads) } else { @($ContentConfiguration.workloads) }
        foreach ($workload in $workloads) {
            try {
                $response = @(Export-ContentExplorerData -TagType $tag.tagType -TagName $tag.tagName -Workload $workload -PageSize ([int]$ContentConfiguration.pageSize))
                $first = $response | Select-Object -First 1
                [pscustomobject]@{
                    tagType = [string]$tag.tagType
                    tagName = [string]$tag.tagName
                    workload = [string]$workload
                    status = 'Observed'
                    totalCount = if ($null -ne $first -and $first.PSObject.Properties['TotalCount']) { $first.TotalCount } else { 0 }
                    morePagesAvailable = if ($null -ne $first -and $first.PSObject.Properties['MorePagesAvailable']) { $first.MorePagesAvailable } else { $null }
                    message = $null
                    detailedRecordsPersisted = $false
                }
            }
            catch {
                [pscustomobject]@{
                    tagType = [string]$tag.tagType
                    tagName = [string]$tag.tagName
                    workload = [string]$workload
                    status = 'Unavailable'
                    totalCount = $null
                    morePagesAvailable = $null
                    message = $_.Exception.Message
                    detailedRecordsPersisted = $false
                }
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Profile)) {
    $Profile = Select-CollectionProfile
}
if ($script:OnlySources.Count -eq 0 -and $script:InteractiveOnlySources.Count -gt 0) {
    $script:OnlySources = @($script:InteractiveOnlySources)
}
$script:SelectedProfile = $Profile
$profileRank = Get-ProfileRank -Name $Profile

if ([string]::IsNullOrWhiteSpace($ScoreConfigPath)) {
    $ScoreConfigPath = Join-Path $PSScriptRoot 'scoring-config.json'
}
if ([string]::IsNullOrWhiteSpace($CollectedDataPath)) {
    $CollectedDataPath = Join-Path $PSScriptRoot 'Collected Data'
}
if ([string]::IsNullOrWhiteSpace($ExportedDataPath)) {
    $ExportedDataPath = Join-Path $PSScriptRoot 'Exported Data'
}

if (-not (Test-Path -LiteralPath $ScoreConfigPath -PathType Leaf)) {
    throw "Scoring configuration not found: $ScoreConfigPath"
}

$scoreConfiguration = Get-Content -LiteralPath $ScoreConfigPath -Raw | ConvertFrom-Json -Depth 100
Assert-ScoreConfiguration -Configuration $scoreConfiguration
if ($LookbackDays -notin @($scoreConfiguration.collection.allowedLookbackDays)) {
    throw "LookbackDays $LookbackDays is not allowed by the scoring configuration."
}

$runId = '{0}_{1}_{2}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), $Profile, ([guid]::NewGuid().ToString('N').Substring(0, 8))
$script:RunPath = Join-Path $CollectedDataPath $runId
New-Item -ItemType Directory -Path $script:RunPath -Force | Out-Null
Write-AtomicJson -Path (Join-Path $script:RunPath 'Score-Configuration.json') -InputObject $scoreConfiguration
$scoreConfigHash = (Get-FileHash -LiteralPath $ScoreConfigPath -Algorithm SHA256).Hash

$complianceReady = $false
$exchangeReady = $false
$graphReady = $false
$complianceReason = if ($SkipCompliance) { 'Skipped by -SkipCompliance.' } else { 'Compliance connection was not established.' }
$exchangeReason = if ($SkipCompliance) { 'Skipped by -SkipCompliance.' } else { 'Exchange Online connection was not established.' }
$graphReason = if ($SkipGraph) { 'Skipped by -SkipGraph.' } else { 'Microsoft Graph connection was not established.' }

try {
    if (-not $DryRun) {
        if (-not $SkipCompliance) {
            try {
                Import-CollectorModule -Name 'ExchangeOnlineManagement'
            }
            catch {
                $complianceReason = $_.Exception.Message
                Add-RunMessage -Level Warning -Message "Exchange Online module import failed: $complianceReason"
            }

            if (Get-Module -Name 'ExchangeOnlineManagement') {
                if ($profileRank -ge 2 -and -not $SkipExchangeOnlineConnection) {
                    try {
                        $exchangeConnectParameters = @{ ShowBanner = $false }
                        if ($DeviceAuthentication) { $exchangeConnectParameters.DisableWAM = $true }
                        Connect-ExchangeOnline @exchangeConnectParameters
                        $exchangeReady = $true
                    }
                    catch {
                        $exchangeReason = $_.Exception.Message
                        Add-RunMessage -Level Warning -Message "Exchange Online connection failed; IRM sources will be unavailable: $exchangeReason"
                    }
                }

                try {
                    $complianceConnectParameters = @{ ShowBanner = $false }
                    if ($DeviceAuthentication) { $complianceConnectParameters.DisableWAM = $true }
                    Connect-IPPSSession @complianceConnectParameters
                    $complianceReady = $true
                    Add-RunMessage -Level Information -Message 'Connected to Security & Compliance PowerShell.'
                }
                catch {
                    $complianceReason = $_.Exception.Message
                    Add-RunMessage -Level Warning -Message "Compliance connection failed: $complianceReason"
                }
            }
        }

        if (-not $SkipGraph) {
            try {
                foreach ($module in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Reports')) {
                    Import-CollectorModule -Name $module
                }

                $graphScopes = [Collections.Generic.List[string]]::new()
                foreach ($scope in @('Organization.Read.All', 'LicenseAssignment.Read.All', 'User.Read.All', 'Reports.Read.All')) { $graphScopes.Add($scope) }
                if ($profileRank -ge 3 -and $scoreConfiguration.collection.advancedHunting.enabled -and ($script:OnlySources.Count -eq 0 -or 'AdvancedHuntingAggregate' -in $script:OnlySources)) {
                    $graphScopes.Add('ThreatHunting.Read.All')
                }
                $graphConnectParameters = @{
                    Scopes = @($graphScopes)
                    ContextScope = 'Process'
                    NoWelcome = $true
                }
                if ($DeviceAuthentication) { $graphConnectParameters.UseDeviceCode = $true }
                Connect-MgGraph @graphConnectParameters
                $graphReady = $true
                Add-RunMessage -Level Information -Message 'Connected to Microsoft Graph.'
            }
            catch {
                $graphReason = $_.Exception.Message
                Add-RunMessage -Level Warning -Message "Microsoft Graph connection failed: $graphReason"
            }
        }
    }

    $complianceDisabledStatus = if ($SkipCompliance) { 'NotCollected' } else { 'Unavailable' }
    $graphDisabledStatus = if ($SkipGraph) { 'NotCollected' } else { 'Unavailable' }

    Invoke-CollectionStep -Name 'SensitiveInformationTypes' -Source 'Microsoft Purview Data Classification' -Command 'Get-DlpSensitiveInformationType -Identity <each SIT>' -RequiredCommands 'Get-DlpSensitiveInformationType' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
        $script:SensitiveInformationTypes = @(Get-SensitiveInformationTypeDetails)
        $script:SensitiveInformationTypes
    }

    Invoke-CollectionStep -Name 'SensitiveInformationTypeRulePackages' -Source 'Microsoft Purview Data Classification' -Command 'Get-DlpSensitiveInformationTypeRulePackage (parsed XML plus raw local XML)' -RequiredCommands 'Get-DlpSensitiveInformationTypeRulePackage' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
        $script:SensitiveInformationTypeDefinitions = @(Get-SensitiveInformationTypeRulePackageDefinitions)
        $script:SensitiveInformationTypeDefinitions
    }

    Invoke-CollectionStep -Name 'DLPPolicies' -Source 'Microsoft Purview DLP' -Command 'Get-DlpCompliancePolicy -Identity <each policy> -DistributionDetail -IncludeExtendedProperties $true -IncludeRulesMetadata $true' -RequiredCommands 'Get-DlpCompliancePolicy' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
        Get-DlpPolicyDetails
    }

    Invoke-CollectionStep -Name 'DLPRules' -Source 'Microsoft Purview DLP' -Command 'Get-DlpComplianceRule -Identity <each rule> (full property bag and AdvancedRule parsing)' -RequiredCommands 'Get-DlpComplianceRule' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
        $script:DlpDetailedRules = @(Get-DlpRuleDetails)
        $script:DlpDetailedRules
    }

    Invoke-CollectionStep -Name 'DlpRuleSitValidation' -Source 'Local evidence validation' -Command 'Cross-check detailed DLP rule SIT references against custom rule-package confidence patterns' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
        Get-DlpRuleSitValidation
    }

    Invoke-CollectionStep -Name 'SensitivityLabels' -Source 'Microsoft Purview Information Protection' -Command 'Get-Label' -RequiredCommands 'Get-Label' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
        Get-Label | Select-Object DisplayName, Name, Guid, ParentLabelDisplayName, ParentId, IsParent, IsLabelGroup, Tooltip, DefaultContentLabel, ContentType, LocaleSettings, SchematizedDataCondition, ColumnAssetCondition, LabelActions, Settings, Priority, Workload, Policy, CreatedBy, LastModifiedBy, WhenChangedUTC, WhenCreatedUTC, Comment, Conditions
    }

    Invoke-CollectionStep -Name 'LabelPolicies' -Source 'Microsoft Purview Information Protection' -Command 'Get-LabelPolicy -Identity <each policy> (detailed property bag)' -RequiredCommands 'Get-LabelPolicy' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
        foreach ($summary in @(Get-LabelPolicy)) {
            $identity = [string](Get-ObjectPropertyValue $summary @('Guid','Identity','Id','Name'))
            try { $detail = Get-LabelPolicy -Identity $identity -ErrorAction Stop | Select-Object -First 1 } catch { $detail = $summary }
            if (-not $detail) { $detail = $summary }
            $detail | Select-Object Name, Guid, WhenChangedUTC, WhenCreatedUTC, Enabled, Mode, DistributionStatus, Type, Settings, Labels, ScopedLabels, PolicySettingsBlob, Workload, CreatedBy, LastModifiedBy, ExchangeLocation, ModernGroupLocation, @{Name='AllProperties';Expression={ConvertTo-PropertyBag $_}}
        }
    }

    Invoke-CollectionStep -Name 'Organization' -Source 'Microsoft Graph' -Command 'Get-MgOrganization' -RequiredCommands 'Get-MgOrganization' -Enabled $graphReady -DisabledStatus $graphDisabledStatus -DisabledReason $graphReason -Action {
        Get-MgOrganization -Property Id,DisplayName,CreatedDateTime,VerifiedDomains | Select-Object Id, DisplayName, CreatedDateTime, VerifiedDomains
    }

    Invoke-CollectionStep -Name 'SubscribedSkus' -Source 'Microsoft Graph' -Command 'Get-MgSubscribedSku' -RequiredCommands 'Get-MgSubscribedSku' -Enabled $graphReady -DisabledStatus $graphDisabledStatus -DisabledReason $graphReason -Action {
        Get-MgSubscribedSku -All | Select-Object SkuId, SkuPartNumber, AppliesTo, CapabilityStatus, ConsumedUnits, PrepaidUnits, ServicePlans
    }

    Invoke-CollectionStep -Name 'DirectoryCoverage' -Source 'Microsoft Graph' -Command 'Get-MgUser; Get-MgSubscribedSku (aggregate only)' -RequiredCommands @('Get-MgUser', 'Get-MgSubscribedSku') -Enabled $graphReady -DisabledStatus $graphDisabledStatus -DisabledReason $graphReason -Action {
        Get-DirectoryCoverageSummary -ScoreConfiguration $scoreConfiguration
    }

    Invoke-CollectionStep -Name 'EmailActivityCounts' -Source 'Microsoft Graph Reports' -Command 'Get-MgReportEmailActivityCount' -RequiredCommands 'Get-MgReportEmailActivityCount' -Enabled $graphReady -DisabledStatus $graphDisabledStatus -DisabledReason $graphReason -Action {
        Get-GraphCsvAggregate -CommandName 'Get-MgReportEmailActivityCount' -ReportName 'Email activity counts' -Columns @('Send', 'Receive', 'Read', 'Meeting Created', 'Meeting Interacted')
    }

    Invoke-CollectionStep -Name 'OneDriveFileCounts' -Source 'Microsoft Graph Reports' -Command 'Get-MgReportOneDriveUsageFileCount' -RequiredCommands 'Get-MgReportOneDriveUsageFileCount' -Enabled $graphReady -DisabledStatus $graphDisabledStatus -DisabledReason $graphReason -Action {
        Get-GraphCsvAggregate -CommandName 'Get-MgReportOneDriveUsageFileCount' -ReportName 'OneDrive usage file counts' -Columns @('Total', 'Active')
    }

    Invoke-CollectionStep -Name 'SharePointFileCounts' -Source 'Microsoft Graph Reports' -Command 'Get-MgReportSharePointSiteUsageFileCount' -RequiredCommands 'Get-MgReportSharePointSiteUsageFileCount' -Enabled $graphReady -DisabledStatus $graphDisabledStatus -DisabledReason $graphReason -Action {
        Get-GraphCsvAggregate -CommandName 'Get-MgReportSharePointSiteUsageFileCount' -ReportName 'SharePoint site usage file counts' -Columns @('Total', 'Active')
    }

    if ($profileRank -ge 2) {
        Invoke-CollectionStep -Name 'IRMConfiguration' -Source 'Exchange Online' -Command 'Get-IRMConfiguration' -RequiredCommands 'Get-IRMConfiguration' -Enabled $exchangeReady -DisabledStatus $complianceDisabledStatus -DisabledReason $exchangeReason -Action {
            Get-IRMConfiguration | Select-Object InternalLicensingEnabled, ExternalLicensingEnabled, AzureRMSLicensingEnabled, SimplifiedClientAccessEnabled, ClientAccessServerEnabled, SearchEnabled, JournalReportDecryptionEnabled, TransportDecryptionSetting, EDiscoverySuperUserEnabled, LicensingLocation
        }

        Invoke-CollectionStep -Name 'RMSTrustedPublishingDomains' -Source 'Exchange Online' -Command 'Get-RMSTrustedPublishingDomain' -RequiredCommands 'Get-RMSTrustedPublishingDomain' -Enabled $exchangeReady -DisabledStatus $complianceDisabledStatus -DisabledReason $exchangeReason -Action {
            Get-RMSTrustedPublishingDomain | Select-Object Name, Default, Status, KeyId, ExtranetLicensingUrl, IntranetLicensingUrl, LicensingLocation
        }

        Invoke-CollectionStep -Name 'RMSTemplates' -Source 'Exchange Online' -Command 'Get-RMSTemplate' -RequiredCommands 'Get-RMSTemplate' -Enabled $exchangeReady -DisabledStatus $complianceDisabledStatus -DisabledReason $exchangeReason -Action {
            Get-RMSTemplate | Select-Object Name, Id, Guid, Description, Type, Status, DistributionPoint, Archive, WhenChangedUTC
        }

        Invoke-CollectionStep -Name 'IRMTransportRules' -Source 'Exchange Online' -Command 'Get-TransportRule (IRM/OME actions only)' -RequiredCommands 'Get-TransportRule' -Enabled $exchangeReady -DisabledStatus $complianceDisabledStatus -DisabledReason $exchangeReason -Action {
            Get-TransportRule | Where-Object {
                $rule = $_
                ($rule.PSObject.Properties['ApplyRightsProtectionTemplate'] -and $null -ne $rule.ApplyRightsProtectionTemplate) -or
                ($rule.PSObject.Properties['ApplyOME'] -and [bool]$rule.ApplyOME) -or
                ($rule.PSObject.Properties['RemoveOME'] -and [bool]$rule.RemoveOME)
            } | Select-Object Name, Guid, State, Mode, Priority, ApplyRightsProtectionTemplate, ApplyOME, RemoveOME, FromScope, SentToScope, ExceptIfFromScope, ExceptIfSentToScope, Comments, WhenChangedUTC
        }

        Invoke-CollectionStep -Name 'RetentionLabels' -Source 'Microsoft Purview Data Lifecycle Management' -Command 'Get-ComplianceTag' -RequiredCommands 'Get-ComplianceTag' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            Get-ComplianceTag | Select-Object Name, Guid, RetentionAction, RetentionDuration, RetentionType, IsRecordLabel, IsRegulatoryLabel, BehaviorDuringRetentionPeriod, ActionAfterRetentionPeriod, Workload, WhenCreatedUTC, WhenChangedUTC
        }

        Invoke-CollectionStep -Name 'RetentionPolicies' -Source 'Microsoft Purview Data Lifecycle Management' -Command 'Get-RetentionCompliancePolicy' -RequiredCommands 'Get-RetentionCompliancePolicy' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            Get-RetentionCompliancePolicy | Select-Object Name, Guid, Enabled, Mode, Workload, ExchangeLocation, SharePointLocation, OneDriveLocation, ModernGroupLocation, TeamsChatLocation, TeamsChannelLocation, WhenCreatedUTC, WhenChangedUTC, DistributionStatus
        }

        Invoke-CollectionStep -Name 'RetentionRules' -Source 'Microsoft Purview Data Lifecycle Management' -Command 'Get-RetentionComplianceRule' -RequiredCommands 'Get-RetentionComplianceRule' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            Get-RetentionComplianceRule | Select-Object Name, Guid, Policy, Disabled, RetentionDuration, RetentionComplianceAction, ExpirationDateOption, ContentMatchQuery, ApplyComplianceTag, WhenCreatedUTC, WhenChangedUTC
        }

        $activityEnabled = $complianceReady -and [bool]$scoreConfiguration.collection.activityExplorer.enabled
        $activityReason = if (-not $scoreConfiguration.collection.activityExplorer.enabled) { 'Disabled in scoring-config.json.' } else { $complianceReason }
        $activityStatus = if (-not $scoreConfiguration.collection.activityExplorer.enabled) { 'NotCollected' } else { $complianceDisabledStatus }
        Invoke-CollectionStep -Name 'ActivityExplorerAggregate' -Source 'Microsoft Purview Activity Explorer' -Command 'Export-ActivityExplorerData (aggregated in memory)' -RequiredCommands 'Export-ActivityExplorerData' -Enabled $activityEnabled -DisabledStatus $activityStatus -DisabledReason $activityReason -Action {
            Get-ActivityExplorerAggregate -ActivityConfiguration $scoreConfiguration.collection.activityExplorer
        }
    }

    if ($profileRank -ge 3) {
        Invoke-CollectionStep -Name 'InformationBarrierSegments' -Source 'Microsoft Purview Information Barriers' -Command 'Get-OrganizationSegment' -RequiredCommands 'Get-OrganizationSegment' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            Get-OrganizationSegment | Select-Object Name, Guid, UserGroupFilter, CreatedBy, LastModifiedBy, WhenCreatedUTC, WhenChangedUTC
        }

        Invoke-CollectionStep -Name 'InformationBarrierPolicies' -Source 'Microsoft Purview Information Barriers' -Command 'Get-InformationBarrierPolicy' -RequiredCommands 'Get-InformationBarrierPolicy' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            Get-InformationBarrierPolicy | Select-Object Name, Guid, State, AssignedSegment, SegmentsAllowed, SegmentsBlocked, WhenCreatedUTC, WhenChangedUTC
        }

        Invoke-CollectionStep -Name 'CommunicationCompliancePolicies' -Source 'Microsoft Purview Communication Compliance' -Command 'Get-SupervisoryReviewPolicyV2' -RequiredCommands 'Get-SupervisoryReviewPolicyV2' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            Get-SupervisoryReviewPolicyV2 | Select-Object Name, Guid, Enabled, Workload, PolicyType, Reviewers, WhenCreatedUTC, WhenChangedUTC
        }

        $huntingConfigured = [bool]$scoreConfiguration.collection.advancedHunting.enabled
        Invoke-CollectionStep -Name 'AdvancedHuntingAggregate' -Source 'Microsoft Graph Security' -Command 'POST /security/runHuntingQuery' -RequiredCommands 'Invoke-MgGraphRequest' -Enabled ($graphReady -and $huntingConfigured) -DisabledStatus $(if ($huntingConfigured) { $graphDisabledStatus } else { 'NotCollected' }) -DisabledReason $(if ($huntingConfigured) { $graphReason } else { 'Disabled in scoring-config.json; configure reviewed aggregate queries first.' }) -Action {
            Get-AdvancedHuntingAggregate -HuntingConfiguration $scoreConfiguration.collection.advancedHunting
        }

        $contentConfigured = [bool]$scoreConfiguration.collection.contentExplorer.enabled
        Invoke-CollectionStep -Name 'ContentExplorerAggregate' -Source 'Microsoft Purview Content Explorer' -Command 'Export-ContentExplorerData (counts only)' -RequiredCommands 'Export-ContentExplorerData' -Enabled ($complianceReady -and $contentConfigured) -DisabledStatus $(if ($contentConfigured) { $complianceDisabledStatus } else { 'NotCollected' }) -DisabledReason $(if ($contentConfigured) { $complianceReason } else { 'Disabled in scoring-config.json; configure tag names first.' }) -Action {
            Get-ContentExplorerAggregate -ContentConfiguration $scoreConfiguration.collection.contentExplorer
        }

        Invoke-CollectionStep -Name 'eDiscoveryCases' -Source 'Microsoft Purview eDiscovery' -Command 'Get-ComplianceCase -CaseType eDiscovery; Get-ComplianceCase -CaseType AdvancedEdiscovery' -RequiredCommands 'Get-ComplianceCase' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            @(Get-ComplianceCaseInventory -CaseType 'eDiscovery') + @(Get-ComplianceCaseInventory -CaseType 'AdvancedEdiscovery')
        }

        Invoke-CollectionStep -Name 'InsiderRiskCases' -Source 'Microsoft Purview Insider Risk Management' -Command 'Get-ComplianceCase -CaseType InsiderRisk' -RequiredCommands 'Get-ComplianceCase' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            Get-ComplianceCaseInventory -CaseType 'InsiderRisk'
        }

        Invoke-CollectionStep -Name 'PurviewRoleGroups' -Source 'Microsoft Purview RBAC' -Command 'Get-RoleGroup; Get-RoleGroupMember (counts by default)' -RequiredCommands 'Get-RoleGroup' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            Get-PurviewRoleGroupInventory
        }

        Invoke-CollectionStep -Name 'ImportedInsiderRiskPolicyExport' -Source 'Microsoft Purview portal policy export' -Command 'Import-Clixml / local XML import from administrator-provided export' -Enabled (-not [string]::IsNullOrWhiteSpace($InsiderRiskExportPath)) -DisabledStatus 'NotCollected' -DisabledReason 'No -InsiderRiskExportPath was provided. Microsoft does not expose a supported public PowerShell cmdlet for full Insider Risk policy configuration.' -Action {
            Import-InsiderRiskPolicyExport -Path $InsiderRiskExportPath
        }

        Invoke-CollectionStep -Name 'PurviewDiagnosticExport' -Source 'Microsoft Purview diagnostics' -Command 'Export-PurviewConfig -Components DLP,MIPLabels,ClassificationAndTextExtraction,DLM' -RequiredCommands 'Export-PurviewConfig' -Enabled $complianceReady -DisabledStatus $complianceDisabledStatus -DisabledReason $complianceReason -Action {
            [byte[]]$bytes = Export-PurviewConfig -Components DLP,MIPLabels,ClassificationAndTextExtraction,DLM
            $artifactName = 'Purview-Diagnostic-Configuration.zip'
            $artifactPath = Join-Path $script:RunPath $artifactName
            [IO.File]::WriteAllBytes($artifactPath, $bytes)
            [pscustomobject]@{
                file = $artifactName
                sizeBytes = $bytes.Length
                sha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
                components = @('DLP','MIPLabels','ClassificationAndTextExtraction','DLM')
                note = 'Read-only diagnostic export retained locally for full-fidelity configuration analysis.'
            }
        }
    }
}
finally {
    if (-not $DryRun) {
        if ($graphReady -and (Get-Command -Name Disconnect-MgGraph -ErrorAction SilentlyContinue)) {
            try { Disconnect-MgGraph | Out-Null } catch { Add-RunMessage -Level Warning -Message "Graph disconnect warning: $($_.Exception.Message)" }
        }
        if (($complianceReady -or $exchangeReady) -and (Get-Command -Name Disconnect-ExchangeOnline -ErrorAction SilentlyContinue)) {
            try { Disconnect-ExchangeOnline -Confirm:$false } catch { Add-RunMessage -Level Warning -Message "Exchange disconnect warning: $($_.Exception.Message)" }
        }
    }

    $runEndedUtc = [DateTime]::UtcNow
    $manifest = [ordered]@{
        schemaVersion = '1.0.0'
        collectorVersion = $script:CollectorVersion
        runId = $runId
        profile = $Profile
        lookbackDays = $LookbackDays
        dryRun = [bool]$DryRun
        deviceAuthentication = [bool]$DeviceAuthentication
        onlySources = @($script:OnlySources)
        skipExchangeOnlineConnection = [bool]$SkipExchangeOnlineConnection
        includeRoleGroupMembers = [bool]$IncludeRoleGroupMembers
        includeCaseNames = [bool]$IncludeCaseNames
        insiderRiskExportProvided = -not [string]::IsNullOrWhiteSpace($InsiderRiskExportPath)
        startedAtUtc = $script:RunStartedUtc.ToString('o')
        endedAtUtc = $runEndedUtc.ToString('o')
        durationSeconds = [Math]::Round(($runEndedUtc - $script:RunStartedUtc).TotalSeconds, 3)
        scoreConfiguration = [ordered]@{
            sourcePath = (Resolve-Path -LiteralPath $ScoreConfigPath).Path
            snapshotFile = 'Score-Configuration.json'
            sha256 = $scoreConfigHash
            modelVersion = [string]$scoreConfiguration.model.version
        }
        privacy = [ordered]@{
            aggregateFirst = $true
            detailedActivityExplorerRecordsPersisted = $false
            directoryUsersPersisted = $false
            roleGroupMemberIdentitiesPersisted = [bool]$IncludeRoleGroupMembers
            complianceCaseNamesPersisted = [bool]$IncludeCaseNames
        }
        connections = [ordered]@{
            complianceReady = $complianceReady
            exchangeOnlineReady = $exchangeReady
            graphReady = $graphReady
        }
        summary = [ordered]@{
            sourceCount = $script:RunItems.Count
            observed = @($script:RunItems | Where-Object { $_.status -eq 'Observed' }).Count
            notObserved = @($script:RunItems | Where-Object { $_.status -eq 'NotObserved' }).Count
            unavailable = @($script:RunItems | Where-Object { $_.status -eq 'Unavailable' }).Count
            notCollected = @($script:RunItems | Where-Object { $_.status -eq 'NotCollected' }).Count
        }
        evidence = @($script:RunItems)
        messages = @($script:RunMessages)
    }
    Write-AtomicJson -Path (Join-Path $script:RunPath 'Run-Manifest.json') -InputObject $manifest

    $reportGeneratorPath = Join-Path $PSScriptRoot 'Export-PurviewHtmlReport.ps1'
    try {
        if (-not (Test-Path -LiteralPath $reportGeneratorPath -PathType Leaf)) {
            throw "HTML report generator not found: $reportGeneratorPath"
        }
        $script:ReportPath = @(& $reportGeneratorPath -RunPath $script:RunPath -ExportedDataPath $ExportedDataPath) | Select-Object -Last 1
        $manifest['report'] = [ordered]@{
            status = 'Created'
            path = $script:ReportPath
            latestPath = (Join-Path $ExportedDataPath $(if ($DryRun) { 'Purview-Assessment-Latest-DryRun.html' } else { 'Purview-Assessment-Latest.html' }))
        }
    }
    catch {
        Add-RunMessage -Level Warning -Message "HTML report generation failed: $($_.Exception.Message)"
        $manifest['report'] = [ordered]@{
            status = 'Failed'
            message = $_.Exception.Message
        }
    }
    $manifest['messages'] = @($script:RunMessages)
    Write-AtomicJson -Path (Join-Path $script:RunPath 'Run-Manifest.json') -InputObject $manifest
}

Write-Host ''
Write-Host "Collection completed: $script:RunPath"
Write-Host 'Review Run-Manifest.json before using the evidence for scoring.'
if ($script:ReportPath) { Write-Host "HTML report: $script:ReportPath" }

