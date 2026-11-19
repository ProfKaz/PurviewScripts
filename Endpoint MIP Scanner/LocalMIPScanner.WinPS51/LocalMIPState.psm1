<#PSScriptInfo
.VERSION 1.1.0
.GUID 548fa14a-abb5-4547-80c0-cf5cd9c02d3c
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.PROJECTURI https://github.com/ProfKaz/PurviewScripts
.RELEASENOTES
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: 548fa14a-abb5-4547-80c0-cf5cd9c02d3c
#>
<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/LocalMIPState.psm1.
.NOTES
HISTORY
Script      : LocalMIPScanner.WinPS51/LocalMIPState.psm1
Version     : 1.1.0
Tracking ID : 548fa14a-abb5-4547-80c0-cf5cd9c02d3c
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
. (Join-Path $PSScriptRoot 'WinPSCompatibility.ps1')
Set-StrictMode -Version Latest

function ConvertTo-LocalPath {
    param([string] $Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -notmatch '^[A-Za-z]:[\\/]' -or $expanded.Substring(2).Contains(':')) {
        throw "Expected an absolute Windows drive path: $Path"
    }
    return (Get-WinPSFullPath $expanded)
}

function Get-IncrementalSettings {
    param([string] $ConfigDirectory)
    $file = Join-Path $ConfigDirectory 'incremental.json'
    if (-not [IO.File]::Exists($file)) {
        return @{ Enabled = $false }
    }
    $raw = Get-Content -LiteralPath $file -Raw | ConvertFrom-WinPSJson
    if ($raw -isnot [Collections.IDictionary]) { throw 'incremental.json must contain an object.' }
    foreach ($name in @('enabled','detectModifiedFiles','detectDeletedFiles','forceFullScan')) {
        if ($raw[$name] -isnot [bool]) { throw "incremental.json: $name must be boolean." }
    }
    foreach ($name in @('rescanIntervalDays','maxFileSizeMB')) {
        if ($raw[$name] -isnot [long] -or $raw[$name] -lt 1 -or $raw[$name] -gt 36500) {
            throw "incremental.json: $name must be an integer between 1 and 36500."
        }
    }
    if ($raw['stateDirectory'] -isnot [string] -or [string]::IsNullOrWhiteSpace($raw['stateDirectory'])) {
        throw 'incremental.json: stateDirectory must be an absolute Windows path.'
    }
    return @{
        Enabled = $raw['enabled']
        DetectModified = $raw['detectModifiedFiles']
        DetectDeleted = $raw['detectDeletedFiles']
        Force = $raw['forceFullScan']
        Days = $raw['rescanIntervalDays']
        MaxBytes = $raw['maxFileSizeMB'] * 1MB
        StateDirectory = ConvertTo-LocalPath $raw['stateDirectory']
    }
}

function Get-FileInventoryDecision {
    param(
        [hashtable] $Settings,
        [Collections.Generic.Dictionary[string,object]] $Entries,
        [string] $Path,
        [long] $SizeBytes,
        [string] $LastWriteUtc,
        [datetime] $Now
    )
    $old = $null
    if (-not $Entries.TryGetValue($Path, [ref] $old)) { return 'new' }
    if ($Settings.Force) { return 'due' }
    if ($Settings.DetectModified -and
        ($old['sizeBytes'] -ne $SizeBytes -or $old['lastWriteUtc'] -ne $LastWriteUtc)) {
        return 'modified'
    }
    # Never use discovery time as evidence of a completed content scan.
    if ($old['lastContentScannedUtc'] -is [string] -and $old['lastContentScannedUtc']) {
        $lastScan = [datetime]::Parse($old['lastContentScannedUtc'],
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        if ($Now.ToUniversalTime() -ge $lastScan.ToUniversalTime().AddDays($Settings.Days)) {
            return 'due'
        }
        return 'unchanged'
    }
    # M2 has no content classifier yet. Existing unclassified files remain pending,
    # but can be skipped for metadata refresh using the unchanged status.
    return 'unchanged'
}

Export-ModuleMember -Function Get-IncrementalSettings, Get-FileInventoryDecision
