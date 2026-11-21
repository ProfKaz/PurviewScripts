<#PSScriptInfo
.VERSION 0.1.0
.GUID a84b3dbb-abce-40da-9fbf-c398f59568e8
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 W01 local read-only and output allowlist checks.
#>
<#
.DESCRIPTION
Local fixtures only. No Graph, enrollment or upload.
.NOTES
Version     : 0.1.0
Tracking ID : a84b3dbb-abce-40da-9fbf-c398f59568e8
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
$ErrorActionPreference='Stop'
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$fixture=Join-Path $env:TEMP ('WorkUploadInventory-'+[guid]::NewGuid().ToString('N'))
$outbox=Join-Path $fixture 'Pending'
$id='A'*64
$batch=Join-Path $outbox $id
[void][IO.Directory]::CreateDirectory($batch)
[void][IO.Directory]::CreateDirectory((Join-Path $fixture '.endpoint-install/controlplane'))
$tenant=[guid]::NewGuid().ToString();$client=[guid]::NewGuid().ToString()
$state=@{TenantId=$tenant;ClientId=$client;ClientSecret='DO-NOT-SHARE-SECRET';accessToken='DO-NOT-SHARE-TOKEN'}
$state|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $fixture '.endpoint-install/mip-app.json') -Encoding utf8
[IO.File]::WriteAllText((Join-Path $fixture '.endpoint-install/controlplane/controlplane.json'),'{corrupt DO-NOT-SHARE-CORRUPT')
@{schemaVersion=1;state='Sealed';batchId=$id}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $batch 'manifest.json') -Encoding utf8
[IO.File]::WriteAllText((Join-Path $batch 'records.jsonl'),'{"evidence":"do not modify"}')
$before=(Get-FileHash -LiteralPath (Join-Path $batch 'records.jsonl')).Hash
$standalone=Join-Path $fixture 'standalone'
[void][IO.Directory]::CreateDirectory($standalone)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Get-WorkUploadInventory.ps1') -Destination $standalone
$beforeFiles=@(Get-ChildItem -LiteralPath $fixture -Recurse -File).Count
try{
    $result=& (Join-Path $standalone 'Get-WorkUploadInventory.ps1') -InstallationDirectory $fixture -OutboxDirectory @($outbox,(Join-Path $fixture 'missing'))
    $json=$result|ConvertTo-Json -Depth 12
    Assert (-not($json.Contains('DO-NOT-SHARE'))) 'Non-allowlisted data leaked.'
    $app=@($result.Applications|Where-Object Role -eq 'MipDelegatedApp')[0]
    Assert ($app.ClientId -eq $client -and $app.TenantId -eq $tenant) 'Public IDs were not recovered.'
    Assert (@($result.Applications|Where-Object LocalState -eq 'Missing').Count -eq 1) 'Missing admin app was not explicit.'
    Assert ($result.Issues.Count -eq 1) 'Corrupt state did not produce a bounded diagnostic.'
    Assert ($result.Outboxes[0].PendingCount -eq 1 -and $result.Outboxes[1].PendingCount -eq 0) 'Pending inventory was incorrect.'
    Assert (-not $result.Outboxes[0].Batches[0].PayloadHashesVerified) 'Manifest inventory falsely claimed payload verification.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $batch 'records.jsonl')).Hash -eq $before) 'Payload changed.'
    Assert (@(Get-ChildItem -LiteralPath $fixture -Recurse -File).Count -eq $beforeFiles) 'Inventory wrote files.'
    'PASS: W01 public-ID allowlist, missing/corrupt state, pending manifest inventory and unchanged payload/files; no tenant calls'
}finally{
    $absolute=[IO.Path]::GetFullPath($fixture)
    if(-not $absolute.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup.'}
    [IO.Directory]::Delete($absolute,$true)
}
