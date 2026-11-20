<#PSScriptInfo
.VERSION 1.0.0
.GUID c20e72b1-3c53-4506-a630-69f828670344
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 1.0.0 Validate a central profile against the actual PS5.1 scanner.
#>
<#
.DESCRIPTION
Validates a supplied JSON profile without scanning or changing documents.
.NOTES
Version     : 1.0.0
Tracking ID : c20e72b1-3c53-4506-a630-69f828670344
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
param([Parameter(Mandatory)][string]$ProfilePath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/ScannerPortal.Endpoint.psm1') -Force
$profile=Read-PortalJson $ProfilePath
$null=Test-PortalProfile $profile
'PASS: central profile validated by PS5.1 scanner'
