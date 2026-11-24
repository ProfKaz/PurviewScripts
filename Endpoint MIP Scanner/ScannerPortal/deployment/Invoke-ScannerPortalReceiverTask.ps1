<#PSScriptInfo
.VERSION 0.1.0
.GUID eb0d3972-d283-467f-9f24-fcfa4f29a6a3
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.0 Run one certificate-authenticated receiver pass and publish local health.
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$homeDir=Split-Path $PSScriptRoot
$settings=Get-Content -LiteralPath (Join-Path $homeDir 'receiver.json') -Raw | ConvertFrom-Json
$state=Join-Path $homeDir 'state'
$health=[ordered]@{startedUtc=[datetime]::UtcNow.ToString('o');identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    clientId=$settings.clientId;outcome='Running';finishedUtc=$null}
function Save-Health {
    $path=Join-Path $state 'status.json'
    [IO.File]::WriteAllText("$path.tmp",($health | ConvertTo-Json -Depth 5))
    [IO.File]::Move("$path.tmp",$path,$true)
}
Save-Health
try {
    $params=@{SiteUrl=$settings.siteUrl;TenantId=$settings.tenantId;PortalClientId=$settings.clientId
        CertificateThumbprint=$settings.thumbprint;StateDirectory=$state;AcknowledgePublisherDenied=$true}
    $result=& (Join-Path $homeDir 'Work/SharePointUpload/Start-ScannerPortalReceiver.ps1') @params
    if ($result.Test -ne 'ManagedReceiver') {throw 'Receiver did not return its pass summary.'}
    $health.result=$result
    $health.outcome=if ($result.Pending) {'PendingRetry'} else {'Completed'}
} catch {
    $health.outcome='Failed'
    $health.error=$_.Exception.Message
    throw
} finally {
    $health.finishedUtc=[datetime]::UtcNow.ToString('o')
    Save-Health
}
