<#PSScriptInfo
.VERSION 1.1.0
.GUID 7ec6aab1-a5f8-4628-9c16-712e1b4b243b
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.PROJECTURI https://github.com/ProfKaz/PurviewScripts
.RELEASENOTES
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: 7ec6aab1-a5f8-4628-9c16-712e1b4b243b
#>
<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS7[Pending]/Invoke-LocalMIPScanner.ps1.
.NOTES
HISTORY
Script      : LocalMIPScanner.WinPS7[Pending]/Invoke-LocalMIPScanner.ps1
Version     : 1.1.0
Tracking ID : 7ec6aab1-a5f8-4628-9c16-712e1b4b243b
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]] $Root,

    [string] $ConfigDirectory = (Join-Path $PSScriptRoot 'Config'),

    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'LocalMIPScanner\Logs'),

    [ValidateRange(0, 2147483647)] [int] $MaxDirectories = 0,
    [ValidateRange(0, 2147483647)] [int] $MaxSeconds = 0,
    [switch] $AuditContent,
    [switch] $Continuous,
    [ValidateRange(1, 86400)] [int] $IdleSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LocalMIPScanner.psm1') -Force -ErrorAction Stop
do {
    Invoke-LocalMIPInventory -Root $Root -ConfigDirectory $ConfigDirectory -LogDirectory $LogDirectory `
        -MaxDirectories $MaxDirectories -MaxSeconds $MaxSeconds -AuditContent:$AuditContent
    if ($Continuous) { Start-Sleep -Seconds $IdleSeconds }
} while ($Continuous)
