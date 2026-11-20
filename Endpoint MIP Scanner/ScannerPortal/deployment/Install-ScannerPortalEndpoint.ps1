<#PSScriptInfo
.VERSION 1.0.0
.GUID ddfac335-a7c0-4110-aab4-540cc4eb826e
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 1.0.0 User-scope enrollment and optional least-privilege scheduled task.
#>
<#
.DESCRIPTION
Creates a public enrollment request. Repeat with RegisterTask after administrative approval.
.NOTES
Version     : 1.0.0
Tracking ID : ddfac335-a7c0-4110-aab4-540cc4eb826e
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BootstrapPath,
    [string]$Directory=(Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/ManagedEndpoint'),
    [switch]$RegisterTask)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/ScannerPortal.Endpoint.psm1') -Force
$Directory=Assert-PortalDirectory $Directory
$enrollment=New-PortalEnrollment -BootstrapPath $BootstrapPath -Directory $Directory
if ($RegisterTask) {
    $state=Read-PortalJson $enrollment.RegistrationPath
    $token=Get-PortalToken $state
    try { $null=Sync-PortalProfile -Registration $state -Directory $Directory -Token $token }
    finally { $token=$null }
    # InteractiveToken retains the user profile/certificate and WAM session. No password/SYSTEM/elevation.
    $exe=Join-Path $PSHOME 'powershell.exe'
    $runner=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Invoke-ScannerPortalEndpoint.ps1'))
    if ($runner.Contains('"') -or $Directory.Contains('"')) { throw 'Invalid task argument path.' }
    $arguments='-NoProfile -NonInteractive -WindowStyle Hidden -File "' + $runner + '" -Directory "' + $Directory + '" -Continuous'
    $action=New-ScheduledTaskAction -Execute $exe -Argument $arguments
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $sid
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    $name='EndpointMIPScanner-' + $enrollment.RegistrationId
    $null=Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Description 'Kaz Demos: authenticated profile pull and verified inventory reports.' -Force
    $enrollment | Add-Member TaskName $name
    $enrollment | Add-Member TaskStarted $false
}
Write-Host '=== ENDPOINT PORTAL PARA COMPARTIR ===' -ForegroundColor Magenta
Write-Host ($enrollment|ConvertTo-Json -Depth 5) -ForegroundColor Magenta
$enrollment
