<#PSScriptInfo
.VERSION 1.1.0
.GUID ad7c5a2e-6eb7-4fbd-9195-b0368dd692a5
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.PROJECTURI https://github.com/ProfKaz/PurviewScripts
.RELEASENOTES
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: ad7c5a2e-6eb7-4fbd-9195-b0368dd692a5
#>
<#
HISTORY
Script      : LocalMIPScanner.WinPS51/Invoke-LocalMIPScanner.ps1
Version     : 1.1.0
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

    [ValidateRange(0, 2147483647)] [int] $MaxDirectories = 0,
    [ValidateRange(0, 2147483647)] [int] $MaxSeconds = 0,
    [switch] $AuditContent,
    [switch] $Continuous,
    [ValidateRange(1, 86400)] [int] $IdleSeconds = 60
)

if (-not $ConfigDirectory) { $ConfigDirectory = Join-Path $PSScriptRoot 'Config' }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LocalMIPScanner.psm1') -Force -ErrorAction Stop
do {
    Invoke-LocalMIPInventory -Root $Root -ConfigDirectory $ConfigDirectory -LogDirectory $LogDirectory `
        -MaxDirectories $MaxDirectories -MaxSeconds $MaxSeconds -AuditContent:$AuditContent
    if ($Continuous) { Start-Sleep -Seconds $IdleSeconds }
} while ($Continuous)
