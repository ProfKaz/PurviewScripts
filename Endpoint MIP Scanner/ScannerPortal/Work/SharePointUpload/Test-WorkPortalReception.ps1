<#PSScriptInfo
.VERSION 0.8.0
.GUID 9db4ac4a-f2e7-4fd6-9413-1557d38fb74f
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
0.8.0 Store and verify endpoint-reported Windows identity on managed acceptance rows.
0.7.0 Allow the discovery worker to reuse its authenticated site connection.
0.6.0 Refresh the configured overview following verified report storage or reuse.
2026-11-23 0.5.0 Validate and project managed inventory runs separately from Purview SIT reports.
2026-11-21 0.3.0 W06C read-only reporting from accepted sealed evidence.
2026-11-21 0.2.0 Optional W06B2 central acceptance publication after fresh remote validation and ACL review.
2026-11-21 0.1.0 W06 independent portal-side read/validation preview; local receipt only.
#>
<#
.DESCRIPTION
Downloads and validates a sealed batch with existing Setup identity and PS5.1 contract. Optional central acceptance add/readback; no endpoint outbox access.
.NOTES
Version     : 0.8.0
Tracking ID : 9db4ac4a-f2e7-4fd6-9413-1557d38fb74f
#>
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][uri]$SiteUrl,
 [Parameter(Mandatory)][guid]$PortalClientId,[Parameter(Mandatory)][guid]$ListId,
 [Parameter(Mandatory)][string]$TargetRelativePath,[Parameter(Mandatory)][string]$ExpectedManifestSha256,
 [object]$ReceiverConnection,
 [string]$VerificationModulePath,[switch]$ManagedInventory,[switch]$PublishAcceptance,[switch]$ReportAcceptedBatch,[switch]$StoreReport,[guid]$AcceptanceListId=[guid]::Empty,[switch]$AcknowledgePublisherDenied,
 [string]$StateDirectory=(Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/Work/PortalReceiver'))
$ErrorActionPreference='Stop'
if ($ManagedInventory -and ($PublishAcceptance -or $ReportAcceptedBatch -or -not $StoreReport -or
    -not $AcknowledgePublisherDenied -or $AcceptanceListId -in @([guid]::Empty,$ListId))) {
    throw 'ManagedInventory requires StoreReport, a distinct acceptance list and a publisher-denial acknowledgment.'
}

if($StoreReport -and -not ($ReportAcceptedBatch -or $ManagedInventory)){throw 'StoreReport requires ReportAcceptedBatch.'}
if($ReportAcceptedBatch -and ($PublishAcceptance -or $AcceptanceListId -eq [guid]::Empty -or $AcceptanceListId -eq $ListId)){throw 'Reporting requires a separate acceptance list and cannot publish.'}
if($PublishAcceptance -and ($AcceptanceListId -eq [guid]::Empty -or $AcceptanceListId -eq $ListId -or -not $AcknowledgePublisherDenied)){throw 'Separate acceptance list and prior publisher-denial acknowledgment required.'}
if($TenantId -eq [guid]::Empty -or $PortalClientId -eq [guid]::Empty -or $ListId -eq [guid]::Empty){throw 'Nonempty tenant, Setup and library IDs required.'}
if ($ManagedInventory) {
    if ($TargetRelativePath -cnotmatch '^devices/([a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})/batches/([a-f0-9]{32})$') {throw 'Invalid managed registration/run path.'}
    $deviceId=([guid]$Matches[1]).ToString()
    $batchId=$Matches[2]
} else {
    if($TargetRelativePath -cnotmatch '^work-pilot/devices/([a-f0-9]{32})/batches/([a-f0-9]{64})$'){throw 'Invalid exact device/batch path.'}
    $deviceId=([guid]$Matches[1]).ToString()
    $batchId=$Matches[2].ToUpperInvariant()
}

if($ExpectedManifestSha256 -cnotmatch '^[A-F0-9]{64}$'){throw 'Pinned original manifest hash required.'}
if($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort){throw 'Invalid commercial SharePoint site URL.'}
if (-not $ManagedInventory) {
    if (-not $VerificationModulePath) { throw 'VerificationModulePath is required for sealed batches.' }
    $VerificationModulePath=(Get-Item -LiteralPath $VerificationModulePath).FullName
    if([IO.Path]::GetFileName($VerificationModulePath) -cne 'LocalMIPReporting.psm1'){throw 'Expected original reporting verification module.'}
}
$StateDirectory=[IO.Path]::GetFullPath($StateDirectory)
for($ancestor=[IO.DirectoryInfo]::new($StateDirectory);$ancestor;$ancestor=$ancestor.Parent){if($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse receiver state directory.'}}
[void][IO.Directory]::CreateDirectory($StateDirectory)
$lock=[IO.File]::Open((Join-Path $StateDirectory 'writer.lock'),'OpenOrCreate','ReadWrite','None')
$temp=Join-Path $StateDirectory ('download-'+[guid]::NewGuid().ToString('N'))
$connection=$null
function Get-WorkAcceptance {
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
 $summary=if ($ManagedInventory) { $managed.Counts } else {
    $verified.Summary|Select-Object candidateFiles,respondedFiles,noResponseFiles,errorFiles,skippedFiles,filesWithFindings,coverageErrors,appliedRetryCount
 }
 $validationScope=if ($ManagedInventory) {'Managed run identity, payload hashes/sizes and reconciled counts'}else{'Sealed identity, payload hashes/sizes and eight summary counts'}
 $acceptance=[ordered]@{contract='ScannerPortalAcceptance/1';state='AcceptedValidatedBatch';tenantId=$TenantId.ToString();sourceSiteUrl=$SiteUrl.AbsoluteUri.TrimEnd('/');sourceListId=$ListId.ToString()
  sourceRelativePath=$TargetRelativePath;acceptanceKey=$key;batchId=$batchId;manifestSha256=$actual;reportingDeviceId=$deviceId;summary=$summary
  acceptedUtc=[DateTimeOffset]::UtcNow.ToString('o');validationScope=$validationScope;reportingIngestionConfirmed=$false}
 $values.AcceptanceJson=$acceptance|ConvertTo-Json -Compress -Depth 8
 $existing=@(Get-PnPListItem -List $AcceptanceListId -Query $query -Connection $connection)
 $created=$false;$uncertain=$false
 if(-not $existing.Count -and ($PublishAcceptance -or $ManagedInventory)){
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
 foreach($property in ([pscustomobject]$summary).PSObject.Properties){
  $name=$property.Name
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
 $connection=if ($ReceiverConnection) {$ReceiverConnection} else {Connect-PnPOnline -Url $SiteUrl.AbsoluteUri.TrimEnd('/') -Tenant $TenantId -ClientId $PortalClientId -Interactive -ReturnConnection}
 $web=Get-PnPWeb -Includes Url -Connection $connection
 if($web.Url.TrimEnd('/') -ne $SiteUrl.AbsoluteUri.TrimEnd('/')){throw 'Connected site mismatch.'}
 $list=Get-PnPList -Identity $ListId -Includes Id,Title,BaseTemplate,RootFolder -Connection $connection
 if([guid]$list.Id -ne $ListId -or $list.Title -ne 'ScannerPortalLanding' -or $list.BaseTemplate -ne 101){throw 'Unexpected library.'}
 $root=Get-PnPProperty -ClientObject $list -Property RootFolder -Connection $connection
 $null=Get-PnPProperty -ClientObject $root -Property ServerRelativeUrl -Connection $connection
 $folderUrl=$root.ServerRelativeUrl.TrimEnd('/')+'/'+$TargetRelativePath
 [void][IO.Directory]::CreateDirectory($temp)
 $names=@('manifest.json','records.jsonl','summary.json')
 if (-not $ManagedInventory) { $names+= 'coverage.jsonl' }
 foreach($name in $names){
  $url=$folderUrl+'/'+$name
  $metadata=Get-PnPFile -Url $url -AsListItem -Connection $connection
  if(-not $metadata -or $null -eq $metadata['File_x0020_Size'] -or [long]$metadata['File_x0020_Size'] -gt 64MB){throw 'Receiver pilot file limit exceeded.'}
  $null=Get-PnPFile -Url $url -Path $temp -FileName $name -AsFile -Connection $connection
  if((Get-Item -LiteralPath (Join-Path $temp $name)).Length -gt 64MB){throw 'Receiver downloaded file limit exceeded.'}
 }
 $actual=(Get-FileHash -LiteralPath (Join-Path $temp 'manifest.json')).Hash
 if($actual -cne $ExpectedManifestSha256){throw 'Remote manifest differs from original pinned hash.'}
 $manifest=Get-Content -LiteralPath (Join-Path $temp 'manifest.json') -Raw|ConvertFrom-Json -AsHashtable
 if ($ManagedInventory) {
  . (Join-Path $PSScriptRoot 'Read-ManagedInventoryProjection.ps1')
  $managed=Read-ManagedInventoryProjection $temp $manifest $TenantId $deviceId $batchId
 } else {
 if($manifest.batchId -cne $batchId -or $manifest.identity.context.tenantId -ne $TenantId.ToString()){throw 'Remote batch/tenant mismatch.'}
 # Run the original verifier in its supported Windows PowerShell 5.1 runtime.
 $moduleLiteral=$VerificationModulePath.Replace("'","''");$batchLiteral=$temp.Replace("'","''")
 $command="`$ErrorActionPreference='Stop';Import-Module '$moduleLiteral' -Force;Test-LocalMIPReportBatch -BatchDirectory '$batchLiteral'|ConvertTo-Json -Depth 12 -Compress"
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
 $text=& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -OutputFormat Text -InputFormat Text -EncodedCommand $encoded 2>$null
 if($LASTEXITCODE -ne 0){throw 'Original sealed batch verifier rejected downloaded evidence.'}
 $verified=($text -join "`n")|ConvertFrom-Json
 if(-not $verified.Verified -or $verified.BatchId -cne $batchId -or $verified.ManifestSha256 -cne $ExpectedManifestSha256){throw 'Unexpected verifier result.'}
 }
 if($ReportAcceptedBatch -or $ManagedInventory){
  $central=Get-WorkAcceptance
  $extensions=@{};$outcomes=@{};$types=@{}
  if (-not $ManagedInventory) {
  foreach($line in [IO.File]::ReadLines((Join-Path $temp 'records.jsonl'))){
   if([string]::IsNullOrWhiteSpace($line)){continue}
   $record=ConvertFrom-Json -InputObject $line -AsHashtable
   $extension=if($record.extension){$record.extension.ToLowerInvariant()}else{'(sin extension)'}
   $outcome=[string]$record.outcome
   $extensions[$extension]++
   $outcomes[$outcome]++
   $seen=[Collections.Generic.HashSet[guid]]::new()
   foreach($finding in $record.findings){
    $id=[guid]$finding.sitId
    if(-not $types.ContainsKey($id)){
     $types[$id]=[ordered]@{SitId=$id.ToString();Name=$finding.name;Files=0;Matches=[long]0}
    }
    if($seen.Add($id)){$types[$id].Files++}
    $types[$id].Matches += [long]$finding.count
   }
  }
  }
  $report=[ordered]@{
   Test='W06C-AcceptedBatchReport';Outcome='Reported';BatchId=$batchId;ManifestSha256=$actual
   ReportingDeviceId=$deviceId;AccountObjectId=$manifest.identity.context.accountObjectId
   AcceptanceItemId=$central.AcceptanceItemId;AcceptanceKey=$central.AcceptanceKey;FilesVerified=4
   ByExtension=@($extensions.Keys | Sort-Object | ForEach-Object {[ordered]@{Extension=$_;Files=$extensions[$_]}})
   ByOutcome=@($outcomes.Keys | Sort-Object | ForEach-Object {[ordered]@{Outcome=$_;Files=$outcomes[$_]}})
   BySit=@($types.Keys | Sort-Object | ForEach-Object {$types[$_]})
   CoverageErrors=$verified.Summary.coverageErrors;SharePointChanged=$false;PortalIngestionConfirmed=$false
  }
  if ($ManagedInventory) {
   $report.FilesVerified=2
   $report.ByExtension=$managed.ByExtension
   $report.ByOutcome=$managed.ByOutcome
   $report.CoverageErrors=$managed.Counts.InventoryErrors
   $report.ManagedInventory=$managed.Inventory
  }
  if($StoreReport){
   $projection=[ordered]@{
    SchemaVersion=1;BatchId=$batchId;ManifestSha256=$actual;AcceptanceKey=$central.AcceptanceKey
    ReportingDeviceId=$deviceId;AccountObjectId=$report.AccountObjectId
    ByExtension=$report.ByExtension;ByOutcome=$report.ByOutcome;BySit=$report.BySit
    CoverageErrors=$report.CoverageErrors
   }
   if ($ManagedInventory) { $projection.ManagedInventory=$managed.Inventory }
   $summaryJson=ConvertTo-Json -InputObject $projection -Depth 8 -Compress
   if($summaryJson.Length -gt 60000){throw 'Summary exceeds the pilot column size limit.'}
   $column='PortalReportJson'
   $field=@(Get-PnPField -List $AcceptanceListId -Connection $connection | Where-Object InternalName -eq $column)
   if(-not $field.Count){
    $null=Add-PnPField -List $AcceptanceListId -DisplayName $column -InternalName $column -Type Note -Connection $connection
   }
   $field=Get-PnPField -List $AcceptanceListId -Identity $column -Connection $connection
   if($field.TypeAsString -ne 'Note' -or $field.RichText -or $field.AppendOnly){throw 'Unexpected report column schema.'}
   $item=Get-PnPListItem -List $AcceptanceListId -Id $central.AcceptanceItemId -Connection $connection
   if($item['Title'] -cne $central.AcceptanceKey -or $item['ManifestSha256'] -cne $actual){throw 'Acceptance changed before report storage.'}
   $stored=[string]$item[$column]
   if ($stored -and $stored -cne $summaryJson) { throw 'Stored report differs from validated summary.' }
   $updates=@{}
   if (!$stored) { $updates[$column]=$summaryJson }
   if ($ManagedInventory) {
    foreach ($key in $managed.RunIdentity.Keys) {
     $prior=[string]$item[$key]
     if (!$prior) { $updates[$key]=$managed.RunIdentity[$key] }
     elseif ($prior -cne $managed.RunIdentity[$key]) { throw "Stored $key differs from the verified scan summary." }
    }
   }
   $changed=$updates.Count -gt 0
   if($changed){
    $null=Set-PnPListItem -List $AcceptanceListId -Identity $central.AcceptanceItemId -Values $updates -Connection $connection
    $item=Get-PnPListItem -List $AcceptanceListId -Id $central.AcceptanceItemId -Connection $connection
    $stored=[string]$item[$column]
   }
   if($stored -cne $summaryJson -or $item['Title'] -cne $central.AcceptanceKey -or $item['ManifestSha256'] -cne $actual){throw 'Stored report differs from validated summary or acceptance binding.'}
   if ($ManagedInventory) {
    foreach ($key in $managed.RunIdentity.Keys) {
     if ($item[$key] -cne $managed.RunIdentity[$key]) { throw "Failed to verify $key on acceptance readback." }
    }
   }
   $report.Test=if($ManagedInventory){'ManagedInventory-PortalIngestion'}else{'W06D-StoreAcceptedBatchReport'}
   $report.Outcome=if($changed){'Stored'}else{'Reused'}
   $report.SharePointChanged=($changed -or $central.AcceptanceCreatedThisRun -or $central.CreateResponseUncertain)
   $report.PortalIngestionConfirmed=$true
   $report.ReportSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($stored)))
   $report.SitTypes=$report.BySit.Count
   $report.Remove('BySit')
   $publisher=Join-Path $PSScriptRoot '../../deployment/Publish-ScannerPortalOverview.ps1'
   try {
    $report.OverviewRefresh = & $publisher -TenantId $TenantId -SiteUrl $SiteUrl -PortalClientId $PortalClientId -Connection $connection -AfterIngestion
    if ($report.OverviewRefresh.Outcome -eq 'Published') { $report.SharePointChanged=$true }
   } catch {
    throw "Report stored and verified. Overview refresh failed. Retry this reception to reconcile it. $($_.Exception.Message)"
   }
  }
  Write-Host ($(if($ManagedInventory){'=== MANAGED INVENTORY FOR SHARING ==='}elseif($StoreReport){'=== WORK W06D PARA COMPARTIR ==='}else{'=== WORK W06C PARA COMPARTIR ==='})) -ForegroundColor Magenta
  Write-Host ($report|ConvertTo-Json -Depth 8) -ForegroundColor Magenta
  return [pscustomobject]$report
 }
 $receiptName=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($TenantId.ToString()+'|'+$ListId.ToString()+'|'+$TargetRelativePath))))+'.json'
 $receiptPath=Join-Path $StateDirectory $receiptName;$already=$false
 if(Test-Path -LiteralPath $receiptPath){
  $prior=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
  if($prior.ManifestSha256 -cne $ExpectedManifestSha256 -or $prior.TargetRelativePath -cne $TargetRelativePath){throw 'Prior receiver receipt conflicts.'}
  $already=$true
 }
 $central=$null
 if($PublishAcceptance){$central=Get-WorkAcceptance}
 $result=[ordered]@{Test=if($PublishAcceptance){'W06B2-CentralAcceptance'}else{'W06A-PortalReceptionValidation'};Version='0.4.0';Outcome=if($PublishAcceptance){'Accepted'}else{'Validated'};AlreadyValidatedLocally=$already
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
 if($connection -and !$ReceiverConnection){Disconnect-PnPOnline -ErrorAction SilentlyContinue}
 if([IO.Directory]::Exists($temp)){
  if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($temp)) -cne $StateDirectory){throw 'Unsafe temporary download cleanup.'}
  [IO.Directory]::Delete($temp,$true)
 }
 $lock.Dispose()
}
