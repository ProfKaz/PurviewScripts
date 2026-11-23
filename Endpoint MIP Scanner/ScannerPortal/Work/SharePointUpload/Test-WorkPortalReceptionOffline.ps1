<#PSScriptInfo
.VERSION 0.4.0
.GUID d8a2a089-3acf-437a-972a-621e62bc2fd6
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-21 0.2.0 Central acceptance lost-response/repeat, conflict and unsafe ACL tests.
2026-11-21 0.1.0 Mock PnP transport, real Windows PowerShell contract verifier, repeat and corruption tests.
#>
<#
.NOTES
Version     : 0.4.0
Tracking ID : d8a2a089-3acf-437a-972a-621e62bc2fd6
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('ReceiverTest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$global:ReceiverFixture=@{Directory=$fixture;Tenant=[guid]::NewGuid();List=[guid]::NewGuid();BadDownload=$false;Item=$null}
function Get-Module{param($ListAvailable,$Name) [pscustomobject]@{Version=[version]'3.2.0'}}
function Import-Module{param($Name,$RequiredVersion)}
function Connect-PnPOnline{param($Url,$Tenant,$ClientId,[switch]$Interactive,[switch]$ReturnConnection) 'fixture'}
function Disconnect-PnPOnline{param($ErrorAction)}
function Get-PnPWeb{param($Includes,$Connection) @{Url='https://example.sharepoint.com/sites/Pilot'}}
function Get-PnPList{param($Identity,$Includes,$Connection)
 if($Identity -eq $global:ReceiverFixture.AcceptanceList){return [pscustomobject]@{Id=$Identity;Title='ScannerPortalAcceptance';BaseTemplate=100;HasUniqueRoleAssignments=$true;RoleAssignments=@([pscustomobject]@{Member=[pscustomobject]@{LoginName=$(if($global:ReceiverFixture.BadAcl){'other'}else{'admin'})};RoleDefinitionBindings=@([pscustomobject]@{RoleTypeKind=5})})}}
 @{Id=$global:ReceiverFixture.List;Title='ScannerPortalLanding';BaseTemplate=101}}
function Get-PnPProperty{param($ClientObject,$Property,$Connection) if($Property -eq 'Member'){return $ClientObject.Member};if($Property -eq 'RootFolder'){@{ServerRelativeUrl='/sites/Pilot/ScannerPortalLanding'}}}
function Get-PnPFile{param($Url,[switch]$AsListItem,$Connection,$Path,$FileName,[switch]$AsFile)
 $name=($Url -split '/')[-1];$source=Join-Path $global:ReceiverFixture.Directory $name
 if($AsListItem){return @{File_x0020_Size=(Get-Item $source).Length}}
 [IO.File]::Copy($source,(Join-Path $Path $FileName))
 if($global:ReceiverFixture.BadDownload -and $name -eq 'records.jsonl'){[IO.File]::WriteAllText((Join-Path $Path $FileName),'corrupt')}
}
function Get-PnPSiteCollectionAdmin{param($Connection) @{LoginName='admin'}}
function Get-PnPField{param($List,$Identity,$Connection)
 if(-not $Identity -or $Identity -eq 'PortalReportJson'){if($global:ReceiverFixture.ReportField){[pscustomobject]$global:ReceiverFixture.ReportField};return}
 if($Identity -eq 'Title'){return @{Indexed=$true;EnforceUniqueValues=$true;Required=$true}}
 @{TypeAsString='Note';RichText=$false;AppendOnly=$false}
}
function Add-PnPField{param($List,$DisplayName,$InternalName,$Type,$Connection)
 $global:ReceiverFixture.ReportField=@{InternalName=$InternalName;TypeAsString=$Type;RichText=$false;AppendOnly=$false}
}
function Set-PnPListItem{param($List,$Identity,$Values,$Connection)
 $global:ReceiverFixture.Item.PortalReportJson=$Values.PortalReportJson
 $global:ReceiverFixture.ReportWrites++
}
function Get-PnPListItem{param($List,$Query,$Id,$Connection) if($global:ReceiverFixture.Item){$global:ReceiverFixture.Item}}
function Add-PnPListItem{param($List,$Values,$Connection)
 $global:ReceiverFixture.Creates++;$global:ReceiverFixture.Item=$Values.Clone();$global:ReceiverFixture.Item.Id=42
 if($global:ReceiverFixture.LostResponse){throw 'Response lost'}
 $global:ReceiverFixture.Item
}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
try{
 $module=(Resolve-Path (Join-Path $PSScriptRoot '../../../LocalMIPScanner.WinPS51/LocalMIPReporting.psm1')).Path
 $identity=[ordered]@{contract='LocalMIPReportBatch';consolidatorVersion='1.0.0';discoverySha256=('A'*64);retrySha256=('B'*64);inventorySha256=('C'*64)
 context=[ordered]@{tenantId=$global:ReceiverFixture.Tenant.ToString();accountObjectId=$null;deviceId=$null}}
 $batch=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($identity|ConvertTo-Json -Compress -Depth 6))))
 [IO.File]::WriteAllText((Join-Path $fixture 'records.jsonl'),'');[IO.File]::WriteAllText((Join-Path $fixture 'coverage.jsonl'),'')
 $summary=@{candidateFiles=0;respondedFiles=0;noResponseFiles=0;errorFiles=0;skippedFiles=0;filesWithFindings=0;coverageErrors=0;appliedRetryCount=0}
 $summary|ConvertTo-Json|Set-Content (Join-Path $fixture 'summary.json')
 $sit=[guid]::NewGuid().ToString()
 $records=@(
  @{extension='.txt';outcome='Responded';clientVersion='test';provenance=@{retry=$null};findings=@(@{sitId=$sit;name='Synthetic SIT';count=3})}
  @{extension='.txt';outcome='NoResponse';clientVersion='test';provenance=@{retry=$null};findings=@()}
 )
 [IO.File]::WriteAllLines((Join-Path $fixture 'records.jsonl'),[string[]]@($records|ForEach-Object {ConvertTo-Json -InputObject $_ -Compress -Depth 6}))
 $summary.candidateFiles=2;$summary.respondedFiles=1;$summary.noResponseFiles=1;$summary.filesWithFindings=1
 $summary|ConvertTo-Json|Set-Content (Join-Path $fixture 'summary.json')
 $payloads=@(foreach($name in 'records.jsonl','coverage.jsonl','summary.json'){@{name=$name;bytes=(Get-Item (Join-Path $fixture $name)).Length;sha256=(Get-FileHash (Join-Path $fixture $name)).Hash}})
 @{schemaVersion=1;state='Sealed';batchId=$batch;identity=$identity;payloads=$payloads}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $fixture 'manifest.json')
 $common=@{TenantId=$global:ReceiverFixture.Tenant;SiteUrl='https://example.sharepoint.com/sites/Pilot';PortalClientId=[guid]::NewGuid();ListId=$global:ReceiverFixture.List
 TargetRelativePath=('work-pilot/devices/'+('a'*32)+'/batches/'+$batch.ToLowerInvariant());ExpectedManifestSha256=(Get-FileHash (Join-Path $fixture 'manifest.json')).Hash
 VerificationModulePath=$module;StateDirectory=(Join-Path $fixture 'state')}
 $scriptPath=Join-Path $PSScriptRoot 'Test-WorkPortalReception.ps1'
 $first=& $scriptPath @common
 $again=& $scriptPath @common
 Assert ($first.Outcome -eq 'Validated' -and -not $first.AlreadyValidatedLocally -and $again.AlreadyValidatedLocally -and $first.FilesUploaded -eq 0 -and -not $first.CentralAcceptancePublished) 'Receiver validation/repeat status incorrect.'
 $global:ReceiverFixture.BadDownload=$true;$rejected=$false
 try{& $scriptPath @common|Out-Null}catch{$rejected=$true}
 Assert $rejected 'Corrupted payload accepted.'
 $global:ReceiverFixture.BadDownload=$false;$common.ExpectedManifestSha256=('F'*64);$rejected=$false
 try{& $scriptPath @common|Out-Null}catch{$rejected=$true}
 Assert $rejected 'Wrong original manifest accepted.'
 $common.ExpectedManifestSha256=(Get-FileHash (Join-Path $fixture 'manifest.json')).Hash
 $common.PublishAcceptance=$true;$common.AcceptanceListId=[guid]::NewGuid();$common.AcknowledgePublisherDenied=$true
 $global:ReceiverFixture.AcceptanceList=$common.AcceptanceListId;$global:ReceiverFixture.Creates=0;$global:ReceiverFixture.LostResponse=$true
 $accepted=& $scriptPath @common
 $repeat=& $scriptPath @common
 Assert ($accepted.Outcome -eq 'Accepted' -and $accepted.CentralAcceptancePublished -and $accepted.CentralAcceptance.CreateResponseUncertain -and $repeat.CentralAcceptance.AcceptanceItemId -eq 42 -and $global:ReceiverFixture.Creates -eq 1 -and -not $repeat.CentralAcceptance.AcceptanceCreatedThisRun) 'Acceptance lost-response recovery/repeat failed.'
 $common.Remove('PublishAcceptance')
 $common.ReportAcceptedBatch=$true
 $report=& $scriptPath @common
 Assert ($report.AcceptanceItemId -eq 42 -and $report.ByExtension[0].Files -eq 2 -and $report.ByOutcome.Count -eq 2 -and $report.BySit[0].Matches -eq 3 -and $report.BySit[0].Files -eq 1) 'Reporting totals incorrect.'
 $common.StoreReport=$true
 $stored=& $scriptPath @common
 $reused=& $scriptPath @common
 Assert ($stored.Outcome -eq 'Stored' -and $stored.PortalIngestionConfirmed -and $reused.Outcome -eq 'Reused' -and -not $reused.SharePointChanged -and $stored.ReportSha256 -eq $reused.ReportSha256 -and $global:ReceiverFixture.ReportWrites -eq 1) 'Stored report readback/reuse failed.'
 $global:ReceiverFixture.Item.PortalReportJson='{}'
 $rejected=$false;try{& $scriptPath @common|Out-Null}catch{$rejected=$true}
 Assert ($rejected -and $global:ReceiverFixture.ReportWrites -eq 1) 'Existing conflicting summary overwritten.'
 $common.Remove('StoreReport')
 $originalItem=$global:ReceiverFixture.Item
 $global:ReceiverFixture.Item=$null
 $rejected=$false;try{& $scriptPath @common|Out-Null}catch{$rejected=$true}
 Assert ($rejected -and $global:ReceiverFixture.Creates -eq 1) 'Reporting accepted or created a missing receipt.'
 $global:ReceiverFixture.Item=$originalItem
 $global:ReceiverFixture.Item.ManifestSha256=('F'*64);$rejected=$false
 try{& $scriptPath @common|Out-Null}catch{$rejected=$true};Assert $rejected 'Conflicting existing acceptance accepted.'
 $global:ReceiverFixture.Item.ManifestSha256=$common.ExpectedManifestSha256;$global:ReceiverFixture.BadAcl=$true;$rejected=$false
 try{& $scriptPath @common|Out-Null}catch{$rejected=$true};Assert $rejected 'Unsafe central ACL accepted.'
 Assert ($global:ReceiverFixture.Creates -eq 1) 'Conflict/ACL test rewrote acceptance.'
 Assert (@(Get-ChildItem (Join-Path $fixture 'state') -Directory -Filter 'download-*').Count -eq 0) 'Downloaded evidence left behind.'
 'PASS: mocked PnP download; actual PS5.1 identity/payload/summary verification; local dedup, corruption/hash rejection and cleanup; mocked acceptance create/readback, lost-response recovery, dedup, conflict and unsafe ACL rejection'
}finally{
 $safe=[IO.Path]::GetFullPath($fixture)
 if(-not $safe.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup.'}
 [IO.Directory]::Delete($safe,$true);Remove-Variable ReceiverFixture -Scope Global
}
