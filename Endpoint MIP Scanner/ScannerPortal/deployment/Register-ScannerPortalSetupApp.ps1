<#PSScriptInfo
.VERSION 1.1.0
.GUID f7793dec-25e3-4a4a-a11a-d7175bb16640
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.PROJECTURI https://github.com/ProfKaz/PurviewScripts
.RELEASENOTES
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: f7793dec-25e3-4a4a-a11a-d7175bb16640
#>
<#
HISTORY
Script      : ScannerPortal/deployment/Register-ScannerPortalSetupApp.ps1
Version     : 1.1.0
Tracking ID : f7793dec-25e3-4a4a-a11a-d7175bb16640
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
#Requires -Version 7.4
<#
.SYNOPSIS
Plans or registers the tenant-owned interactive setup application for Scanner Portal.
.DESCRIPTION
Plan is offline. Apply opens a Microsoft login for app registration and consent.
No client secret or certificate is created. Run once per tenant, then reuse ClientId.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^([a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[a-fA-F0-9-]{36})$')]
    [string]$Tenant,
    [ValidateNotNullOrEmpty()][string]$ApplicationName = 'Kaz Demos Scanner Portal - Setup',
    [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
    [switch]$DeviceLogin
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$plan = [pscustomobject]@{
    Tenant = $Tenant
    ApplicationName = $ApplicationName
    Purpose = 'Interactive administrative setup; not the scanner runtime identity'
    SharePointDelegatedPermissions = @('AllSites.FullControl')
    GraphDelegatedPermissions = @('User.Read')
    ApplicationPermissions = @()
    CreatesSecret = $false
    RepeatPolicy = 'Register once, record public ClientId and reuse it; Apply is not an upsert'
}
if ($Mode -eq 'Plan' -or $WhatIfPreference) { $plan; return }
Import-Module PnP.PowerShell -MinimumVersion 3.2.0 -ErrorAction Stop
if (-not $PSCmdlet.ShouldProcess($Tenant, "Register interactive application '$ApplicationName' and request delegated consent")) {
    return
}
# Explicit lists avoid the registration cmdlet's broad default Graph permissions.
$registration = @{
    ApplicationName = $ApplicationName
    Tenant = $Tenant
    SignInAudience = 'AzureADMyOrg'
    GraphDelegatePermissions = @('User.Read')
    SharePointDelegatePermissions = @('AllSites.FullControl')
    GraphApplicationPermissions = @()
    SharePointApplicationPermissions = @()
    O365ManagementApplicationPermissions = @()
    O365ManagementDelegatePermissions = @()
    ErrorAction = 'Stop'
}
if ($DeviceLogin) { $registration.DeviceLogin = $true }
# PnP handles authentication and consent. Its output contains the public app ID, never a generated secret.
Register-PnPEntraIDAppForInteractiveLogin @registration
