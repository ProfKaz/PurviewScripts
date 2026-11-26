<#PSScriptInfo
.VERSION 0.1.0
.GUID f2c7c7bb-5801-43c9-a3a2-a49aa39a9e77
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.0 Compare two accepted single-cycle Purview inventories of the same scope.
#>
#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]$Connection,
    [Parameter(Mandatory)][guid]$AcceptanceListId,
    [Parameter(Mandatory)][guid]$LandingListId,
    [Parameter(Mandatory)][int]$EarlierAcceptance,
    [Parameter(Mandatory)][int]$LaterAcceptance
)
$ErrorActionPreference = 'Stop'

function Read-VerifiedText($Url, $Digest, $Length) {
    $stream = Get-PnPFile -Url $Url -AsMemoryStream -Connection $Connection
    try {
        $bytes = $stream.ToArray()
        if (($null -ne $Length -and $bytes.LongLength -ne $Length) -or
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -ine $Digest) {
            throw 'The accepted payload failed integrity verification.'
        }
        return [Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xfeff)
    } finally { $stream.Dispose() }
}

function Read-Snapshot([int]$Id) {
    $row = (Get-PnPListItem -List $AcceptanceListId -Id $Id -Connection $Connection).FieldValues
    $device = ([guid]$row.ReportingDeviceId).ToString()
    $run = $row.BatchId
    $folder = "devices/$device/batches/$run"
    if ($run -cnotmatch '^[a-f0-9]{32}$' -or $row.SourceRelativePath -cne $folder -or
        [guid]$row.SourceListId -ne $LandingListId) { throw "Unexpected managed source for acceptance $Id." }
    $base = "$libraryRoot/$folder"
    $manifest = Read-VerifiedText "$base/manifest.json" $row.ManifestSha256 $null | ConvertFrom-Json -AsHashtable
    if ($manifest.contract -cne 'ScannerPortal.InventoryRun/1' -or $manifest.schemaVersion -ne 1 -or
        $manifest.batchId -cne $run -or $manifest.registrationId -ne $device -or $manifest.files.Count -ne 2) {
        throw "Invalid managed manifest for acceptance $Id."
    }
    $payload = @{}
    foreach ($name in 'summary.json','records.jsonl') {
        $entry = @($manifest.files | Where-Object name -CEQ $name)
        if ($entry.Count -ne 1) { throw "Missing payload entry for $name." }
        $payload[$name] = Read-VerifiedText "$base/$name" $entry[0].sha256 $entry[0].length
    }
    $wrapper = $payload['summary.json'] | ConvertFrom-Json -AsHashtable
    $summary = $wrapper.summary
    if ($wrapper.tenantId -ne $manifest.tenantId -or !$wrapper.tenantId -or $wrapper.registrationId -ne $device -or
        $wrapper.profileSha256 -notmatch '^[a-f0-9]{64}$' -or !$wrapper.executionAccountSid -or
        $summary.runId -cne $run -or $summary.interrupted -or $summary.generationComplete -ne $true -or
        $summary.generationHasErrors -ne $false -or $summary.resumedDirectories -ne 0 -or $summary.errors -ne 0) {
        throw "Acceptance $Id requires a complete single-cycle inventory with known scope and zero coverage errors."
    }
    $paths = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $matched = 0
    $unknown = 0
    $terminal = $null
    foreach ($line in $payload['records.jsonl'].Split([char]10,[StringSplitOptions]::RemoveEmptyEntries)) {
        $record = ConvertFrom-Json -InputObject $line -AsHashtable
        if ($terminal) { throw 'Unexpected data after the closing record.' }
        if ($record.event -eq 'summary') { $terminal = $record; continue }
        if ($record.event -eq 'error') { throw 'Inventory contains a coverage error.' }
        if ($record.event -ne 'file') { continue }
        if (!$record.path -or !$paths.TryAdd($record.path,[string]$record.purview.discovery)) {
            throw 'Missing or duplicate file path in a single inventory.'
        }
        switch ($record.purview.discovery) {
            'Matched' { $matched++ }
            'NoMatch' { }
            default { $unknown++ }
        }
    }
    if ($terminal.runId -cne $run -or $paths.Count -ne $summary.inventoried -or $paths.Count -eq 0) {
        throw "Incomplete or empty control inventory for acceptance $Id."
    }
    [pscustomobject]@{ Device=$device; Tenant=$wrapper.tenantId; Sid=$wrapper.executionAccountSid
        Profile=$wrapper.profileSha256; Run=$run; Started=[datetimeoffset]$summary.startedUtc
        Paths=$paths; Matched=$matched; Unknown=$unknown }
}

$libraryRoot = (Get-PnPList -Identity $LandingListId -Includes RootFolder -Connection $Connection).RootFolder.ServerRelativeUrl
$first = Read-Snapshot $EarlierAcceptance
$last = Read-Snapshot $LaterAcceptance
if ($first.Device -ne $last.Device -or $first.Tenant -ne $last.Tenant -or $first.Sid -ne $last.Sid -or
    $first.Profile -ne $last.Profile -or $first.Run -eq $last.Run -or $first.Started -ge $last.Started) {
    throw 'Select distinct runs in chronological order with the same registration, account and profile.'
}
$overlap = 0
$changed = 0
foreach ($path in $last.Paths.Keys) {
    if ($first.Paths.ContainsKey($path)) {
        $overlap++
        if ($first.Paths[$path] -cne $last.Paths[$path]) { $changed++ }
    }
}
$stable = $overlap -eq $first.Paths.Count -and $overlap -eq $last.Paths.Count -and $changed -eq 0 -and
    $first.Unknown -eq 0 -and $last.Unknown -eq 0
$result = [ordered]@{
    Test='CurrentInventory-RepeatedScan'; Outcome=$(if ($stable) {'Verified'} else {'Review'})
    Acceptances=@($EarlierAcceptance,$LaterAcceptance); HistoricalFileObservations=$first.Paths.Count+$last.Paths.Count
    CurrentFiles=$last.Paths.Count; ReobservedPaths=$overlap; AddedPaths=$last.Paths.Count-$overlap
    MissingFromLatest=$first.Paths.Count-$overlap; ChangedDiscoveryStates=$changed
    CurrentFilesWithPurviewMatches=$last.Matched; CurrentDiscoveryUnknown=$last.Unknown
}
Write-Host '=== CURRENT INVENTORY FOR SHARING ===' -ForegroundColor Magenta
Write-Host ($result | ConvertTo-Json) -ForegroundColor Magenta
[pscustomobject]$result
