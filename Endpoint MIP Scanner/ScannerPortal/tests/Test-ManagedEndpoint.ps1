<#PSScriptInfo
.VERSION 1.0.0
.GUID b1bf5e35-7203-41f1-b81a-8bbd55039fe6
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 1.0.0 Enrollment, configuration generations, real incremental scan and delivery fault tests.
#>
<#
.DESCRIPTION
Local integration tests; Graph transport mocked. Does not modify tenant or register a task.
.NOTES
Version     : 1.0.0
Tracking ID : b1bf5e35-7203-41f1-b81a-8bbd55039fe6
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed $Message}
$modulePath=Join-Path $PSScriptRoot '../src/ScannerPortal.Endpoint.psm1'
Import-Module $modulePath -Force
$module=Get-Module ScannerPortal.Endpoint
$fixture=Join-Path $env:TEMP ('ManagedEndpoint-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$certThumb=$null
try{
    $bootstrap=@{schemaVersion=1;tenantId=[guid]::NewGuid().ToString();clientId=[guid]::NewGuid().ToString()
        siteUrl='https://example.sharepoint.com/sites/ScannerPortalPilot';configDriveId='config';landingDriveId='landing';sharedIdentity=$true}
    $bootstrapPath=Join-Path $fixture 'bootstrap.json';Write-PortalJson $bootstrap $bootstrapPath
    $directory=Join-Path $fixture 'agent'
    $enrollment=New-PortalEnrollment $bootstrapPath $directory
    $registration=Read-PortalJson $enrollment.RegistrationPath
    $certThumb=$registration.certificateThumbprint
    $again=New-PortalEnrollment $bootstrapPath $directory
    Assert ($again.RegistrationId -eq $enrollment.RegistrationId) 'Enrollment duplicated registration.'
    $request=Read-PortalJson $enrollment.RequestPath
    $public=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($request.certificate))
    Assert (-not $public.HasPrivateKey) 'Enrollment exported a private key.'
    $wrong=Read-PortalJson $bootstrapPath;$wrong.clientId=[guid]::NewGuid().ToString();Write-PortalJson $wrong (Join-Path $fixture 'wrong.json')
    Reject {New-PortalEnrollment (Join-Path $fixture 'wrong.json') $directory} 'Changed identity was adopted.'
    $documents=Join-Path $fixture 'Documentos-con-acento-é'
    [void][IO.Directory]::CreateDirectory($documents)
    $file=Join-Path $documents 'prueba-é.txt';[IO.File]::WriteAllText($file,'PILOT-123456')
    $sourceHash=(Get-FileHash -LiteralPath $file).Hash
    $profile=Read-PortalJson (Join-Path $PSScriptRoot '../config/managed-profile.example.json')
    $profile.expiresUtc=[datetime]::UtcNow.AddDays(10).ToString('o')
    $profile.execution.roots=@($documents)
    $profile.files['incremental.json'].stateDirectory=Join-Path $fixture 'state'
    $profile.files['performance.json'].pauseMilliseconds=0L
    $null=Test-PortalProfile $profile
    $bad=Read-PortalJson (Join-Path $PSScriptRoot '../config/managed-profile.example.json');$bad.execution.command='whoami'
    Reject {Test-PortalProfile $bad} 'Arbitrary execution field accepted.'
    $expired=Read-PortalJson (Join-Path $PSScriptRoot '../config/managed-profile.example.json');$expired.expiresUtc='2020-01-01T00:00:00Z'
    Reject {Test-PortalProfile $expired} 'Expired profile accepted.'
    $profilePath=Join-Path $fixture 'profile.json';Write-PortalJson $profile $profilePath
    $hash=(Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $assignment=@{schemaVersion=1;registrationId=$registration.registrationId;profilePath=('profiles/'+$profile.profileId+'/'+$profile.version+'/'+$hash+'.json');sha256=$hash}
    $assignmentPath=Join-Path $fixture 'assignment.json';Write-PortalJson $assignment $assignmentPath
    & $module {
        param($Assignment,$Profile)
        $script:Assignment=[IO.File]::ReadAllBytes($Assignment);$script:Profile=[IO.File]::ReadAllBytes($Profile)
        $script:Remote=@{};$script:Writes=0;$script:DownloadCorrupt=$false;$script:FailAfterWrite=$false
        function script:Get-PortalBytes($Token,$DriveId,$Path){
            if($DriveId -eq 'config') {if($Path.StartsWith('assignments/')){return ,$script:Assignment};return ,$script:Profile}
            $name=Split-Path -Leaf $Path
            if(-not $script:Remote.ContainsKey($name)){
                $e=[Exception]::new('not found');$e|Add-Member Response ([pscustomobject]@{StatusCode=404});throw $e
            }
            if($script:DownloadCorrupt){return ,([byte[]]@(1,2,3))}
            return ,$script:Remote[$name]
        }
        function script:Get-OrCreatePublisherFolder($Token,$DriveId,$ParentId,$Name){[pscustomobject]@{id=$Name}}
        function script:Invoke-PublisherGraph($Token,$Uri,$Method,$Bytes){
            if($Uri.EndsWith('/root')){return [pscustomobject]@{id='root-item-id'}}
            $name=[regex]::Match($Uri,'/([^/:]+):/content$').Groups[1].Value
            $script:Remote[$name]=$Bytes;$script:Writes++
            if($script:FailAfterWrite){$script:FailAfterWrite=$false;throw 'simulated disconnect after remote write'}
            [pscustomobject]@{id=$name}
        }
    } $assignmentPath $profilePath
    $synced=Sync-PortalProfile $registration $directory 'fixture-token'
    Assert ($synced.Sha256 -eq $hash) 'Profile hash changed.'
    $firstConfig=$synced.ConfigDirectory
    & $module {$script:Profile=[Text.Encoding]::UTF8.GetBytes('{}')}
    Reject {Sync-PortalProfile $registration $directory 'fixture-token'} 'Corrupt profile activated.'
    $cached=Get-PortalCachedProfile $directory
    Assert ($cached.Sha256 -eq $hash -and $cached.Source -eq 'Cache') 'Failed update lost last valid profile.'
    $scan=Get-PortalScanParameters $registration $cached $directory
    $state1=(Read-PortalJson (Join-Path $scan.ConfigDirectory 'incremental.json')).stateDirectory
    $scanner=Join-Path $PSScriptRoot '../../LocalMIPScanner.WinPS51/Invoke-LocalMIPScanner.ps1'
    $first=& $scanner @scan
    $restart=Join-Path $fixture 'restart-cache.ps1'
    [IO.File]::WriteAllText($restart,'param($ModulePath,$Directory) $ErrorActionPreference="Stop"; Import-Module $ModulePath -Force; $null=Get-PortalCachedProfile $Directory',[Text.UTF8Encoding]::new($true))
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -File $restart -ModulePath $modulePath -Directory $directory
    Assert ($LASTEXITCODE -eq 0) 'A fresh PS5.1 process could not restore the cached profile.'
    $scan=Get-PortalScanParameters $registration $cached $directory
    $second=& $scanner @scan
    Assert ($first.contentAudited -eq 1 -and $second.contentAudited -eq 0 -and $second.contentAuditReused -eq 1) 'Real scanner failed content delta reuse.'
    Assert ((Get-FileHash -LiteralPath $file).Hash -eq $sourceHash) 'Audit modified the source.'
    $profile.execution.idleSeconds=600L
    Write-PortalJson $profile $profilePath
    $cached.Profile=$profile
    $null=Get-PortalScanParameters $registration $cached $directory
    $state2=(Read-PortalJson (Join-Path $scan.ConfigDirectory 'incremental.json')).stateDirectory
    Assert ($state1 -eq $state2) 'Schedule-only update reset incremental state.'
    $profile.files['classifiers.json'].rules[0].pattern='PILOT-[0-9]+'
    $null=Get-PortalScanParameters $registration $cached $directory
    $state3=(Read-PortalJson (Join-Path $scan.ConfigDirectory 'incremental.json')).stateDirectory
    Assert ($state1 -ne $state3 -and (Test-Path -LiteralPath $state1)) 'Rule change failed to isolate/preserve old state.'
    $batch=New-PortalRunBatch $registration $cached $first $directory
    & $module {$script:FailAfterWrite=$true}
    Reject {Send-PortalBatch $registration 'fixture-token' $batch} 'Disconnect after upload did not preserve pending state.'
    Assert (Test-Path -LiteralPath $batch) 'Failed delivery removed local batch.'
    $sent=Send-PortalBatch $registration 'fixture-token' $batch
    Assert ($sent.DeliveryState -eq 'UploadedVerified' -and -not $sent.AcceptedByCentralProcessor) 'Delivery incorrectly claimed central acceptance.'
    Assert (-not(Test-Path -LiteralPath $batch)) 'Verified delivery remained pending.'
    $cycle=Join-Path $directory 'logs/interrupted-cycle'
    [void][IO.Directory]::CreateDirectory($cycle)
    Write-PortalJson @{startedUtc=[datetime]::UtcNow.ToString('o');profile=@{Profile=@{profileId=$profile.profileId;version=$profile.version};Sha256=$cached.Sha256;Source='Cache'}} (Join-Path $cycle 'cycle.json')
    $orphanId=[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $cycle ('inventory-'+$orphanId+'.jsonl')),'{"event":"start"}'+[Environment]::NewLine+'{"event":')
    Restore-PortalRunBatches $registration $directory
    $restored=Join-Path $directory ('outbox/Pending/'+$orphanId)
    $restoredSummary=Read-PortalJson (Join-Path $restored 'summary.json')
    Assert ($restoredSummary.summary.interrupted -and $restoredSummary.summary.coverage -eq 'PartialInterruptedRun') 'Interrupted log was lost or counted complete.'
    Restore-PortalRunBatches $registration $directory
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $directory 'outbox/Pending') -Directory|Where-Object Name -eq $orphanId).Count -eq 1) 'Recovery duplicated interrupted batch.'
    $batch=New-PortalRunBatch $registration $cached $second $directory
    & $module {$script:Remote=@{};$script:DownloadCorrupt=$true}
    Reject {Send-PortalBatch $registration 'fixture-token' $batch} 'Corrupt download accepted.'
    Assert (Test-Path -LiteralPath $batch) 'Corrupt delivery lost pending batch.'
    $malicious=Read-PortalJson (Join-Path $batch 'manifest.json');$malicious.files[0].name='../outside.txt';Write-PortalJson $malicious (Join-Path $batch 'manifest.json')
    Reject {Send-PortalBatch $registration 'fixture-token' $batch} 'Path traversal accepted.'
    'PASS: real CurrentUser public enrollment, profile validation/cache/hash, Unicode roots, incremental reuse, scope change preservation, disconnect/retry and corrupt delivery (mock Graph); no task/tenant operations'
} finally {
    if($certThumb){Remove-Item -LiteralPath ('Cert:\CurrentUser\My\'+$certThumb) -DeleteKey -Force}
    if([IO.Directory]::Exists($fixture)){[IO.Directory]::Delete($fixture,$true)}
    Remove-Module ScannerPortal.Endpoint -ErrorAction SilentlyContinue
}
