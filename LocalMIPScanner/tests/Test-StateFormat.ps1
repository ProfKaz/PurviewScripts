#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
