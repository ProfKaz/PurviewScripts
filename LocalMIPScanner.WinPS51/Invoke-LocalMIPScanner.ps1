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
