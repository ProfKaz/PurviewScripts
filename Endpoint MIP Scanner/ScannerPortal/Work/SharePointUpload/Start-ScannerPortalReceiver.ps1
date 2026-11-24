<#PSScriptInfo
.VERSION 0.1.0
.GUID cb5b26cc-fe13-42c3-bd04-300bcb57dc9e
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.0 Discover committed managed inventory runs, checkpoint discovery and retry pending reception.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$PortalClientId,
    [Parameter(Mandatory)][switch]$AcknowledgePublisherDenied,
    [string]$CertificateThumbprint,
    [switch]$Watch,
    [ValidateRange(15,86400)][int]$IntervalSeconds=60,
    [string]$StateDirectory=(Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/PortalReceiver')
)
$ErrorActionPreference='Stop'
if (!$AcknowledgePublisherDenied -or $SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or !$SiteUrl.IsDefaultPort) {
    throw 'Specify the dedicated portal site and confirm the endpoint publisher denial test.'
}
$site=$SiteUrl.AbsoluteUri.TrimEnd('/')
Import-Module PnP.PowerShell -RequiredVersion 3.2.0
$auth=@{Url=$site;Tenant=$TenantId;ClientId=$PortalClientId;ReturnConnection=$true}
if ($CertificateThumbprint) { $auth.Thumbprint=$CertificateThumbprint } else { $auth.Interactive=$true }
$conn=Connect-PnPOnline @auth
$lock=$null
function Save-Queue {
    $temp=$statePath+'.tmp'
    [IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Depth 6 -Compress))
    [IO.File]::Move($temp,$statePath,$true)
}
try {
    $web=Get-PnPWeb -Includes Url -Connection $conn
    if ($web.Url.TrimEnd('/') -ne $site) { throw 'Connected site differs from the target.' }
    $landing=Get-PnPList -Identity ScannerPortalLanding -Includes RootFolder,BaseTemplate -Connection $conn
    $ledger=Get-PnPList -Identity ScannerPortalAcceptance -Includes HasUniqueRoleAssignments -Connection $conn
    if ($landing.BaseTemplate -ne 101 -or !$ledger.HasUniqueRoleAssignments) { throw 'Unexpected landing or acceptance configuration.' }
    $root=$landing.RootFolder.ServerRelativeUrl.TrimEnd('/')
    $config=Get-PnPList -Identity ScannerPortalConfig -Includes RootFolder -Connection $conn
    $overview=Get-PnPFile -Url ($SiteUrl.AbsolutePath.TrimEnd('/')+'/ScannerPortalExecutive/overview.json') -AsString -Connection $conn | ConvertFrom-Json
    if ($overview.refreshAfterIngestion -ne $true) { throw 'Enable the dynamic overview before running the receiver.' }
    $dir=[IO.Directory]::CreateDirectory((Join-Path $StateDirectory "$TenantId/$($landing.Id)")).FullName
    $lock=[IO.File]::Open((Join-Path $dir 'discovery.lock'),'OpenOrCreate','ReadWrite','None')
    $statePath=Join-Path $dir 'queue.json'
    $state=if ([IO.File]::Exists($statePath)) {Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable} else {
        @{schema=1;site=$site;ledger=$ledger.Id.ToString();cursor=0;pending=@{}}
    }
    if ($state.schema -ne 1 -or $state.site -ne $site -or $state.ledger -ne $ledger.Id.ToString() -or
        $state.pending -isnot [Collections.IDictionary] -or $null -eq $state.cursor -or [int]$state.cursor -lt 0) {throw 'Invalid receiver checkpoint.'}
    if (![IO.File]::Exists($statePath)) {Save-Queue}
    $receiver=Join-Path $PSScriptRoot 'Test-WorkPortalReception.ps1'
    do {
        $discovered=0
        $stored=0
        $reused=0
        try {
            do {
                $cursor=[int]$state.cursor
                $query="<View Scope='RecursiveAll'><Query><Where><Gt><FieldRef Name='ID'/><Value Type='Counter'>$cursor</Value></Gt></Where><OrderBy><FieldRef Name='ID' Ascending='TRUE'/></OrderBy></Query><ViewFields><FieldRef Name='ID'/><FieldRef Name='FileRef'/><FieldRef Name='FSObjType'/></ViewFields><RowLimit>200</RowLimit></View>"
                $page=@(Get-PnPListItem -List $landing.Id -Query $query -Connection $conn)
                foreach ($item in $page) {
                    $path=[string]$item.FieldValues.FileRef
                    if ($item.Id -le $state.cursor) {throw 'Discovery returned an unordered item ID.'}
                    if ([int]$item.FieldValues.FSObjType -eq 0 -and $path.StartsWith($root+'/',[StringComparison]::OrdinalIgnoreCase)) {
                        $relative=$path.Substring($root.Length+1)
                        if ($relative -cmatch '^devices/([a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})/batches/([a-f0-9]{32})/manifest\.json$') {
                            $state.pending[$relative]=@{registration=$Matches[1];hash='';error=''}
                            $discovered++
                        }
                    }
                    $state.cursor=$item.Id
                }
                if ($page.Count) {Save-Queue}
            } while ($page.Count -ge 200)
            foreach ($path in @($state.pending.Keys)) {
                $job=$state.pending[$path]
                try {
                    $assignmentUrl=$config.RootFolder.ServerRelativeUrl.TrimEnd('/')+'/assignments/'+$job.registration+'.json'
                    $assignment=Get-PnPFile -Url $assignmentUrl -AsString -Connection $conn | ConvertFrom-Json
                    if ($assignment.schemaVersion -ne 1 -or $assignment.registrationId -ne $job.registration) {throw 'Invalid registration assignment.'}
                    if (!$job.hash) {
                        $meta=Get-PnPFile -Url "$root/$path" -AsListItem -Connection $conn
                        if (!$meta -or $null -eq $meta['File_x0020_Size'] -or [long]$meta['File_x0020_Size'] -gt 1MB) {throw 'Unexpected manifest size.'}
                        $stream=Get-PnPFile -Url "$root/$path" -AsMemoryStream -Connection $conn
                        try { $stream.Position=0; $job.hash=(Get-FileHash -InputStream $stream).Hash } finally { $stream.Dispose() }
                        Save-Queue
                    }
                    $argsForRun=@{SiteUrl=$SiteUrl; TenantId=$TenantId; PortalClientId=$PortalClientId; ListId=$landing.Id; AcceptanceListId=$ledger.Id
                        TargetRelativePath=$path.Substring(0,$path.LastIndexOf('/')); ExpectedManifestSha256=$job.hash; ReceiverConnection=$conn
                        ManagedInventory=$true; StoreReport=$true; AcknowledgePublisherDenied=$true; StateDirectory=(Join-Path $dir 'validation')}
                    $result=& $receiver @argsForRun
                    if (!$result.PortalIngestionConfirmed -or $result.OverviewRefresh.Outcome -notin 'Current','Published') {throw 'Report or overview not confirmed.'}
                    if ($result.Outcome -eq 'Stored') {$stored++} else {$reused++}
                    $state.pending.Remove($path)
                } catch {
                    $job.error=$_.Exception.Message
                    Write-Warning "Pending $path — $($job.error)"
                }
                Save-Queue
            }
            [pscustomobject]@{Test='ManagedReceiver';Discovered=$discovered;Stored=$stored;Reused=$reused;Pending=$state.pending.Count;Cursor=$state.cursor}
        } catch {
            if (!$Watch) {throw}
            # Reload the durable checkpoint before retrying a failed discovery or save.
            if (![IO.File]::Exists($statePath)) {throw}
            $state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            Write-Warning "Receiver pass failed: $($_.Exception.Message)"
        }
        if ($Watch) {Start-Sleep -Seconds $IntervalSeconds}
    } while ($Watch)
} finally {
    if ($lock) {$lock.Dispose()}
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}
