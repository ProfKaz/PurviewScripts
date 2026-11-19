<#PSScriptInfo

.VERSION 1.1.0

.GUID 4b27dccf-a12d-41cf-aa57-e1eb65fddc7c

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: 4b27dccf-a12d-41cf-aa57-e1eb65fddc7c
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/tests/Test-StateFormat.ps1.
.NOTES
HISTORY
Script      : LocalMIPScanner.WinPS51/tests/Test-StateFormat.ps1
Version     : 1.1.0
Tracking ID : 4b27dccf-a12d-41cf-aa57-e1eb65fddc7c
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../WinPSCompatibility.ps1')
. (Join-Path $PSScriptRoot '../LocalMIPCheckpoint.ps1')

$entry = @{
    schemaVersion = 1; path = 'C:\root\sample.txt'; sizeBytes = 0
    lastWriteUtc = '2026-11-09T09:00:00.1234567Z'; lastDiscoveredUtc = '2026-11-09T09:00:00.1234567Z'
    lastContentScannedUtc = $null; status = 'PendingClassification'
}
foreach ($size in [int]0, [long]2147483648, [long]::MaxValue) {
    $entry.sizeBytes = $size
    $parsed = Read-StateJson (Get-StateJson $entry)
    Assert-StateEntry $parsed
    if ($parsed.sizeBytes -isnot [long] -or $parsed.sizeBytes -ne $size -or
        $parsed.lastWriteUtc -cne $entry.lastWriteUtc -or $parsed.lastWriteUtc -isnot [string]) {
        throw "Incorrect metadata round trip for length $size."
    }
}
foreach ($size in -1, 1.5, '1') {
    $entry.sizeBytes = $size
    $rejected = $false
    try { Assert-StateEntry (Read-StateJson (Get-StateJson $entry)) } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid length accepted: $size." }
}
'PASS: state record timestamp and Int64 round trips, invalid lengths rejected'
