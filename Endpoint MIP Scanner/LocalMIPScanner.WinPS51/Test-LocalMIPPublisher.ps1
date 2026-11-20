<#PSScriptInfo

.VERSION 1.0.0

.GUID dedef6b8-8c82-4fe4-954b-10d9b5cb4601

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-20  1.0.0  Device-folder publisher registration and app-only permission preflight.
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: LocalMIPScanner.WinPS51/Test-LocalMIPPublisher.ps1.
.NOTES
HISTORY
Version     : 1.0.0
Tracking ID : dedef6b8-8c82-4fe4-954b-10d9b5cb4601
2026-11-20  Kaz Demos  Initial publisher preparation and permission verification.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param([string] $ConfigurationPath)
$ErrorActionPreference = 'Stop'
if (-not $ConfigurationPath) { $ConfigurationPath = Join-Path $env:ProgramData 'EndpointMIPScanner/Publisher/publisher.json' }
Import-Module (Join-Path $PSScriptRoot 'LocalMIPSharePoint.psm1') -Force
$configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
$result = Test-LocalMIPPublisher $configuration
Write-Host '=== PUBLICADOR SHAREPOINT PARA COMPARTIR ===' -ForegroundColor Magenta
Write-Host ($result | ConvertTo-Json -Depth 6) -ForegroundColor Magenta
$result
