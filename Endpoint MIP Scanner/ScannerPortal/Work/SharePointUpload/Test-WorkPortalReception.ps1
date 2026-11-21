<#PSScriptInfo
.VERSION 0.2.0
.GUID 9db4ac4a-f2e7-4fd6-9413-1557d38fb74f
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-21 0.2.0 Optional W06B2 central acceptance publication after fresh remote validation and ACL review.
2026-11-21 0.1.0 W06 independent portal-side read/validation preview; local receipt only.
#>
<#
.DESCRIPTION
Downloads and validates a sealed batch with existing Setup identity and PS5.1 contract. Optional central acceptance add/readback; no endpoint outbox access.
.NOTES
Version     : 0.2.0
Tracking ID : 9db4ac4a-f2e7-4fd6-9413-1557d38fb74f
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][uri]$SiteUrl,
 [Parameter(Mandatory)][guid]$PortalClientId,[Parameter(Mandatory)][guid]$ListId,
 [Parameter(Mandatory)][string]$TargetRelativePath,[Parameter(Mandatory)][string]$ExpectedManifestSha256,
 [Parameter(Mandatory)][string]$VerificationModulePath,[switch]$PublishAcceptance,[guid]$AcceptanceListId=[guid]::Empty,[switch]$AcknowledgePublisherDenied,
 [string]$StateDirectory=(Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/Work/PortalReceiver'))
$ErrorActionPreference='Stop'
if($PublishAcceptance -and ($AcceptanceListId -eq [guid]::Empty -or $AcceptanceListId -eq $ListId -or -not $AcknowledgePublisherDenied)){throw 'Separate acceptance list and prior publisher-denial acknowledgment required.'}
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
function Publish-WorkAcceptance {
 $ledger=Get-PnPList -Identity $AcceptanceListId -Includes Id,Title,BaseTemplate,HasUniqueRoleAssignments -Connection $connection
 if([guid]$ledger.Id -ne $AcceptanceListId -or $ledger.Title -ne 'ScannerPortalAcceptance' -or $ledger.BaseTemplate -ne 100 -or -not $ledger.HasUniqueRoleAssignments){throw 'Unexpected or inherited acceptance list.'}
 $admins=@(Get-PnPSiteCollectionAdmin -Connection $connection|ForEach-Object {$_.LoginName})
 if(-not $admins.Count){throw 'Cannot verify acceptance administrator baseline.'}
 $null=Get-PnPProperty -ClientObject $ledger -Property RoleAssignments -Connection $connection
 $allowed=0
 foreach($assignment in $ledger.RoleAssignments){
  $member=Get-PnPProperty -ClientObject $assignment -Property Member -Connection $connection
  $null=Get-PnPProperty -ClientObject $member -Property LoginName -Connection $connection
  $null=Get-PnPProperty -ClientObject $assignment -Property RoleDefinitionBindings -Connection $connection
  foreach($role in $assignment.RoleDefinitionBindings){
   $null=Get-PnPProperty -ClientObject $role -Property RoleTypeKind -Connection $connection
   if([int]$role.RoleTypeKind -ne 1){if($member.LoginName -notin $admins){throw 'Non-administrator acceptance access; no publication.'};$allowed++}
  }
 }
 if(-not $allowed){throw 'No administrator acceptance assignment.'}
 $title=Get-PnPField -List $AcceptanceListId -Identity Title -Connection $connection
 if(-not $title.Indexed -or -not $title.EnforceUniqueValues -or -not $title.Required){throw 'Acceptance key lacks required unique index.'}
 foreach($name in 'AcceptanceJson','SourceRelativePath'){
  $field=Get-PnPField -List $AcceptanceListId -Identity $name -Connection $connection
  if($field.TypeAsString -ne 'Note' -or $field.RichText -or $field.AppendOnly){throw 'Unexpected acceptance text schema.'}
 }
 $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($TenantId.ToString()+'|'+$SiteUrl.AbsoluteUri.TrimEnd('/').ToLowerInvariant()+'|'+$ListId.ToString()+'|'+$TargetRelativePath)))
 $query="<View><Query><Where><Eq><FieldRef Name='Title'/><Value Type='Text'>$key</Value></Eq></Where></Query><RowLimit>2</RowLimit></View>"
 $values=@{Title=$key;BatchId=$batchId;ManifestSha256=$actual;ReportingDeviceId=$deviceId;SourceListId=$ListId.ToString();SourceRelativePath=$TargetRelativePath}
 $summary=$verified.Summary|Select-Object candidateFiles,respondedFiles,noResponseFiles,errorFiles,skippedFiles,filesWithFindings,coverageErrors,appliedRetryCount
 $acceptance=[ordered]@{contract='ScannerPortalAcceptance/1';state='AcceptedValidatedBatch';tenantId=$TenantId.ToString();sourceSiteUrl=$SiteUrl.AbsoluteUri.TrimEnd('/');sourceListId=$ListId.ToString()
  sourceRelativePath=$TargetRelativePath;acceptanceKey=$key;batchId=$batchId;manifestSha256=$actual;reportingDeviceId=$deviceId;summary=$summary
  acceptedUtc=[DateTimeOffset]::UtcNow.ToString('o');validationScope='Sealed identity, payload hashes/sizes and eight summary counts';reportingIngestionConfirmed=$false}
 $values.AcceptanceJson=$acceptance|ConvertTo-Json -Compress -Depth 8
 $existing=@(Get-PnPListItem -List $AcceptanceListId -Query $query -Connection $connection)
 $created=$false;$uncertain=$false
 if(-not $existing.Count){
  try{$null=Add-PnPListItem -List $AcceptanceListId -Values $values -Connection $connection;$created=$true}
  catch{$uncertain=$true}
  # Also resolves a unique-key race or a lost successful create response; never updates existing items.
  $existing=@(Get-PnPListItem -List $AcceptanceListId -Query $query -Connection $connection)
 }
 if($existing.Count -ne 1){throw 'Acceptance creation/readback not confirmed; rerun revalidates remote batch.'}
 $item=$existing[0]
 foreach($name in 'Title','BatchId','ManifestSha256','ReportingDeviceId','SourceListId','SourceRelativePath'){
  if([string]$item[$name] -cne [string]$values[$name]){throw "Conflicting acceptance field: $name. Existing record preserved."}
 }
 $saved=[string]$item['AcceptanceJson']|ConvertFrom-Json
 foreach($name in 'contract','state','tenantId','sourceSiteUrl','sourceListId','sourceRelativePath','acceptanceKey','batchId','manifestSha256','reportingDeviceId','validationScope'){
  if([string]$saved.$name -cne [string]$acceptance[$name]){throw 'Conflicting acceptance body; no overwrite.'}
 }
 foreach($name in 'candidateFiles','respondedFiles','noResponseFiles','errorFiles','skippedFiles','filesWithFindings','coverageErrors','appliedRetryCount'){
  if($null -eq $saved.summary.$name -or $saved.summary.$name -ne $summary.$name){throw 'Conflicting acceptance counts; no overwrite.'}
 }
 $accepted=[DateTimeOffset]::MinValue
 if(-not [DateTimeOffset]::TryParse([string]$saved.acceptedUtc,[ref]$accepted) -or $saved.reportingIngestionConfirmed -ne $false){throw 'Invalid acceptance timestamp/state.'}
 return [ordered]@{AcceptanceListId=$AcceptanceListId.ToString();AcceptanceKey=$key;AcceptanceItemId=$item.Id;AcceptanceCreatedThisRun=$created;CreateResponseUncertain=$uncertain
  AcceptanceReadBackVerified=$true;AcceptedUtc=$saved.acceptedUtc;AcceptanceState='AcceptedValidatedBatch';ReportingIngestionConfirmed=$false}
}

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
 $central=$null
 if($PublishAcceptance){$central=Publish-WorkAcceptance}
 $result=[ordered]@{Test=if($PublishAcceptance){'W06B2-CentralAcceptance'}else{'W06A-PortalReceptionValidation'};Version='0.2.0';Outcome=if($PublishAcceptance){'Accepted'}else{'Validated'};AlreadyValidatedLocally=$already
  Authentication='ExistingSetupDelegatedInteractive';TenantId=$TenantId.ToString();ListId=$ListId.ToString();BatchId=$batchId;ManifestSha256=$actual
  ReportingDeviceId=$deviceId;DeviceIdentitySource='FolderLocalPersistentGuidNotAttested';ReportedContext=$manifest.identity.context
  TargetRelativePath=$TargetRelativePath;FilesVerified=4;Summary=($verified.Summary|Select-Object candidateFiles,respondedFiles,noResponseFiles,errorFiles,skippedFiles,filesWithFindings,coverageErrors,appliedRetryCount);ValidatedUtc=[DateTimeOffset]::UtcNow.ToString('o')
  ReceiptPath=$receiptPath;ReceiptScope='LocalReceiverOnly';CentralAcceptancePublished=[bool]$PublishAcceptance;CentralAcceptance=$central;PortalIngestionConfirmed=$false
  SharePointChanged=($PublishAcceptance -and ($central.AcceptanceCreatedThisRun -or $central.CreateResponseUncertain));EndpointOutboxChanged=$false;FilesUploaded=0;CertificatesCreated=0}
 $staging=$receiptPath+'.tmp';[IO.File]::WriteAllText($staging,($result|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
 if([IO.File]::Exists($receiptPath)){[IO.File]::Replace($staging,$receiptPath,[NullString]::Value)}else{[IO.File]::Move($staging,$receiptPath)}
 Write-Host ($(if($PublishAcceptance){'=== WORK W06B2 PARA COMPARTIR ==='}else{'=== WORK W06A PARA COMPARTIR ==='})) -ForegroundColor Magenta
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
