<#PSScriptInfo

.VERSION 1.0.0

.GUID 9e915811-26d1-4f05-9db3-6d8b805fe447

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-20  1.0.0  Consolidate local discovery and retry evidence into verified pending batches.
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/tests/Test-ReportBatch.ps1.
.NOTES
HISTORY
Version     : 1.0.0
Tracking ID : 9e915811-26d1-4f05-9db3-6d8b805fe447
2026-11-20  Kaz Demos  Initial local batch implementation and verification.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../LocalMIPReporting.psm1') -Force
$fixture = Join-Path $env:TEMP ('LocalMIPReport-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message expected [$Expected], got [$Actual]." }
}
function Assert-Fails([scriptblock] $Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Expected rejection.' }
}
function Write-Fixture([string] $Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), $utf8)
}

try {
    $discoveryPath = Join-Path $fixture 'discovery.jsonl'
    $retryPath = Join-Path $fixture 'retry.json'
    $inventoryPath = Join-Path $fixture 'inventory.jsonl'
    $correctPath = 'C:\Données\résumé.csv'
    $damagedPath = [Text.Encoding]::GetEncoding(1252).GetString($utf8.GetBytes($correctPath))
    $paths = @($correctPath, 'C:\root\none.csv', 'C:\Users\User\AppData\Local\sample.txt', 'C:\root\positive.docx')
    $records = @(for ($i = 0; $i -lt 4; $i++) {
        $path = $paths[$i]
        if ($i -eq 0) { $path = $damagedPath }
        $outcome = if ($i -lt 2) { 'Error' } elseif ($i -eq 2) { 'NoResponse' } else { 'Responded' }
        @{
            Path = $path; Extension = [IO.Path]::GetExtension($path); ClientVersion = '3.2.181.0'
            StartedUtc = '2026-11-20T10:00:00Z'; Result = $outcome
            NativeStatus = @('Skipped')
            ErrorId = $(if ($i -lt 2) { 'PathNotFound,Microsoft.PowerShell.Commands.GetItemCommand' } else { $null })
            Findings = @($(if ($i -eq 3) {
                @{ SitId = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'; Name = 'Credit Card Number'
                    Count = 5; Confidence = 85; SensitiveContents = 'SECRET-FIXTURE' }
            }))
        }
    })
    $lines = @($records | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress })
    [IO.File]::WriteAllLines($discoveryPath, [string[]]$lines, $utf8)
    $retry = @{
        ReintentosCSV = @(
            @{ Ruta = $correctPath; Registros = 1; Estados = @('Skipped'); ErrorId = $null
                TiposDetectados = @(@{ RuleId = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
                    Name = 'Credit Card Number'; Count = 3; Confidence = 85; Value = 'SECRET-FIXTURE' }) },
            @{ Ruta = $paths[1]; Registros = 1; Estados = @('Skipped'); ErrorId = $null; TiposDetectados = @() }
        )
    }
    Write-Fixture $retryPath $retry
    $inventory = @($paths | ForEach-Object { @{ event = 'file'; path = $_ } })
    $inventory += @{ event = 'error'; operation = 'openDirectory'; path = 'C:\denied' }
    $inventory += @{ event = 'summary'; generationComplete = $true; errors = 1 }
    [IO.File]::WriteAllLines($inventoryPath, [string[]]@($inventory | ForEach-Object { $_ | ConvertTo-Json -Compress }), $utf8)
    $parameters = @{
        DiscoveryReport = $discoveryPath; RetryReport = $retryPath; InventoryLog = $inventoryPath
        TenantId = 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4'; OutboxDirectory = Join-Path $fixture 'Outbox'
    }
    $before = (Get-FileHash -LiteralPath $discoveryPath).Hash
    $first = New-LocalMIPReportBatch @parameters
    Assert-Equal $true $first.Verified 'Verification'
    Assert-Equal 4 $first.Summary.candidateFiles 'Candidates'
    Assert-Equal 3 $first.Summary.respondedFiles 'Responded'
    Assert-Equal 1 $first.Summary.noResponseFiles 'Unresolved location'
    Assert-Equal 0 $first.Summary.errorFiles 'Retry resolves errors'
    Assert-Equal 2 $first.Summary.filesWithFindings 'Skipped retains findings'
    Assert-Equal 2 $first.Summary.appliedRetryCount 'Retry provenance'
    Assert-Equal 1 $first.Summary.coverageErrors 'Directory coverage errors'
    Assert-Equal 8 $first.Summary.findingsByType[0]['matches'] 'SIT matches'
    $payload = Join-Path $first.BatchDirectory 'records.jsonl'
    if ([IO.File]::ReadAllText($payload).Contains('SECRET-FIXTURE')) { throw 'Sensitive fixture leaked.' }
    $second = New-LocalMIPReportBatch @parameters
    Assert-Equal $first.BatchId $second.BatchId 'Idempotent ID'
    Assert-Equal $first.ManifestSha256 $second.ManifestSha256 'Existing manifest preserved'
    Assert-Equal $before (Get-FileHash -LiteralPath $discoveryPath).Hash 'Source preserved'
    $entry = Join-Path $PSScriptRoot '../New-LocalMIPReportBatch.ps1'
    $verifiedFromEntry = & $entry -VerifyBatch $first.BatchDirectory
    Assert-Equal $true $verifiedFromEntry.Verified 'Public verification entry point'
    $lock = [IO.File]::Open((Join-Path $parameters.OutboxDirectory 'writer.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { Assert-Fails { New-LocalMIPReportBatch @parameters } }
    finally { $lock.Dispose() }

    $retry.ReintentosCSV += $retry.ReintentosCSV[0]
    Write-Fixture $retryPath $retry
    Assert-Fails { New-LocalMIPReportBatch @parameters }
    $retry.ReintentosCSV = @($retry.ReintentosCSV | Select-Object -First 2)
    Write-Fixture $retryPath $retry
    $originalBytes = [IO.File]::ReadAllBytes($discoveryPath)
    [IO.File]::WriteAllBytes($discoveryPath, [byte[]]@(0xC3, 0x28))
    Assert-Fails { New-LocalMIPReportBatch @parameters }
    [IO.File]::WriteAllBytes($discoveryPath, $originalBytes)
    [IO.File]::AppendAllText($discoveryPath, $lines[0] + [Environment]::NewLine, $utf8)
    Assert-Fails { New-LocalMIPReportBatch @parameters }
    [IO.File]::WriteAllBytes($discoveryPath, $originalBytes)
    [IO.File]::AppendAllText($payload, 'corruption', $utf8)
    Assert-Fails { Test-LocalMIPReportBatch $first.BatchDirectory }
    Assert-Fails { New-LocalMIPReportBatch @parameters }
    'PASS: UTF8 path reconciliation, retry precedence, coverage, metadata-only findings, hashes, idempotency and corruption rejection'
} finally {
    # Resolve and verify the generated fixture before recursive cleanup.
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'LocalMIPReport-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
