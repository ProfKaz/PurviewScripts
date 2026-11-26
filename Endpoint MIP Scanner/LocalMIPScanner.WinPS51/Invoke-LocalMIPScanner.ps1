<#PSScriptInfo

.VERSION 1.2.0

.GUID ad7c5a2e-6eb7-4fbd-9195-b0368dd692a5

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
1.2.0 Managed discovery and reporting for explicitly selected Purview SITs.
2026-11-23 1.1.1 Managed checkpoint resumption across cycle log directories.
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: ad7c5a2e-6eb7-4fbd-9195-b0368dd692a5
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/Invoke-LocalMIPScanner.ps1.
.NOTES
HISTORY
Script      : LocalMIPScanner.WinPS51/Invoke-LocalMIPScanner.ps1
Version     : 1.2.0
Tracking ID : ad7c5a2e-6eb7-4fbd-9195-b0368dd692a5
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]] $Root,

    [string] $ConfigDirectory,

    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'LocalMIPScanner.WinPS51\Logs'),

    [string] $LogScopeDirectory,

    [ValidateRange(0, 2147483647)] [int] $MaxDirectories = 0,
    [ValidateRange(0, 2147483647)] [int] $MaxSeconds = 0,
    [guid[]] $PurviewSitIds = @(),
    [switch] $AuditContent,
    [switch] $Continuous,
    [ValidateRange(1, 86400)] [int] $IdleSeconds = 60
)

if (-not $ConfigDirectory) { $ConfigDirectory = Join-Path $PSScriptRoot 'Config' }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LocalMIPScanner.psm1') -Force -ErrorAction Stop
do {
    Invoke-LocalMIPInventory -Root $Root -ConfigDirectory $ConfigDirectory -LogDirectory $LogDirectory -LogScopeDirectory $LogScopeDirectory `
        -MaxDirectories $MaxDirectories -MaxSeconds $MaxSeconds -AuditContent:$AuditContent -PurviewSitIds $PurviewSitIds
    if ($Continuous) { Start-Sleep -Seconds $IdleSeconds }
} while ($Continuous)
