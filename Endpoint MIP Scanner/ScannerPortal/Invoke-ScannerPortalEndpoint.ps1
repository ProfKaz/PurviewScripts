<#PSScriptInfo
.VERSION 1.1.0
.GUID cb3e6ef2-d589-4383-88f9-883caa438eaf
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-25 1.1.0 Report fleet contact independently of scan findings.
2026-11-20 1.0.0 Pull configuration, bounded scan, durable report and verified upload.
#>
<#
.DESCRIPTION
Managed endpoint pilot. Audit-only; no document labeling. Continuous mode polls between bounded scan cycles.
.NOTES
Version     : 1.1.0
Tracking ID : cb3e6ef2-d589-4383-88f9-883caa438eaf
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param([string]$Directory=(Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/ManagedEndpoint'),[switch]$Continuous,[switch]$SyncOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'src/ScannerPortal.Endpoint.psm1') -Force
$Directory=Assert-PortalDirectory $Directory
$registration=Read-PortalJson (Join-Path $Directory 'registration.json')
Assert-PortalBootstrap $registration.bootstrap
$lock=[IO.File]::Open((Join-Path $Directory 'runtime.lock'),'OpenOrCreate','ReadWrite','None')
try {
    do {
        $token=$null; $profile=$null; $idle=60; $status=[ordered]@{event='managedEndpoint';startedUtc=[datetime]::UtcNow.ToString('o');registrationId=$registration.registrationId}
        try {
            try {
                $token=Get-PortalToken $registration
                $profile=Sync-PortalProfile -Registration $registration -Directory $Directory -Token $token
            } catch {
                # Authentication/authorization errors must not masquerade as offline success.
                if ((Get-PortalHttpStatus $_) -in 400,401,403,404) { throw }
                $status.syncError=$_.Exception.GetType().Name
                $profile=Get-PortalCachedProfile $Directory
            }
            $idle=[int]$profile.Profile.execution.idleSeconds
            $status.profileId=$profile.Profile.profileId; $status.profileVersion=$profile.Profile.version; $status.profileSource=$profile.Source
            if(-not $SyncOnly){Restore-PortalRunBatches $registration $Directory}
            $pending=Join-Path $Directory 'outbox/Pending'
            if (-not $SyncOnly -and $token -and (Test-Path -LiteralPath $pending)) {
                foreach ($batch in @(Get-ChildItem -LiteralPath $pending -Directory | Where-Object Name -Match '^[a-f0-9]{32}$' | Select-Object -First 10)) {
                    $null=Send-PortalBatch $registration $token $batch.FullName
                }
            }
            if (-not $SyncOnly -and -not $profile.Profile.execution.paused) {
                $bytes=0L
                foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Recurse)) { $bytes+=$file.Length }
                if ($bytes -ge 512MB) { throw 'Managed endpoint local quota reached; preserve reports and review storage.' }
                $suite=Split-Path -Parent $PSScriptRoot
                $scan=Get-PortalScanParameters $registration $profile $Directory
                $cycle=Join-Path (Join-Path $Directory 'logs') ([guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($cycle)
                Write-PortalJson @{startedUtc=[datetime]::UtcNow.ToString('o');profile=@{Profile=@{profileId=$profile.Profile.profileId;version=$profile.Profile.version};Sha256=$profile.Sha256;Source=$profile.Source}} (Join-Path $cycle 'cycle.json')
                $scan.LogDirectory=$cycle
                $summary=& (Join-Path $suite 'LocalMIPScanner.WinPS51/Invoke-LocalMIPScanner.ps1') @scan
                $batch=New-PortalRunBatch $registration $profile $summary $Directory
                $status.runId=$summary.runId; $status.deliveryState='PendingUpload'
                if ($token) { $delivery=Send-PortalBatch $registration $token $batch; $status.deliveryState=$delivery.DeliveryState }
            } else { $status.scanState=if ($SyncOnly) {'SyncOnly'} else {'Paused'} }
            $status.outcome='Completed'
        } catch { $status.outcome='Failed';$status.error=$_.Exception.Message }
        finally {
            if ($token -and $profile -and -not $SyncOnly) {
                try {
                    $mode = if ($status.outcome -eq 'Failed') {'Failed'} elseif ($profile.Profile.execution.paused) {'Paused'} else {'Active'}
                    $status.heartbeat = Send-PortalHeartbeat $registration $token $profile $Directory $mode
                } catch {
                    $status.heartbeat = 'Failed'
                    $status.heartbeatError = $_.Exception.GetType().Name
                }
            }
            $token=$null
        }
        Write-PortalJson $status (Join-Path $Directory 'last-status.json')
        Write-Host '=== ENDPOINT PORTAL PARA COMPARTIR ===' -ForegroundColor Magenta
        Write-Host ($status|ConvertTo-Json -Depth 6) -ForegroundColor Magenta
        [pscustomobject]$status
        if (-not $Continuous -and $status.outcome -eq 'Failed') { throw 'Managed endpoint cycle failed. See last-status.json.' }
        if ($Continuous -and -not $SyncOnly) { Start-Sleep -Seconds $idle }
    } while ($Continuous -and -not $SyncOnly)
} finally { $lock.Dispose() }
