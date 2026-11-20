<#PSScriptInfo

.VERSION 1.0.0

.GUID 7ffa2766-848b-4832-b54c-7d8f4098ba42

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-20  1.0.0  Consolidate local discovery and retry evidence into verified pending batches.
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/LocalMIPReporting.psm1.
.NOTES
HISTORY
Version     : 1.0.0
Tracking ID : 7ffa2766-848b-4832-b54c-7d8f4098ba42
2026-11-20  Kaz Demos  Initial local batch implementation and verification.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinPSCompatibility.ps1')
$script:ReportUtf8 = [Text.UTF8Encoding]::new($false, $true)
$script:ReportVersion = '1.0.0'

function Read-ReportSource {
    param([string] $Path, [switch] $JsonLines)
    $resolved = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    $stream = [IO.File]::Open($resolved, 'Open', 'Read', 'Read')
    try {
        if ($stream.Length -gt 128MB) { throw 'Report input exceeds the 128 MiB pilot limit.' }
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $digest = ConvertTo-WinPSHex ($hash.ComputeHash($stream)) }
        finally { $hash.Dispose() }
        $stream.Position = 0
        $reader = [IO.StreamReader]::new($stream, $script:ReportUtf8, $false, 16384, $true)
        try {
            $text = $reader.ReadToEnd().TrimStart([char]0xFEFF)
            if ($JsonLines) {
                $items = @(foreach ($line in ($text -split '\r?\n')) {
                    if ($line.Trim()) { ConvertFrom-WinPSJson $line }
                })
            } else { $items = @(ConvertFrom-WinPSJson $text) }
        } finally { $reader.Dispose() }
        return @{ Path = $resolved; Sha256 = $digest; Items = $items }
    } finally { $stream.Dispose() }
}

function Get-ReportPath {
    param($Value)
    if ($Value -isnot [string] -or $Value -notmatch '^[A-Za-z]:[\\/]' -or $Value.Substring(2).Contains(':')) {
        throw 'Expected an absolute Windows file path in a report.'
    }
    return Get-WinPSFullPath $Value
}

function Convert-ReportFindings {
    param($Values)
    foreach ($item in @($Values)) {
        if ($null -eq $item) { continue }
        $id = [guid]::Empty
        if ($item -isnot [hashtable] -or -not [guid]::TryParse($item['SitId'], [ref]$id) -or $id -eq [guid]::Empty -or
            $item['Name'] -isnot [string] -or $item['Count'] -isnot [long] -or $item['Count'] -lt 0 -or
            $item['Confidence'] -isnot [long] -or $item['Confidence'] -lt 0 -or $item['Confidence'] -gt 100) {
            throw 'Invalid SIT finding.'
        }
        # Whitelist metadata. Raw sensitive values and context are never copied.
        [ordered]@{ sitId = $id.ToString(); name = $item['Name']; count = $item['Count']; confidence = $item['Confidence'] }
    }
}

function Convert-DiscoveryRecord {
    param([hashtable] $Item, [int] $LineNumber, [string] $SourceHash)
    $path = Get-ReportPath $Item['Path']
    $outcome = $Item['Result']
    if ($outcome -notin 'Responded','NoResponse','Error','SkippedOfflineOrReparse') { throw 'Unknown discovery outcome.' }
    if ($Item['ClientVersion'] -isnot [string] -or -not $Item['ClientVersion']) { throw 'Missing client version.' }
    foreach ($status in @($Item['NativeStatus'])) {
        if ($status -isnot [string]) { throw 'Native status must be text.' }
    }
    $findings = @(Convert-ReportFindings $Item['Findings'])
    if ($outcome -ne 'Responded' -and $findings.Count -gt 0) { throw 'Findings require a client response.' }
    [ordered]@{
        schemaVersion = 1; eventType = 'DiscoveryResult'; path = $path
        extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
        outcome = $outcome; clientVersion = $Item['ClientVersion']
        nativeStatus = @($Item['NativeStatus']); findings = $findings
        errorId = $Item['ErrorId']; sourceTimeUtc = $Item['StartedUtc']
        provenance = @{
            original = @{
                sha256 = $SourceHash; recordNumber = $LineNumber; outcome = $outcome
                errorId = $Item['ErrorId']; clientVersion = $Item['ClientVersion']
            }
            retry = $null
        }
    }
}

function Get-ReportIdentityHash {
    param($Identity)
    $canonical = [ordered]@{
        contract = $Identity['contract']; consolidatorVersion = $Identity['consolidatorVersion']
        discoverySha256 = $Identity['discoverySha256']; retrySha256 = $Identity['retrySha256']
        inventorySha256 = $Identity['inventorySha256']
        context = [ordered]@{
            tenantId = $Identity['context']['tenantId']
            accountObjectId = $Identity['context']['accountObjectId']
            deviceId = $Identity['context']['deviceId']
        }
    }
    Get-WinPSSha256 ($script:ReportUtf8.GetBytes(($canonical | ConvertTo-Json -Compress -Depth 6)))
}

function Write-ReportFile {
    param([string] $Path, [string[]] $Lines)
    $stream = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
    try {
        $writer = [IO.StreamWriter]::new($stream, $script:ReportUtf8, 16384, $true)
        try {
            foreach ($line in $Lines) { $writer.WriteLine($line) }
            $writer.Flush()
            $stream.Flush($true)
        } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-ReportSummary {
    param($Records, $Coverage)
    $typeTotals = @{}
    foreach ($record in $Records) {
        foreach ($finding in $record.findings) {
            $key = $finding.sitId
            if (-not $typeTotals.ContainsKey($key)) {
                $typeTotals[$key] = @{ sitId = $key; name = $finding.name; findingRecords = 0; matches = [long]0 }
            }
            $typeTotals[$key].findingRecords++
            $typeTotals[$key].matches += $finding.count
        }
    }
    [ordered]@{
        candidateFiles = @($Records).Count
        respondedFiles = @($Records | Where-Object { $_.outcome -eq 'Responded' }).Count
        noResponseFiles = @($Records | Where-Object { $_.outcome -eq 'NoResponse' }).Count
        errorFiles = @($Records | Where-Object { $_.outcome -eq 'Error' }).Count
        skippedFiles = @($Records | Where-Object { $_.outcome -eq 'SkippedOfflineOrReparse' }).Count
        filesWithFindings = @($Records | Where-Object { $_.findings.Count -gt 0 }).Count
        coverageErrors = @($Coverage).Count
        appliedRetryCount = @($Records | Where-Object { $null -ne $_.provenance.retry }).Count
        findingsByType = @($typeTotals.Values | Sort-Object sitId)
        clientVersions = @($Records | ForEach-Object { $_.clientVersion } | Sort-Object -Unique)
        source = 'PurviewClientReference'
        integratedScanner = $false
    }
}

function Test-LocalMIPReportBatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $BatchDirectory)
    $directory = [IO.Path]::GetFullPath($BatchDirectory)
    $manifestPath = Join-Path $directory 'manifest.json'
    $manifest = (Read-ReportSource $manifestPath).Items[0]
    if ($manifest['schemaVersion'] -ne 1 -or $manifest['state'] -ne 'Sealed' -or
        $manifest['batchId'] -cnotmatch '^[0-9A-F]{64}$' -or $manifest['payloads'].Count -ne 3) {
        throw 'Invalid batch manifest.'
    }
    if ((Get-ReportIdentityHash $manifest['identity']) -cne $manifest['batchId']) {
        throw 'Batch identity hash mismatch.'
    }
    $expected = @('records.jsonl','coverage.jsonl','summary.json')
    $seen = @{}
    foreach ($payload in $manifest['payloads']) {
        $name = $payload['name']
        if ($name -notin $expected -or $seen.ContainsKey($name)) { throw 'Unexpected or duplicate batch payload.' }
        $seen[$name] = $true
        $path = Join-Path $directory $name
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse payload is not supported.' }
        if ($item.Length -ne $payload['bytes'] -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $payload['sha256']) {
            throw "Batch payload integrity failure: $name"
        }
    }
    $records = @((Read-ReportSource (Join-Path $directory 'records.jsonl') -JsonLines).Items)
    $coverage = @((Read-ReportSource (Join-Path $directory 'coverage.jsonl') -JsonLines).Items)
    $summary = (Read-ReportSource (Join-Path $directory 'summary.json')).Items[0]
    $computed = Get-ReportSummary $records $coverage
    foreach ($field in 'candidateFiles','respondedFiles','noResponseFiles','errorFiles','skippedFiles','filesWithFindings',
        'coverageErrors','appliedRetryCount') {
        if ($computed[$field] -ne $summary[$field]) { throw "Batch summary count mismatch: $field" }
    }
    [pscustomobject]@{
        Verified = $true; DeliveryState = 'PendingUpload'; BatchId = $manifest['batchId']; BatchDirectory = $directory
        ManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        Summary = $summary
    }
}

function New-LocalMIPReportBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $DiscoveryReport,
        [Parameter(Mandatory)][string] $RetryReport,
        [Parameter(Mandatory)][string] $InventoryLog,
        [Parameter(Mandatory)][guid] $TenantId,
        [string] $AccountObjectId,
        [string] $DeviceId,
        [string] $OutboxDirectory = (Join-Path $env:LOCALAPPDATA 'LocalMIPScanner.WinPS51\Outbox')
    )
    if ($TenantId -eq [guid]::Empty) { throw 'TenantId must be a nonempty GUID.' }
    $discovery = Read-ReportSource $DiscoveryReport -JsonLines
    $retries = Read-ReportSource $RetryReport
    $inventory = Read-ReportSource $InventoryLog -JsonLines
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $line = 0
    foreach ($item in $discovery.Items) {
        $line++
        if ($item -isnot [hashtable]) { throw 'Expected a discovery object.' }
        $record = Convert-DiscoveryRecord $item $line $discovery.Sha256
        if ($map.ContainsKey($record.path)) { throw "Duplicate discovery path: $($record.path)" }
        $map.Add($record.path, $record)
    }
    $inventoryFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $coverage = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in $inventory.Items) {
        if ($item['event'] -eq 'file') {
            $path = Get-ReportPath $item['path']
            if (-not $inventoryFiles.Add($path)) { throw 'Duplicate inventory path.' }
        } elseif ($item['event'] -eq 'error') {
            $coverage.Add([ordered]@{
                eventType = 'CoverageError'; operation = $item['operation']; path = $item['path']
                sourceSha256 = $inventory.Sha256
            })
        }
    }
    $inventorySummary = @($inventory.Items | Where-Object { $_['event'] -eq 'summary' })
    if ($inventorySummary.Count -ne 1 -or $inventorySummary[0]['generationComplete'] -ne $true) {
        throw 'Expected one completed inventory summary.'
    }
    if ($inventoryFiles.Count -ne $map.Count) { throw 'Inventory and discovery counts differ.' }
    if ($inventorySummary[0]['errors'] -ne $coverage.Count) { throw 'Inventory error counts differ.' }
    foreach ($path in @($map.Keys)) {
        if ($inventoryFiles.Contains($path)) { continue }
        $record = $map[$path]
        if ($record.outcome -ne 'Error' -or $record.errorId -notlike 'PathNotFound,*') {
            throw "Discovery path not in inventory: $path"
        }
        # Repair only the documented UTF-8/Windows-1252 read error, and only when
        # the exact recovered path exists in the authoritative inventory.
        $candidate = $path
        $encoding = [Text.Encoding]::GetEncoding(1252, [Text.EncoderFallback]::ExceptionFallback, [Text.DecoderFallback]::ExceptionFallback)
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            try { $candidate = $script:ReportUtf8.GetString($encoding.GetBytes($candidate)) }
            catch { break }
            if ($inventoryFiles.Contains($candidate)) { break }
        }
        if (-not $inventoryFiles.Contains($candidate) -or $map.ContainsKey($candidate)) {
            throw "Cannot reconcile report path with inventory: $path"
        }
        $record.provenance.original.reportedPath = $path
        $record.provenance.original.pathCorrection = 'Windows1252ToUtf8'
        $record.path = $candidate
        $map.Remove($path) | Out-Null
        $map.Add($candidate, $record)
    }
    if ($retries.Items.Count -ne 1 -or -not $retries.Items[0].ContainsKey('ReintentosCSV')) {
        throw 'Expected the diagnostic JSON containing ReintentosCSV.'
    }
    $retried = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $number = 0
    foreach ($item in @($retries.Items[0]['ReintentosCSV'])) {
        $number++
        $path = Get-ReportPath $item['Ruta']
        if (-not $map.ContainsKey($path) -or -not $retried.Add($path)) { throw 'Unknown or duplicate retry path.' }
        $original = $map[$path]
        if ($original.outcome -notin 'Error','NoResponse') { throw 'Retry must target an unresolved discovery record.' }
        if ($item['Registros'] -isnot [long] -or $item['Registros'] -lt 0) { throw 'Invalid retry response count.' }
        # These historical retries have no timestamp or client version of their own.
        $outcome = if ($item['ErrorId']) { 'Error' } elseif ($item['Registros'] -gt 0) { 'Responded' } else { 'NoResponse' }
        $findings = @(foreach ($finding in @($item['TiposDetectados'])) {
            if ($null -ne $finding) {
                @{ SitId = $finding['RuleId']; Name = $finding['Name']; Count = $finding['Count']; Confidence = $finding['Confidence'] }
            }
        })
        $original.provenance.retry = @{
            sha256 = $retries.Sha256; entryNumber = $number; previousOutcome = $original.outcome
            timeUtc = $null; clientVersion = $null
        }
        $original.outcome = $outcome
        $original.nativeStatus = @($item['Estados'])
        foreach ($status in $original.nativeStatus) {
            if ($status -isnot [string]) { throw 'Retry status must be text.' }
        }
        $original.findings = @(Convert-ReportFindings $findings)
        if ($outcome -ne 'Responded' -and $original.findings.Count -gt 0) { throw 'Retry findings require a response.' }
        $original.errorId = $item['ErrorId']
    }
    $context = [ordered]@{
        tenantId = $TenantId.ToString()
        accountObjectId = $(if ($AccountObjectId) { $AccountObjectId } else { $null })
        deviceId = $(if ($DeviceId) { $DeviceId } else { $null })
    }
    $identity = [ordered]@{
        contract = 'LocalMIPReportBatch/v1'; consolidatorVersion = $script:ReportVersion
        discoverySha256 = $discovery.Sha256; retrySha256 = $retries.Sha256; inventorySha256 = $inventory.Sha256
        context = $context
    }
    $batchId = Get-ReportIdentityHash $identity
    $outbox = [IO.Path]::GetFullPath($OutboxDirectory)
    [void][IO.Directory]::CreateDirectory($outbox)
    $lock = [IO.File]::Open((Join-Path $outbox 'writer.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $pending = Join-Path $outbox 'Pending'
        [void][IO.Directory]::CreateDirectory($pending)
        $destination = Join-Path $pending $batchId
        if ([IO.Directory]::Exists($destination)) {
            $verified = Test-LocalMIPReportBatch $destination
            if ($verified.BatchId -cne $batchId) { throw 'Existing batch ID mismatch.' }
            return $verified
        }
        $staging = Join-Path $outbox ('.staging-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($staging)
        [string[]]$paths = @($map.Keys)
        [Array]::Sort($paths, [StringComparer]::OrdinalIgnoreCase)
        $records = @(foreach ($path in $paths) { $map[$path] })
        foreach ($record in $records) {
            $record.batchId = $batchId
            $record.recordId = Get-WinPSSha256 ($script:ReportUtf8.GetBytes($batchId + '|' + $record.path.ToUpperInvariant()))
        }
        $summary = Get-ReportSummary $records $coverage.ToArray()
        Write-ReportFile (Join-Path $staging 'records.jsonl') @($records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 12 })
        Write-ReportFile (Join-Path $staging 'coverage.jsonl') @($coverage | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
        Write-ReportFile (Join-Path $staging 'summary.json') @($summary | ConvertTo-Json -Depth 10)
        $payloads = @(foreach ($name in 'records.jsonl','coverage.jsonl','summary.json') {
            $path = Join-Path $staging $name
            @{ name = $name; bytes = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        })
        $manifest = [ordered]@{
            schemaVersion = 1; state = 'Sealed'; batchId = $batchId
            createdUtc = [datetime]::UtcNow.ToString('o'); consolidatorVersion = $script:ReportVersion
            context = $context; identity = $identity; payloads = $payloads
            sources = @(
                @{ role = 'Discovery'; sha256 = $discovery.Sha256; path = $discovery.Path },
                @{ role = 'RetryDiagnostic'; sha256 = $retries.Sha256; path = $retries.Path },
                @{ role = 'Inventory'; sha256 = $inventory.Sha256; path = $inventory.Path }
            )
        }
        Write-ReportFile (Join-Path $staging 'manifest.json') @($manifest | ConvertTo-Json -Depth 12)
        $null = Test-LocalMIPReportBatch $staging
        [IO.Directory]::Move($staging, $destination)
        Test-LocalMIPReportBatch $destination
    } finally { $lock.Dispose() }
}

Export-ModuleMember -Function New-LocalMIPReportBatch, Test-LocalMIPReportBatch
