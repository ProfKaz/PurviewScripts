#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../deployment/New-ScannerPortalPilot.ps1'
$arguments = @{
    AdminUrl = 'https://example-admin.sharepoint.com'
    SiteUrl = 'https://example.sharepoint.com/sites/ScannerPortalPilot'
    Owner = 'owner@example.invalid'
}
$plan = & $scriptPath @arguments
if ($plan.Stage -ne 'SiteOnly' -or $plan.DeploysSPFx -or $plan.ExternalSharing -ne 'Disabled') {
    throw 'Offline plan does not match pilot scope.'
}
# Apply + WhatIf must not import PnP or authenticate, even without ClientId/Tenant.
$whatIfPlan = & $scriptPath @arguments -Mode Apply -WhatIf
if ($whatIfPlan.SiteUrl -ne $plan.SiteUrl) { throw 'WhatIf plan differs from default plan.' }

$cases = @(
    @{ AdminUrl = 'http://example-admin.sharepoint.com' },
    @{ AdminUrl = 'https://example-admin.sharepoint.com:444' },
    @{ AdminUrl = 'https://user@example-admin.sharepoint.com' },
    @{ AdminUrl = 'https://example-admin.sharepoint.com?query=1' },
    @{ SiteUrl = 'https://other.sharepoint.com/sites/ScannerPortalPilot' },
    @{ SiteUrl = 'https://example.sharepoint.com/' },
    @{ SiteUrl = 'https://example.sharepoint.com/sites/Pilot?query=1' },
    @{ SiteUrl = 'https://example.sharepoint.com/sites/Pilot/nested' },
    @{ SiteUrl = 'https://example.sharepoint.com/sites/ab' },
    @{ Owner = 'invalid' }
)
foreach ($case in $cases) {
    $bad = $arguments.Clone()
    foreach ($key in $case.Keys) { $bad[$key] = $case[$key] }
    $failed = $false
    try { & $scriptPath @bad | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw "Unsafe pilot plan accepted: $($case | ConvertTo-Json -Compress)" }
}
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
$registerPath = Join-Path $PSScriptRoot '../deployment/Register-ScannerPortalSetupApp.ps1'
$appPlan = & $registerPath -Tenant 'example.onmicrosoft.com'
if ($appPlan.CreatesSecret -or $appPlan.ApplicationPermissions.Count -ne 0 -or
    ($appPlan.GraphDelegatedPermissions -join ',') -ne 'User.Read' -or
    ($appPlan.SharePointDelegatedPermissions -join ',') -ne 'AllSites.FullControl') {
    throw 'Application plan requested unexpected permissions or secret creation.'
}
$appWhatIf = & $registerPath -Tenant 'example.onmicrosoft.com' -Mode Apply -WhatIf
if ($appWhatIf.ApplicationName -ne $appPlan.ApplicationName) { throw 'Application WhatIf changed the plan.' }
$failed = $false
try { & $registerPath -Tenant 'https://example.onmicrosoft.com/' | Out-Null } catch { $failed = $true }
if (-not $failed) { throw 'Application registration accepted a URL instead of a tenant identifier.' }
$null = [Management.Automation.Language.Parser]::ParseFile($registerPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join '; ') }
'PASS: site and application offline plans, WhatIf without authentication, permissions, input validation, and PowerShell syntax.'
