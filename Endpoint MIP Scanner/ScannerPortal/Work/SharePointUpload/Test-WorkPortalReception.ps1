<#PSScriptInfo
.VERSION 0.1.0
.GUID 9db4ac4a-f2e7-4fd6-9413-1557d38fb74f
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-21 0.1.0 W06 independent portal-side read/validation preview; local receipt only.
#>
<#
.DESCRIPTION
Downloads a sealed batch with existing Setup identity and validates with the PS5.1 reporting contract. No SharePoint writes or endpoint outbox access.
.NOTES
Version     : 0.1.0
Tracking ID : 9db4ac4a-f2e7-4fd6-9413-1557d38fb74f
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][uri]$SiteUrl,
 [Parameter(Mandatory)][guid]$PortalClientId,[Parameter(Mandatory)][guid]$ListId,
 [Parameter(Mandatory)][string]$TargetRelativePath,[Parameter(Mandatory)][string]$ExpectedManifestSha256,
 [Parameter(Mandatory)][string]$VerificationModulePath,
 [string]$StateDirectory=(Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/Work/PortalReceiver'))
$ErrorActionPreference='Stop'
if($TenantId -eq [guid]::Empty -or $PortalClientId -eq [guid]::Empty -or $ListId -eq [guid]::Empty){throw 'Nonempty tenant, Setup and library IDs required.'}
if($TargetRelativePath -cnotmatch '^work-pilot/devices/([a-f0-9]{32})/batches/([a-f0-9]{64})$'){throw 'Invalid exact device/batch path.'}
$deviceId=([guid]$Matches[1]).ToString();$batchId=$Matches[2].ToUpperInvariant()
if($ExpectedManifestSha256 -cnotmatch '^[A-F0-9]{64}$'){throw 'Pinned original manifest hash required.'}
if($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort){throw 'Invalid commercial SharePoint site URL.'}
$VerificationModulePath=(Get-Item -LiteralPath $VerificationModulePath).FullName
if([IO.Path]::GetFileName($VerificationModulePath) -cne 'LocalMIPReporting.psm1'){throw 'Expected original reporting verification module.'}
$StateDirectory=[IO.Path]::GetFullPath($StateDirectory)
for($ancestor=[IO.DirectoryInfo]::new($StateDirectory);$ancestor;$ancestor=$ancestor.Parent){if($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse receiver state directory.'}}
[void][IO.Directory]::CreateDirectory($StateDirectory)
$lock=[IO.File]::Open((Join-Path $StateDirectory 'writer.lock'),'OpenOrCreate','ReadWrite','None')
$temp=Join-Path $StateDirectory ('download-'+[guid]::NewGuid().ToString('N'))
$connection=$null
try{
 if(-not(Get-Module -ListAvailable PnP.PowerShell|Where-Object Version -eq ([version]'3.2.0'))){Install-Module PnP.PowerShell -RequiredVersion 3.2.0 -Scope CurrentUser -Repository PSGallery -Force}
 Import-Module PnP.PowerShell -RequiredVersion 3.2.0
 $connection=Connect-PnPOnline -Url $SiteUrl.AbsoluteUri.TrimEnd('/') -Tenant $TenantId -ClientId $PortalClientId -Interactive -ReturnConnection
 $web=Get-PnPWeb -Includes Url -Connection $connection
 if($web.Url.TrimEnd('/') -ne $SiteUrl.AbsoluteUri.TrimEnd('/')){throw 'Connected site mismatch.'}
 $list=Get-PnPList -Identity $ListId -Includes Id,Title,BaseTemplate,RootFolder -Connection $connection
 if([guid]$list.Id -ne $ListId -or $list.Title -ne 'ScannerPortalLanding' -or $list.BaseTemplate -ne 101){throw 'Unexpected library.'}
 $root=Get-PnPProperty -ClientObject $list -Property RootFolder -Connection $connection
 $null=Get-PnPProperty -ClientObject $root -Property ServerRelativeUrl -Connection $connection
 $folderUrl=$root.ServerRelativeUrl.TrimEnd('/')+'/'+$TargetRelativePath
 [void][IO.Directory]::CreateDirectory($temp)
 foreach($name in 'manifest.json','records.jsonl','coverage.jsonl','summary.json'){
  $url=$folderUrl+'/'+$name
  $metadata=Get-PnPFile -Url $url -AsListItem -Connection $connection
  if(-not $metadata -or $null -eq $metadata['File_x0020_Size'] -or [long]$metadata['File_x0020_Size'] -gt 64MB){throw 'Receiver pilot file limit exceeded.'}
  $null=Get-PnPFile -Url $url -Path $temp -FileName $name -AsFile -Connection $connection
  if((Get-Item -LiteralPath (Join-Path $temp $name)).Length -gt 64MB){throw 'Receiver downloaded file limit exceeded.'}
 }
 $actual=(Get-FileHash -LiteralPath (Join-Path $temp 'manifest.json')).Hash
 if($actual -cne $ExpectedManifestSha256){throw 'Remote manifest differs from original pinned hash.'}
 $manifest=Get-Content -LiteralPath (Join-Path $temp 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable
 if($manifest.batchId -cne $batchId -or $manifest.identity.context.tenantId -ne $TenantId.ToString()){throw 'Remote batch/tenant mismatch.'}
 # Run the original verifier in its supported Windows PowerShell 5.1 runtime.
 $moduleLiteral=$VerificationModulePath.Replace("'","''");$batchLiteral=$temp.Replace("'","''")
 $command="`$ErrorActionPreference='Stop';Import-Module '$moduleLiteral' -Force;Test-LocalMIPReportBatch -BatchDirectory '$batchLiteral'|ConvertTo-Json -Depth 12 -Compress"
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
 $text=& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -OutputFormat Text -InputFormat Text -EncodedCommand $encoded 2>$null
 if($LASTEXITCODE -ne 0){throw 'Original sealed batch verifier rejected downloaded evidence.'}
 $verified=($text -join "`n")|ConvertFrom-Json
 if(-not $verified.Verified -or $verified.BatchId -cne $batchId -or $verified.ManifestSha256 -cne $ExpectedManifestSha256){throw 'Unexpected verifier result.'}
 $receiptName=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($TenantId.ToString()+'|'+$ListId.ToString()+'|'+$TargetRelativePath))))+'.json'
 $receiptPath=Join-Path $StateDirectory $receiptName;$already=$false
 if(Test-Path -LiteralPath $receiptPath){
  $prior=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
  if($prior.ManifestSha256 -cne $ExpectedManifestSha256 -or $prior.TargetRelativePath -cne $TargetRelativePath){throw 'Prior receiver receipt conflicts.'}
  $already=$true
 }
 $result=[ordered]@{Test='W06A-PortalReceptionValidation';Version='0.1.0';Outcome='Validated';AlreadyValidatedLocally=$already
  Authentication='ExistingSetupDelegatedInteractive';TenantId=$TenantId.ToString();ListId=$ListId.ToString();BatchId=$batchId;ManifestSha256=$actual
  ReportingDeviceId=$deviceId;DeviceIdentitySource='FolderLocalPersistentGuidNotAttested';ReportedContext=$manifest.identity.context
  TargetRelativePath=$TargetRelativePath;FilesVerified=4;Summary=($verified.Summary|Select-Object candidateFiles,respondedFiles,noResponseFiles,errorFiles,skippedFiles,filesWithFindings,coverageErrors,appliedRetryCount);ValidatedUtc=[DateTimeOffset]::UtcNow.ToString('o')
  ReceiptPath=$receiptPath;ReceiptScope='LocalReceiverOnly';CentralAcceptancePublished=$false;PortalIngestionConfirmed=$false
  SharePointChanged=$false;EndpointOutboxChanged=$false;FilesUploaded=0;CertificatesCreated=0}
 $staging=$receiptPath+'.tmp';[IO.File]::WriteAllText($staging,($result|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
 if([IO.File]::Exists($receiptPath)){[IO.File]::Replace($staging,$receiptPath,[NullString]::Value)}else{[IO.File]::Move($staging,$receiptPath)}
 Write-Host '=== WORK W06A PARA COMPARTIR ===' -ForegroundColor Magenta
 Write-Host ($result|ConvertTo-Json -Depth 12) -ForegroundColor Magenta
 [pscustomobject]$result
}finally{
 if($connection){Disconnect-PnPOnline -ErrorAction SilentlyContinue}
 if([IO.Directory]::Exists($temp)){
  if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($temp)) -cne $StateDirectory){throw 'Unsafe temporary download cleanup.'}
  [IO.Directory]::Delete($temp,$true)
 }
 $lock.Dispose()
}
