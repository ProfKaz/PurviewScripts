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
    [switch] $Continuous,
    [ValidateRange(1, 86400)] [int] $IdleSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LocalMIPScanner.psm1') -Force -ErrorAction Stop
do {
    Invoke-LocalMIPInventory -Root $Root -ConfigDirectory $ConfigDirectory -LogDirectory $LogDirectory `
        -MaxDirectories $MaxDirectories -MaxSeconds $MaxSeconds
    if ($Continuous) { Start-Sleep -Seconds $IdleSeconds }
} while ($Continuous)
