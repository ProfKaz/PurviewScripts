<#PSScriptInfo
.VERSION 0.1.1
.GUID fceba35d-f548-410f-8dd1-41db6209d086
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.1 Use English for new report pages.
0.1.0 Render one verified report as a restricted SharePoint pilot page.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][guid]$PortalClientId,
    [Parameter(Mandatory)][guid]$AcceptanceListId,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$AcceptanceItemId,
    [Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$ExpectedReportSha256
)
$ErrorActionPreference = 'Stop'

function ConvertTo-WorkReportHtml($Report) {
    $total = ($Report.ByExtension | Measure-Object Files -Sum).Sum
    $responded = ($Report.ByOutcome | Where-Object Outcome -eq 'Responded' | Measure-Object Files -Sum).Sum
    $noResponse = ($Report.ByOutcome | Where-Object Outcome -eq 'NoResponse' | Measure-Object Files -Sum).Sum
    $parts = @(
        "<h2>Batch overview</h2><p><strong>$total files</strong> | $responded responded | $noResponse no response</p>"
        "<p>Coverage errors: $($Report.CoverageErrors). Detected types: $(@($Report.BySit).Count).</p>"
        '<h2>Files by outcome</h2><table><thead><tr><th>Outcome</th><th>Files</th></tr></thead><tbody>'
        foreach ($row in $Report.ByOutcome) {
            "<tr><td>$([Net.WebUtility]::HtmlEncode($row.Outcome))</td><td>$($row.Files)</td></tr>"
        }
        '</tbody></table><h2>Files by extension</h2><table><thead><tr><th>Extension</th><th>Files</th></tr></thead><tbody>'
        foreach ($row in $Report.ByExtension) {
            "<tr><td>$([Net.WebUtility]::HtmlEncode($row.Extension))</td><td>$($row.Files)</td></tr>"
        }
        '</tbody></table><h2>Sensitive information types</h2><p>A file can appear under multiple types.</p><table><thead><tr><th>Type</th><th>Files</th><th>Matches</th></tr></thead><tbody>'
        foreach ($row in ($Report.BySit | Sort-Object @{Expression='Files';Descending=$true}, SitId)) {
            $name = if ($row.Name) { $row.Name } else { $row.SitId }
            "<tr><td>$([Net.WebUtility]::HtmlEncode($name))</td><td>$($row.Files)</td><td>$($row.Matches)</td></tr>"
        }
        '</tbody></table>'
    )
    $parts -join ''
}

if ($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or
    $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort) { throw 'Invalid SharePoint site URL.' }

Import-Module PnP.PowerShell -RequiredVersion 3.2.0
$connection = Connect-PnPOnline -Url $SiteUrl.AbsoluteUri -Tenant $TenantId -ClientId $PortalClientId -Interactive -ReturnConnection
try {
    $item = Get-PnPListItem -List $AcceptanceListId -Id $AcceptanceItemId -Connection $connection
    $json = [string]$item['PortalReportJson']
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json)))
    if ($hash -cne $ExpectedReportSha256) { throw 'Stored report hash differs from verified W06E hash.' }
    $report = ConvertFrom-Json -InputObject $json
    if ($report.SchemaVersion -ne 1 -or $report.AcceptanceKey -cne $item['Title'] -or
        $report.ManifestSha256 -cne $item['ManifestSha256'] -or $report.BatchId -cne $item['BatchId']) {
        throw 'Stored report does not match its acceptance.'
    }
    $html = ConvertTo-WorkReportHtml $report
    $admins = @(Get-PnPSiteCollectionAdmin -Connection $connection | ForEach-Object LoginName)
    if (-not $admins.Count) { throw 'Unable to identify site administrators.' }

    # Add an empty draft first. A matching filename is never replaced.
    $pageName = "ScannerPortalReport-$AcceptanceItemId.aspx"
    $null = Add-PnPPage -Name $pageName -Title "Discovery report | Batch $AcceptanceItemId" -LayoutType Article -Connection $connection
    $pagePath = $SiteUrl.AbsolutePath.TrimEnd('/') + '/SitePages/' + $pageName
    $pageItem = Get-PnPFile -Url $pagePath -AsListItem -ThrowExceptionIfFileNotFound -Connection $connection
    $pageItem.BreakRoleInheritance($false, $false)
    Invoke-PnPQuery -Connection $connection

    if (-not (Get-PnPProperty -ClientObject $pageItem -Property HasUniqueRoleAssignments -Connection $connection)) {
        throw 'Draft page still inherits permissions. No report content added.'
    }
    $null = Get-PnPProperty -ClientObject $pageItem -Property RoleAssignments -Connection $connection
    foreach ($assignment in $pageItem.RoleAssignments) {
        $member = Get-PnPProperty -ClientObject $assignment -Property Member -Connection $connection
        $login = Get-PnPProperty -ClientObject $member -Property LoginName -Connection $connection
        if ($login -notin $admins) { throw 'Unexpected page role assignment. No report content added.' }
    }

    $null = Add-PnPPageTextPart -Page $pageName -Text $html -Connection $connection
    $null = Set-PnPPage -Identity $pageName -Publish -Connection $connection
    $result = [ordered]@{
        Test = 'W07A-AdministrativeReportPage'
        Outcome = 'Published'
        PageUrl = $SiteUrl.GetLeftPart([UriPartial]::Authority) + $pagePath
        AcceptanceItemId = $AcceptanceItemId
        ReportSha256 = $hash
        Files = ($report.ByExtension | Measure-Object Files -Sum).Sum
        SitTypes = @($report.BySit).Count
        CoverageErrors = $report.CoverageErrors
        PageHasUniquePermissions = $true
    }
    Write-Host '=== WORK W07A PARA COMPARTIR ===' -ForegroundColor Magenta
    Write-Host ($result | ConvertTo-Json) -ForegroundColor Magenta
} finally {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}
