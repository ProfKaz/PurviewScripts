<#PSScriptInfo
.VERSION 0.1.1
.GUID 89818a36-b63a-42b7-9d02-fd38f819ae56
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.1 Exercise unordered and repeated IDs and interrupted server paging.
0.1.0 Exercise discovery checkpointing and independent retries with a local transport fixture.
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$dir=Join-Path $env:TEMP ('receiver-discovery-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
try {
    $site='https://test.sharepoint.com/sites/pilot'
    $device=[guid]::NewGuid().ToString()
    $bad=[guid]::NewGuid().ToString('N')
    $good=[guid]::NewGuid().ToString('N')
    $list=[guid]::NewGuid()
    $prefix='/sites/pilot/landing'
    $script:failFirst=$true
    $counters=@{reads=0}
    function Import-Module { param($Name,$RequiredVersion) }
    function Connect-PnPOnline { param($Url,$Tenant,$ClientId,[switch]$ReturnConnection,[switch]$Interactive) 'test' }
    function Disconnect-PnPOnline {}
    function Get-PnPWeb { param($Includes,$Connection) @{Url=$site} }
    function Get-PnPList { param($Identity,$Includes,$Connection) @{BaseTemplate=101;HasUniqueRoleAssignments=$true;Id=$list;RootFolder=@{ServerRelativeUrl=$prefix}} }
    function Get-PnPListItem {param($List,$Query,$Connection,$PageSize)
        if ($PageSize -ne 200) {throw 'Expected server paging.'}
        if ($Query -match "Type='Counter'>0<") {
            $paths=@("devices/$device/batches/$bad/summary.json","devices/$device/batches/$bad/manifest.json",
                "devices/$device/batches/$good/manifest.json",'work-pilot/probes/manifest.json')
            foreach($id in 4,2,2,1,3) {
                if ($id -eq 3 -and $failPaging) {throw 'Simulated page failure'}
                [pscustomobject]@{FieldValues=@{ID=[string]$id;FileRef="$prefix/$($paths[$id-1])";FSObjType=0}}
            }
        }
    }
    function Get-PnPFile {param($Url,$Connection,[switch]$AsListItem,[switch]$AsMemoryStream,[switch]$AsString)
        if ($AsListItem) {return @{File_x0020_Size=1}}
        if ($AsMemoryStream) {$counters.reads++;return ,([IO.MemoryStream]::new([byte[]]@(1)))}
        if ($Url.EndsWith('overview.json')) {return '{"refreshAfterIngestion":true}'}
        return (@{schemaVersion=1;registrationId=$device}|ConvertTo-Json)
    }
    $worker=Join-Path $dir 'Start-ScannerPortalReceiver.ps1'
    Copy-Item (Join-Path $PSScriptRoot '../Work/SharePointUpload/Start-ScannerPortalReceiver.ps1') $worker
    @'
param($TargetRelativePath,$ExpectedManifestSha256)
if ($TargetRelativePath.EndsWith($bad) -and $failFirst) {throw 'Simulated interruption'}
if ($ExpectedManifestSha256 -ne '4BF5122F344554C53BDE2EBB8CD2B7E3D1600AD631C385A5D7CCE23C7785459A') {throw 'Bad pin'}
@{Outcome='Reused';PortalIngestionConfirmed=$true;OverviewRefresh=@{Outcome='Current'}}
'@ | Set-Content (Join-Path $dir 'Test-WorkPortalReception.ps1')
    $params=@{SiteUrl=$site;TenantId=[guid]::NewGuid();PortalClientId=[guid]::NewGuid();AcknowledgePublisherDenied=$true;StateDirectory=$dir}
    $failPaging=$true
    try {& $worker @params; throw 'Expected paging failure'} catch {if ($_.Exception.Message -ne 'Simulated page failure') {throw}}
    $checkpoint=Get-Content -LiteralPath (Join-Path $dir "$($params.TenantId)/$list/queue.json") -Raw | ConvertFrom-Json -AsHashtable
    if ($checkpoint.cursor -ne 0 -or $checkpoint.pending.Count) {throw 'Partial discovery was checkpointed.'}
    $failPaging=$false
    $one=& $worker @params
    if ($one.Discovered -ne 2 -or $one.Reused -ne 1 -or $one.Pending -ne 1 -or $one.Cursor -ne 4) {throw 'Failed first discovery pass.'}
    $script:failFirst=$false
    $two=& $worker @params
    $three=& $worker @params
    if ($two.Discovered -ne 0 -or $two.Reused -ne 1 -or $two.Pending -ne 0 -or $three.Reused -ne 0 -or $counters.reads -ne 2) {throw 'Failed checkpoint recovery or duplicate suppression.'}
    'PASS: manifest discovery, partial folders, per-batch failure isolation, pinned retry, idle restart.'
} finally {
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($dir)) -eq [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
