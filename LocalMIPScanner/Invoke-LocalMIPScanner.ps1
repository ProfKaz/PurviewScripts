#Requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]] $Root,

    [string] $ConfigDirectory = (Join-Path $PSScriptRoot 'Config'),

    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'LocalMIPScanner\Logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LocalMIPScanner.psm1') -Force -ErrorAction Stop
Invoke-LocalMIPInventory -Root $Root -ConfigDirectory $ConfigDirectory -LogDirectory $LogDirectory
