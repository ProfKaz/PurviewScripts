<#PSScriptInfo
.VERSION 0.4.0
.GUID 2fa67369-33e7-442c-8a61-bdf80f52860f
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.4.0 Publish verified generation projections for the consolidated portal view.
0.3.0 Independently read back SharePoint Landing files for the compared cycles.
0.2.0 Compare explicitly identified interrupted evidence within a bounded checkpoint gap.
0.1.0 Reconcile locally retained uploaded cycles of one managed generation.
#>
#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Local')]
param(
    [Parameter(Mandatory,ParameterSetName='Local')][Parameter(Mandatory,ParameterSetName='SharePoint')][ValidatePattern('^[0-9a-f]{12,32}$')][string]$RunPrefix,
    [ValidatePattern('^[0-9a-f]{32}$')][string]$InterruptedRunId,
    [string]$UploadedDirectory = (Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner\ManagedEndpoint\outbox\Uploaded'),
    [Parameter(Mandatory,ParameterSetName='SharePoint')]$Connection,
    [Parameter(Mandatory,ParameterSetName='SharePoint')][guid]$LandingListId,
    [Parameter(ParameterSetName='SharePoint')][switch]$PublishGeneration
)
$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'SharePoint') {
    $library = Get-PnPList -Connection $Connection -Identity $LandingListId -Includes RootFolder
    if ($library.Id -ne $LandingListId -or !$library.RootFolder.ServerRelativeUrl) { throw 'Unexpected landing library.' }
    $remoteRoot = $library.RootFolder.ServerRelativeUrl.TrimEnd('/')
}
function Test-LandingDigest([string]$Folder,[string]$Name,[string]$Expected) {
    $stream = Get-PnPFile -Connection $Connection -Url "$Folder/$Name" -AsMemoryStream -ErrorAction Stop
    try {
        $stream.Position = 0
        $actual = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
        if ($actual -ine $Expected) { throw "Remote $Name differs from the verified local batch." }
    } finally { $stream.Dispose() }
}
function Read-JsonFile($Path) {
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
}
function Save-GenerationProjection($Row) {
    $executive = Get-PnPList -Connection $Connection -Identity ScannerPortalExecutive -Includes HasUniqueRoleAssignments,BaseTemplate,RootFolder
    if (!$executive.HasUniqueRoleAssignments -or $executive.BaseTemplate -ne 101 -or $executive.Id -eq $LandingListId) {
        throw 'Unexpected executive library permissions or type.'
    }
    $name = 'generations.json'
    $null = Get-PnPProperty -Connection $Connection -ClientObject $executive.RootFolder -Property Files
    $file = $executive.RootFolder.Files | Where-Object Name -eq $name
    $catalog = [ordered]@{schema=1;generations=@()}
    if ($file) {
        $null = Get-PnPProperty -Connection $Connection -ClientObject $file -Property ETag,ServerRelativeUrl
        $etag = $file.ETag
        $catalog = Get-PnPFile -Url $file.ServerRelativeUrl -AsString -Connection $Connection | ConvertFrom-Json -AsHashtable
        if (!$etag -or $catalog.schema -ne 1 -or $catalog.generations -isnot [array]) { throw 'Invalid stored generation catalog.' }
    }
    $others = @()
    $existing = $null
    foreach ($prior in $catalog.generations) {
        if ($prior.registration -ne $Row.registration -or $prior.generation -ne $Row.generation) { $others += $prior; continue }
        if ($existing -or $prior.profileSha256 -ne $Row.profileSha256 -or $prior.landingListId -ne $Row.landingListId) { throw 'Conflicting generation identity.' }
        $existing = $prior
        foreach ($id in $prior.manifests.Keys) {
            if ($Row.manifests[$id] -ne $prior.manifests[$id]) { throw 'Prior evidence is missing or differs; stored generation preserved.' }
        }
        if ($prior.interruptedRun -and $prior.interruptedRun -ne $Row.interruptedRun) { throw 'Interrupted evidence association changed.' }
    }
    if ($existing -and ($existing | ConvertTo-Json -Compress -Depth 8) -ceq ($Row | ConvertTo-Json -Compress -Depth 8)) { return 'Reused' }
    $catalog.generations = @($Row) + $others
    $json = ConvertTo-Json -InputObject $catalog -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $stream = [IO.MemoryStream]::new($bytes)
    try {
        if ($file) {
            $save = [Microsoft.SharePoint.Client.FileSaveBinaryInformation]::new()
            $save.ETag = $etag
            $save.ContentStream = $stream
            $file.SaveBinary($save)
        } else {
            $create = [Microsoft.SharePoint.Client.FileCreationInformation]::new()
            $create.Url = $name
            $create.Overwrite = $false
            $create.ContentStream = $stream
            $null = $executive.RootFolder.Files.Add($create)
        }
        Invoke-PnPQuery -Connection $Connection
    } finally { $stream.Dispose() }
    $url = $executive.RootFolder.ServerRelativeUrl.TrimEnd('/') + '/' + $name
    $stored = Get-PnPFile -Url $url -AsString -Connection $Connection | ConvertFrom-Json -AsHashtable
    $readback = @($stored.generations | Where-Object { $_.registration -eq $Row.registration -and $_.generation -eq $Row.generation })
    if ($readback.Count -ne 1 -or ($readback[0] | ConvertTo-Json -Depth 8 -Compress) -cne ($Row | ConvertTo-Json -Depth 8 -Compress)) {
        throw 'Generation publication readback did not match. Rerun with the latest evidence.'
    }
    return 'Published'
}
$dirs = @(Get-ChildItem -LiteralPath $UploadedDirectory -Directory | Where-Object Name -Match '^[a-f0-9]{32}$')
$seed = @($dirs | Where-Object Name -Like "$RunPrefix*")
if ($seed.Count -ne 1) { throw "Expected one retained uploaded batch matching $RunPrefix. Found $($seed.Count)." }
$anchor = Read-JsonFile (Join-Path $seed[0].FullName 'summary.json')
$generation = $anchor.summary.generation
if ($generation -notmatch '^[a-f0-9]{32}$' -or !$anchor.executionAccountSid -or !$anchor.registrationId -or
    $anchor.profileSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Incomplete anchor generation identity.' }
$interruptedCycle = $null
$verifiedRemote = 0
$sourceManifests = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
$cycles = @(foreach ($dir in $dirs) {
    $wrapper = Read-JsonFile (Join-Path $dir.FullName 'summary.json')
    $s = $wrapper.summary
    $candidate = $dir.Name -eq $InterruptedRunId
    if (!$candidate -and $s.generation -ne $generation) { continue }
    if ($wrapper.registrationId -ne $anchor.registrationId -or $wrapper.tenantId -ne $anchor.tenantId -or
        $wrapper.profileSha256 -ne $anchor.profileSha256 -or $wrapper.executionAccountSid -ne $anchor.executionAccountSid -or
        $s.runId -ne $dir.Name) { throw 'Inconsistent batch scope.' }
    if ($candidate) {
        if ($s.interrupted -ne $true -or $s.coverage -cne 'PartialInterruptedRun' -or $s.generationComplete -ne $false -or
            ($s.generation -and $s.generation -ne $generation)) { throw 'Expected interrupted evidence.' }
    } elseif ($s.interrupted -or $null -eq $s.resumedDirectories -or
        $s.resumedDirectories -lt 0 -or $null -eq $s.directoriesCompleted -or $s.directoriesCompleted -lt 0 -or
        $s.generationComplete -isnot [bool] -or $s.generationHasErrors -isnot [bool]) { throw 'Inconsistent generation scope or checkpoint.' }
    $receipt = Read-JsonFile (Join-Path $dir.FullName 'delivery.json')
    $manifestPath = Join-Path $dir.FullName 'manifest.json'
    if ($receipt.deliveryState -ne 'UploadedVerified' -or $receipt.batchId -ne $dir.Name -or
        (Get-FileHash -LiteralPath $manifestPath).Hash -ne $receipt.manifestSha256) { throw 'Upload receipt mismatch.' }
    $manifest = Read-JsonFile $manifestPath
    if ($manifest.contract -ne 'ScannerPortal.InventoryRun/1' -or $manifest.batchId -ne $dir.Name -or
        $manifest.registrationId -ne $wrapper.registrationId -or $manifest.tenantId -ne $wrapper.tenantId -or
        $manifest.files.Count -ne 2) { throw 'Unexpected managed manifest.' }
    if ($PSCmdlet.ParameterSetName -eq 'SharePoint') {
        $device = ([guid]$wrapper.registrationId).ToString()
        $remote = "$remoteRoot/devices/$device/batches/$($dir.Name)"
        Test-LandingDigest $remote 'manifest.json' $receipt.manifestSha256
    }
    foreach ($name in 'summary.json','records.jsonl') {
        $entry = @($manifest.files | Where-Object name -CEQ $name)
        $file = Get-Item -LiteralPath (Join-Path $dir.FullName $name)
        if ($entry.Count -ne 1 -or $file.Length -ne $entry[0].length -or
            (Get-FileHash -LiteralPath $file.FullName).Hash -ne $entry[0].sha256) { throw "Invalid $name payload." }
        if ($PSCmdlet.ParameterSetName -eq 'SharePoint') { Test-LandingDigest $remote $name $entry[0].sha256 }
    }
    if ($PSCmdlet.ParameterSetName -eq 'SharePoint') {
        $verifiedRemote++
        $sourceManifests.Add($dir.Name,[string]$receipt.manifestSha256)
    }
    $cycleInfo = [pscustomobject]@{ Summary=$s; Directory=$dir.FullName; Offset=[long]$s.resumedDirectories; Started=[datetimeoffset]$s.startedUtc }
    if ($candidate) { $interruptedCycle = $cycleInfo } else { $cycleInfo }
})
$paths = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
$next = 0L
$gap = $false
$missingDirectories = 0L
$closed = $false
$closingRun = $null
$observations = 0L
$coverageErrors = 0L
$hasErrors = $false
$previous = $null
$bounded = $false
foreach ($cycle in ($cycles | Sort-Object Offset,Started)) {
    $s = $cycle.Summary
    if ($closed -or $cycle.Offset -lt $next) { throw 'Overlapping checkpoints or another cycle after closure.' }
    if ($cycle.Offset -gt $next) {
        $gap = $true
        $missingDirectories += $cycle.Offset - $next
        if ($previous -and $interruptedCycle -and $interruptedCycle.Started -gt $previous.Started -and
            $interruptedCycle.Started -lt $cycle.Started) { $bounded = $true }
    }
    $previous = $cycle
    $next = $cycle.Offset + $s.directoriesCompleted
    $count = 0L
    $terminal = $null
    foreach ($line in [IO.File]::ReadLines((Join-Path $cycle.Directory 'records.jsonl'))) {
        $r = ConvertFrom-Json -InputObject $line
        if ($terminal) { throw 'Unexpected record after summary.' }
        if ($r.event -eq 'summary') { $terminal = $r }
        if ($r.event -ne 'file') { continue }
        if (!$r.path) { throw 'Missing observed path.' }
        $paths[$r.path] = [string]$r.purview.discovery
        $count++
    }
    if ($terminal.runId -ne $s.runId -or $terminal.generationComplete -ne $s.generationComplete -or
        $count -ne $s.inventoried) { throw 'Records do not agree with the cycle summary.' }
    $observations += $count
    $coverageErrors += $s.errors
    $hasErrors = $hasErrors -or $s.generationHasErrors -or $s.errors -gt 0
    if ($s.generationComplete) { $closed=$true; $closingRun=$s.runId }
}
if ($InterruptedRunId) {
    if (!$bounded) { throw 'Interrupted evidence was not found between two uploaded cycles bounding a checkpoint gap.' }
    $distinct = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $fileRows = 0
    foreach ($line in [IO.File]::ReadLines((Join-Path $interruptedCycle.Directory 'records.jsonl'))) {
        $r = ConvertFrom-Json -InputObject $line -ErrorAction Stop
        if ($r.event -eq 'summary' -or ($r.event -eq 'start' -and $r.runId -ne $InterruptedRunId)) { throw 'Unexpected interrupted log identity or terminal record.' }
        if ($r.event -ne 'file') { continue }
        if (!$r.path) { throw 'Missing path in interrupted evidence.' }
        $null = $distinct.Add([string]$r.path)
        $fileRows++
    }
    $newPaths = @($distinct | Where-Object { !$paths.ContainsKey($_) }).Count
    $comparison = [pscustomobject]@{ RunId=$InterruptedRunId; Association='SameScopeAndGapTimeWindow'
        FileRows=$fileRows; UniquePaths=$distinct.Count; AlreadyObservedPaths=$distinct.Count-$newPaths
        AdditionalObservedPaths=$newPaths; CombinedDistinctObservedPaths=$paths.Count+$newPaths }
}
$outcome = if ($gap) { 'CheckpointGap' } elseif (!$closed) { 'Partial' } elseif ($hasErrors) { 'ClosedWithCoverageErrors' } else { 'Closed' }
$matched = @($paths.Values | Where-Object { $_ -eq 'Matched' }).Count
$negative = @($paths.Values | Where-Object { $_ -eq 'NoMatch' }).Count
$result = [pscustomobject]@{
    Test='UploadedGenerationInventory'; Outcome=$outcome; Generation=$generation; ProfileVersion=$anchor.profileVersion
    RegistrationId=$anchor.registrationId; UploadedCycles=$cycles.Count; ClosingRunId=$closingRun
    FileObservations=$observations; DistinctObservedPaths=$paths.Count; RepeatedObservations=$observations-$paths.Count
    PurviewMatched=$matched; PurviewNoMatch=$negative; PurviewUnknownOrNotInspected=$paths.Count-$matched-$negative
    CoverageErrors=$coverageErrors
}
if ($InterruptedRunId) { $result | Add-Member NoteProperty InterruptedEvidence $comparison }
if ($PSCmdlet.ParameterSetName -eq 'SharePoint') {
    $result | Add-Member NoteProperty LandingReadback ([pscustomobject]@{
        ListId=$LandingListId; VerifiedBatches=$verifiedRemote; VerifiedFiles=3*$verifiedRemote
        Scope='LocallyRetainedComparedBatches'; Outcome='HashesVerified'
    })
}
Write-Host '=== GENERATION INVENTORY FOR SHARING ===' -ForegroundColor Magenta
if ($PublishGeneration) {
    $recovered = if ($InterruptedRunId) { $comparison.AdditionalObservedPaths } else { 0 }
    $projection = [ordered]@{
        registration=$anchor.registrationId; profile=$anchor.profileId; version=$anchor.profileVersion
        profileSha256=$anchor.profileSha256; generation=$generation; landingListId=$LandingListId.ToString()
        coverage=$outcome; missingDirectories=$missingDirectories; coverageErrors=$coverageErrors
        closingRun=$closingRun; latestRun=$previous.Summary.runId; observed=$paths.Count; recovered=$recovered
        combined=$paths.Count+$recovered; matched=$matched; negative=$negative; unknown=$paths.Count-$matched-$negative
        interruptedRun=$InterruptedRunId; association=$(if ($InterruptedRunId) { $comparison.Association })
        manifests=$sourceManifests
    }
    $result | Add-Member NoteProperty GenerationPublication (Save-GenerationProjection $projection)
}
Write-Host ($result | ConvertTo-Json -Depth 4) -ForegroundColor Magenta
$result
