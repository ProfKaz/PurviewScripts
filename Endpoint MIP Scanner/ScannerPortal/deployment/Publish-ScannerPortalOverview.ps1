<#PSScriptInfo
.VERSION 0.1.0
.GUID fbd56309-9178-4238-b5df-1fbba2b853c4
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.0 Publish the executive reporting snapshot from accepted batch summaries.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$PortalClientId,
    [string[]]$ExcludeBatchId = @()
)
$ErrorActionPreference = 'Stop'
Import-Module PnP.PowerShell -RequiredVersion 3.2.0
$conn = Connect-PnPOnline -Url $SiteUrl.AbsoluteUri -Tenant $TenantId -ClientId $PortalClientId -Interactive -ReturnConnection
try {
    $name = 'ScannerPortalExecutive'
    $groups = @{}
    $seen = @{}
    $excluded = 0
    $pending = 0
    $source = Get-PnPList -Identity 'ScannerPortalAcceptance' -Connection $conn
    Get-PnPListItem -List $source.Id -PageSize 200 -Fields Title,BatchId,ManifestSha256,ReportingDeviceId,PortalReportJson,AcceptanceJson -Connection $conn | ForEach-Object {
        $row = $_.FieldValues
        if ($row.BatchId -in $ExcludeBatchId) { $excluded++ }
        elseif (!$row.PortalReportJson) { $pending++ }
        else {
            $report = $row.PortalReportJson | ConvertFrom-Json
            $acceptance = $row.AcceptanceJson | ConvertFrom-Json
            if ($report.SchemaVersion -ne 1 -or $acceptance.state -ne 'AcceptedValidatedBatch' -or
                $report.BatchId -ne $row.BatchId -or $report.AcceptanceKey -ne $row.Title -or
                $report.ManifestSha256 -ne $row.ManifestSha256 -or $acceptance.manifestSha256 -ne $report.ManifestSha256 -or
                $report.ReportingDeviceId -ne $row.ReportingDeviceId -or !$report.ReportingDeviceId) { throw "Invalid acceptance item $($_.Id)." }
            $identity = "$($row.ReportingDeviceId)/$($row.BatchId)"
            if ($seen.ContainsKey($identity)) { throw "Duplicate device and batch at acceptance $($_.Id)." }
            $seen[$identity] = $true
            $key = "$($row.ReportingDeviceId)/$($report.AccountObjectId)"
            if (!$groups.ContainsKey($key)) {
                $groups[$key] = [ordered]@{device=$row.ReportingDeviceId; account=$report.AccountObjectId; observations=0L
                    findings=0L; coverageErrors=0L; runs=0; extensions=@{}; detections=@{}}
            }
            $group = $groups[$key]
            $group.runs++
            $group.coverageErrors += $report.CoverageErrors
            foreach ($entry in $report.ByExtension) {
                $group.extensions[$entry.Extension] += [long]$entry.Files
                $group.observations += $entry.Files
            }
            if ($null -ne $report.ManagedInventory) {
                $group.findings += $report.ManagedInventory.FilesWithMatches
                foreach ($entry in $report.ManagedInventory.ByLocalRule) {
                    $group.detections["Local rule / $($entry.RuleId)"] += [long]$entry.Matches
                }
            } else {
                if ($null -eq $acceptance.summary.filesWithFindings) { throw "Missing findings count at item $($_.Id)." }
                $group.findings += $acceptance.summary.filesWithFindings
                foreach ($entry in $report.BySit) {
                    $group.detections["Purview SIT / $($entry.Name) ($($entry.SitId))"] += [long]$entry.Matches
                }
            }
        }
    }
    $snapshot = [ordered]@{schema=1; generatedUtc=[datetime]::UtcNow.ToString('o'); excluded=$excluded
        pending=$pending; groups=@($groups.Values | Sort-Object { $_.device }, { $_.account })}
    $library = Get-PnPList -Connection $conn | Where-Object Title -eq $name
    if (!$library) {
        $null = New-PnPList -Title $name -Url $name -Template DocumentLibrary -Connection $conn
        $null = Set-PnPList -Identity $name -BreakRoleInheritance -CopyRoleAssignments:$false -Connection $conn
    }
    $library = Get-PnPList -Identity $name -Includes HasUniqueRoleAssignments,BaseTemplate,RootFolder -Connection $conn
    if (!$library.HasUniqueRoleAssignments -or $library.BaseTemplate -ne 101) { throw 'Review the executive library permissions before publishing.' }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($snapshot | ConvertTo-Json -Depth 8 -Compress))
    $stream = [IO.MemoryStream]::new($bytes)
    try { $null = Add-PnPFile -FileName 'overview.json' -Folder $library.RootFolder.ServerRelativeUrl -Stream $stream -Connection $conn }
    finally { $stream.Dispose() }
    [pscustomobject]@{ Outcome='Published'; IncludedRuns=$seen.Count; ExcludedRuns=$excluded; AwaitingReport=$pending; GeneratedUtc=$snapshot.generatedUtc }
} finally { Disconnect-PnPOnline -ErrorAction SilentlyContinue }
