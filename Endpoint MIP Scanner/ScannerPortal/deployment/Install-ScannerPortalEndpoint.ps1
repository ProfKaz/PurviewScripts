<#PSScriptInfo
.VERSION 1.1.0
.GUID ddfac335-a7c0-4110-aab4-540cc4eb826e
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
1.1.0 Add a periodic activation opportunity while the user is signed in.
2026-11-23 1.0.1 Use the verified console-free host for Program Files deployments.
2026-11-20 1.0.0 User-scope enrollment and optional least-privilege scheduled task.
#>
<#
.DESCRIPTION
Creates a public enrollment request. Repeat with RegisterTask after administrative approval.
.NOTES
Version     : 1.1.0
Tracking ID : ddfac335-a7c0-4110-aab4-540cc4eb826e
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BootstrapPath,
    [string]$Directory=(Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/ManagedEndpoint'),
    [switch]$RegisterTask,
    [string]$TaskHostSha256)
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
    if ($PSBoundParameters.ContainsKey('TaskHostSha256')) {
        $exe=Join-Path $PSScriptRoot 'ScannerTaskHost.exe'
        if ($TaskHostSha256 -notmatch '^[a-f0-9]{64}$' -or
            (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $TaskHostSha256) {
            throw 'Task host verification failed. Rerun EndpointInstall.'
        }
        $trailingSlashes=$Directory.Length - $Directory.TrimEnd('\').Length
        $arguments='"' + $Directory + ('\' * $trailingSlashes) + '"'
    }
    $action=New-ScheduledTaskAction -Execute $exe -Argument $arguments
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    $logon=New-ScheduledTaskTrigger -AtLogOn -User $sid
    $recovery=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    $name='EndpointMIPScanner-' + $enrollment.RegistrationId
    $null=Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger @($logon,$recovery) -Settings $settings -Description 'Kaz Demos: authenticated profile pull and verified inventory reports.' -Force
    $enrollment | Add-Member TaskName $name
    $enrollment | Add-Member TaskStarted $false
}
Write-Host '=== ENDPOINT PORTAL PARA COMPARTIR ===' -ForegroundColor Magenta
Write-Host ($enrollment|ConvertTo-Json -Depth 5) -ForegroundColor Magenta
$enrollment
