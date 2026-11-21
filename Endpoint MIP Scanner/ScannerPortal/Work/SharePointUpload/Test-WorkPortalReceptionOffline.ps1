<#PSScriptInfo
.VERSION 0.1.0
.GUID d8a2a089-3acf-437a-972a-621e62bc2fd6
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-21 0.1.0 Mock PnP transport, real Windows PowerShell contract verifier, repeat and corruption tests.
#>
<#
.NOTES
Version     : 0.1.0
Tracking ID : d8a2a089-3acf-437a-972a-621e62bc2fd6
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('ReceiverTest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$global:ReceiverFixture=@{Directory=$fixture;Tenant=[guid]::NewGuid();List=[guid]::NewGuid();BadDownload=$false}
function Get-Module{param($ListAvailable,$Name) [pscustomobject]@{Version=[version]'3.2.0'}}
function Import-Module{param($Name,$RequiredVersion)}
function Connect-PnPOnline{param($Url,$Tenant,$ClientId,[switch]$Interactive,[switch]$ReturnConnection) 'fixture'}
function Disconnect-PnPOnline{param($ErrorAction)}
function Get-PnPWeb{param($Includes,$Connection) @{Url='https://example.sharepoint.com/sites/Pilot'}}
function Get-PnPList{param($Identity,$Includes,$Connection) @{Id=$global:ReceiverFixture.List;Title='ScannerPortalLanding';BaseTemplate=101}}
function Get-PnPProperty{param($ClientObject,$Property,$Connection) if($Property -eq 'RootFolder'){@{ServerRelativeUrl='/sites/Pilot/ScannerPortalLanding'}}}
function Get-PnPFile{param($Url,[switch]$AsListItem,$Connection,$Path,$FileName,[switch]$AsFile)
 $name=($Url -split '/')[-1];$source=Join-Path $global:ReceiverFixture.Directory $name
 if($AsListItem){return @{File_x0020_Size=(Get-Item $source).Length}}
 [IO.File]::Copy($source,(Join-Path $Path $FileName))
 if($global:ReceiverFixture.BadDownload -and $name -eq 'records.jsonl'){[IO.File]::WriteAllText((Join-Path $Path $FileName),'corrupt')}
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
 Assert (@(Get-ChildItem (Join-Path $fixture 'state') -Directory -Filter 'download-*').Count -eq 0) 'Downloaded evidence left behind.'
 'PASS: mocked PnP download; actual PS5.1 identity/payload/summary verification; local dedup, corruption/hash rejection and cleanup; no remote writes'
}finally{
 $safe=[IO.Path]::GetFullPath($fixture)
 if(-not $safe.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup.'}
 [IO.Directory]::Delete($safe,$true);Remove-Variable ReceiverFixture -Scope Global
}
