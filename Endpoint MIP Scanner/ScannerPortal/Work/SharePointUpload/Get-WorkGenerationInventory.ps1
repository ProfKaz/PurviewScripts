<#PSScriptInfo
.VERSION 0.2.0
.GUID 2fa67369-33e7-442c-8a61-bdf80f52860f
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.2.0 Compare explicitly identified interrupted evidence within a bounded checkpoint gap.
0.1.0 Reconcile locally retained uploaded cycles of one managed generation.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{12,32}$')][string]$RunPrefix,
    [ValidatePattern('^[0-9a-f]{32}$')][string]$InterruptedRunId,
    [string]$UploadedDirectory = (Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner\ManagedEndpoint\outbox\Uploaded')
)
$ErrorActionPreference = 'Stop'
function Read-JsonFile($Path) {
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
}
$dirs = @(Get-ChildItem -LiteralPath $UploadedDirectory -Directory | Where-Object Name -Match '^[a-f0-9]{32}$')
$seed = @($dirs | Where-Object Name -Like "$RunPrefix*")
if ($seed.Count -ne 1) { throw "Expected one retained uploaded batch matching $RunPrefix. Found $($seed.Count)." }
$anchor = Read-JsonFile (Join-Path $seed[0].FullName 'summary.json')
$generation = $anchor.summary.generation
if ($generation -notmatch '^[a-f0-9]{32}$' -or !$anchor.executionAccountSid -or !$anchor.registrationId -or
    $anchor.profileSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Incomplete anchor generation identity.' }
$interruptedCycle = $null
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
    foreach ($name in 'summary.json','records.jsonl') {
        $entry = @($manifest.files | Where-Object name -CEQ $name)
        $file = Get-Item -LiteralPath (Join-Path $dir.FullName $name)
        if ($entry.Count -ne 1 -or $file.Length -ne $entry[0].length -or
            (Get-FileHash -LiteralPath $file.FullName).Hash -ne $entry[0].sha256) { throw "Invalid $name payload." }
    }
    $cycleInfo = [pscustomobject]@{ Summary=$s; Directory=$dir.FullName; Offset=[long]$s.resumedDirectories; Started=[datetimeoffset]$s.startedUtc }
    if ($candidate) { $interruptedCycle = $cycleInfo } else { $cycleInfo }
})
$paths = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
$next = 0L
$gap = $false
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
Write-Host '=== GENERATION INVENTORY FOR SHARING ===' -ForegroundColor Magenta
Write-Host ($result | ConvertTo-Json -Depth 4) -ForegroundColor Magenta
$result
