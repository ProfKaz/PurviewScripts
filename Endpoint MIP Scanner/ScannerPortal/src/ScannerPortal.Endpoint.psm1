<#PSScriptInfo
.VERSION 1.1.0
.GUID a0bd04b9-f8bf-44bf-93d2-de2a27099420
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-25 1.1.0 Report fleet contact independently of scan findings.
2026-11-23 1.0.1 Managed checkpoint resumption across cycle log directories.
2026-11-20 1.0.0 Certificate enrollment, validated pull profiles and verified report delivery.
#>
<#
.DESCRIPTION
PS5.1 endpoint control-plane pilot. Application identity is shared, not per-device authorization.
.NOTES
Version     : 1.1.0
Tracking ID : a0bd04b9-f8bf-44bf-93d2-de2a27099420
#>
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Suite = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:Suite 'LocalMIPScanner.WinPS51/LocalMIPSharePoint.psm1') -Force
. (Join-Path $script:Suite 'LocalMIPScanner.WinPS51/WinPSCompatibility.ps1')

function Write-PortalJson($Value, [string]$Path, [switch]$Bom) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject (ConvertTo-PortalCanonicalValue $Value) -Depth 20), [Text.UTF8Encoding]::new([bool]$Bom))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Read-PortalJson([string]$Path) {
    ConvertFrom-WinPSJson -InputObject ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
}
function Assert-PortalKeys($Object, [string[]]$Keys) {
    if ($Object -isnot [Collections.IDictionary]) { throw 'Expected JSON object.' }
    foreach ($key in $Object.Keys) { if ($key -cnotin $Keys) { throw "Unsupported field: $key" } }
    foreach ($key in $Keys) { if (-not $Object.Contains($key)) { throw "Missing field: $key" } }
}
function Assert-PortalDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    for ($dir = [IO.DirectoryInfo]::new($full); $dir; $dir = $dir.Parent) {
        if ($dir.Exists -and ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse directory is not allowed.' }
    }
    return $full
}
function Assert-PortalBootstrap($Bootstrap) {
    Assert-PortalKeys $Bootstrap @('schemaVersion','tenantId','clientId','siteUrl','configDriveId','landingDriveId','sharedIdentity')
    if ($Bootstrap.schemaVersion -ne 1 -or $Bootstrap.sharedIdentity -isnot [bool] -or -not $Bootstrap.sharedIdentity) { throw 'Expected shared-identity bootstrap v1.' }
    foreach ($key in 'tenantId','clientId') { if ([guid]$Bootstrap[$key] -eq [guid]::Empty) { throw 'Invalid identity.' } }
    foreach ($key in 'configDriveId','landingDriveId') { if ($Bootstrap[$key] -notmatch '^[A-Za-z0-9_!.,-]{1,256}$') { throw 'Invalid drive ID.' } }
    $uri = [uri]$Bootstrap.siteUrl
    if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or $uri.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $uri.Query -or $uri.Fragment -or $uri.UserInfo -or -not $uri.IsDefaultPort) { throw 'Invalid portal site URL.' }
}
function Get-PortalDigest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

function New-PortalEnrollment {
    param([Parameter(Mandatory)][string]$BootstrapPath, [Parameter(Mandatory)][string]$Directory)
    $bootstrap = Read-PortalJson $BootstrapPath
    Assert-PortalBootstrap $bootstrap
    $Directory = Assert-PortalDirectory $Directory
    [void][IO.Directory]::CreateDirectory($Directory)
    $lock = [IO.File]::Open((Join-Path $Directory 'enrollment.lock'), 'OpenOrCreate','ReadWrite','None')
    try {
        $path = Join-Path $Directory 'registration.json'
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ([IO.File]::Exists($path)) {
            $state = Read-PortalJson $path
            if ($state.executionAccountSid -ne $sid -or $state.deviceName -ne $env:COMPUTERNAME) { throw 'Saved enrollment differs from account or computer.' }
            foreach ($key in $bootstrap.Keys) { if ($state.bootstrap[$key] -cne $bootstrap[$key]) { throw 'Saved bootstrap differs.' } }
            $cert = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $state.certificateThumbprint)
            if (-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date)) { throw 'Enrollment certificate requires renewal.' }
        } else {
            $id = [guid]::NewGuid().ToString()
            $cert = New-SelfSignedCertificate -Subject ('CN=EndpointMIPScanner-' + $id) -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy NonExportable -KeyUsage DigitalSignature -Provider 'Microsoft Software Key Storage Provider' -NotAfter (Get-Date).AddYears(1)
            $state = @{ schemaVersion=1; registrationId=$id; deviceName=$env:COMPUTERNAME; executionAccountSid=$sid
                certificateThumbprint=$cert.Thumbprint; bootstrap=$bootstrap }
            Write-PortalJson $state $path
        }
        $request = @{ schemaVersion=1; registrationId=$state.registrationId; deviceName=$state.deviceName
            tenantId=$bootstrap.tenantId; clientId=$bootstrap.clientId; certificate=[Convert]::ToBase64String($cert.RawData) }
        $requestPath = Join-Path $Directory 'enrollment-request.json'
        Write-PortalJson $request $requestPath
        [pscustomobject]@{ RegistrationPath=$path; RequestPath=$requestPath; RegistrationId=$state.registrationId; RequiresAdministratorApproval=$true; PrivateKeyExported=$false }
    } finally { $lock.Dispose() }
}
function Get-PortalToken($Registration) {
    if ($Registration.executionAccountSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $Registration.deviceName -ne $env:COMPUTERNAME) { throw 'Use the enrolled Windows account and computer.' }
    Get-PublisherAccessToken -Configuration ([pscustomobject]@{
        TenantId=$Registration.bootstrap.tenantId; ClientId=$Registration.bootstrap.clientId
        CertificateStoreLocation='CurrentUser'; ExecutionAccountSid=$Registration.executionAccountSid
        CertificateThumbprint=$Registration.certificateThumbprint
    })
}
function Get-PortalBytes([string]$Token, [string]$DriveId, [string]$Path, [long]$MaxBytes=64MB) {
    if ($Path -notmatch '^[A-Za-z0-9_./-]+$' -or $Path -match '(^|/)\.\.(/|$)') { throw 'Unsafe remote path.' }
    $item = Invoke-PublisherGraph -Token $Token -Uri "https://graph.microsoft.com/v1.0/drives/$DriveId/root:/${Path}"
    if ([long]$item.size -gt $MaxBytes) { throw 'Remote file exceeds pilot limit.' }
    $url = [uri]$item.'@microsoft.graph.downloadUrl'
    if ($url.Scheme -ne 'https' -or $url.UserInfo) { throw 'Invalid download URL.' }
    # Preauthenticated URL must never receive the Graph bearer token.
    $client = [Net.WebClient]::new()
    $inputStream=$null;$outputStream=[IO.MemoryStream]::new()
    try {
        $inputStream=$client.OpenRead($url)
        $buffer=[byte[]]::new(65536)
        while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){
            if($outputStream.Length+$read -gt $MaxBytes){throw 'Download exceeded the bounded file limit.'}
            $outputStream.Write($buffer,0,$read)
        }
        return ,($outputStream.ToArray())
    } finally { if($inputStream){$inputStream.Dispose()};$outputStream.Dispose();$client.Dispose() }
}
function Get-PortalRemoteJson([string]$Token,[string]$DriveId,[string]$Path) {
    $bytes = Get-PortalBytes $Token $DriveId $Path 1MB
    if ($bytes.Length -gt 1MB) { throw 'Configuration file exceeds 1 MiB.' }
    ConvertFrom-WinPSJson -InputObject ([Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xFEFF))
}

function Test-PortalProfile($Profile) {
    Assert-PortalKeys $Profile @('schemaVersion','profileId','version','expiresUtc','execution','files')
    if ($Profile.schemaVersion -ne 1 -or $Profile.profileId -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or $Profile.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Unsupported profile identity/version.' }
    $expires = [DateTimeOffset]::Parse($Profile.expiresUtc, [Globalization.CultureInfo]::InvariantCulture)
    if ($expires.Offset -ne [timespan]::Zero -or $expires -le [DateTimeOffset]::UtcNow) { throw 'Profile is expired or not UTC.' }
    Assert-PortalKeys $Profile.execution @('roots','auditContent','maxSeconds','idleSeconds','paused')
    $execution = $Profile.execution
    if ($execution.roots -isnot [array] -or $execution.roots.Count -lt 1 -or $execution.roots.Count -gt 32) { throw 'Expected 1-32 roots.' }
    foreach ($path in $execution.roots) {
        $expanded = [Environment]::ExpandEnvironmentVariables($path)
        if ($expanded -notmatch '^[A-Za-z]:[\\/]' -or $expanded.Substring(2).Contains(':')) { throw 'Roots must be local absolute drive paths.' }
    }
    foreach ($key in 'auditContent','paused') { if ($execution[$key] -isnot [bool]) { throw 'Expected execution boolean.' } }
    if ($execution.maxSeconds -isnot [long] -or $execution.maxSeconds -lt 1 -or $execution.maxSeconds -gt 3600 -or
        $execution.idleSeconds -isnot [long] -or $execution.idleSeconds -lt 30 -or $execution.idleSeconds -gt 86400) { throw 'Invalid execution budget.' }
    Assert-PortalKeys $Profile.files @('extensions.json','exclusions.json','performance.json','incremental.json','classifiers.json')
    Assert-PortalKeys $Profile.files['performance.json'] @('batchSize','pauseMilliseconds')
    Assert-PortalKeys $Profile.files['incremental.json'] @('enabled','rescanIntervalDays','detectModifiedFiles','detectDeletedFiles','forceFullScan','maxFileSizeMB','stateDirectory')
    Assert-PortalKeys $Profile.files['classifiers.json'] @('maxBytes','rules')
    foreach($rule in $Profile.files['classifiers.json'].rules){Assert-PortalKeys $rule @('id','pattern')}
    # Reuse the actual scanner validators before activating a generation.
    $test = Join-Path ([IO.Path]::GetTempPath()) ('PortalProfile-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($test)
    try {
        foreach ($name in $Profile.files.Keys) { Write-PortalJson $Profile.files[$name] (Join-Path $test $name) -Bom }
        $scannerPath=[IO.Path]::GetFullPath((Join-Path $script:Suite 'LocalMIPScanner.WinPS51/LocalMIPScanner.psm1'))
        $scanner = Get-Module LocalMIPScanner | Where-Object Path -eq $scannerPath
        if (-not $scanner) { $scanner=Import-Module $scannerPath -Force -PassThru }
        & $scanner { param($directory) $null=Get-InventoryConfig $directory; $null=Get-IncrementalSettings $directory; $null=Get-ContentAuditSettings $directory } $test
    } finally { [IO.Directory]::Delete($test,$true) }
    return $true
}
function Sync-PortalProfile {
    param($Registration, [string]$Directory, [string]$Token)
    $assignment = Get-PortalRemoteJson $Token $Registration.bootstrap.configDriveId ('assignments/' + $Registration.registrationId + '.json')
    Assert-PortalKeys $assignment @('schemaVersion','registrationId','profilePath','sha256')
    if ($assignment.schemaVersion -ne 1 -or $assignment.registrationId -ne $Registration.registrationId -or $assignment.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $assignment.profilePath -notmatch '^profiles/[a-z0-9-]+/\d+\.\d+\.\d+/[A-Fa-f0-9]{64}\.json$') { throw 'Invalid profile assignment.' }
    $bytes = Get-PortalBytes $Token $Registration.bootstrap.configDriveId $assignment.profilePath 1MB
    if ($bytes.Length -gt 1MB) { throw 'Profile exceeds 1 MiB.' }
    $digest = Get-WinPSSha256 $bytes
    if ($digest -ine $assignment.sha256) { throw 'Profile digest mismatch.' }
    $profile = ConvertFrom-WinPSJson ([Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xFEFF))
    $null = Test-PortalProfile $profile
    $versions = Join-Path $Directory 'profiles'
    [void][IO.Directory]::CreateDirectory($versions)
    $generation = Join-Path $versions $digest
    if (-not [IO.Directory]::Exists($generation)) {
        $temp = Join-Path $versions ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($temp)
        try {
            foreach ($name in $profile.files.Keys) { Write-PortalJson $profile.files[$name] (Join-Path $temp $name) -Bom }
            [IO.File]::WriteAllBytes((Join-Path $temp 'profile.json'),$bytes)
            [IO.Directory]::Move($temp,$generation)
        } finally { if ([IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp,$true) } }
    }
    $active = @{ sha256=$digest; profileId=$profile.profileId; version=$profile.version }
    Write-PortalJson $active (Join-Path $Directory 'active.json')
    [pscustomobject]@{ Profile=$profile; ConfigDirectory=$generation; Sha256=$digest; Source='Portal' }
}
function Get-PortalCachedProfile([string]$Directory) {
    $active = Read-PortalJson (Join-Path $Directory 'active.json')
    if ($active.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid cached profile reference.' }
    $generation = Join-Path (Join-Path $Directory 'profiles') $active.sha256
    $path = Join-Path $generation 'profile.json'
    if ((Get-PortalDigest $path) -ine $active.sha256) { throw 'Cached profile digest mismatch.' }
    $profile = Read-PortalJson $path
    $null = Test-PortalProfile $profile
    # Regenerate materialized JSON from the hash-verified source, not potentially partial files.
    foreach ($name in $profile.files.Keys) { Write-PortalJson $profile.files[$name] (Join-Path $generation $name) -Bom }
    [pscustomobject]@{ Profile=$profile; ConfigDirectory=$generation; Sha256=$active.sha256; Source='Cache' }
}
function ConvertTo-PortalCanonicalValue($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $result=[ordered]@{}
        foreach($key in @($Value.Keys|Sort-Object)) {$result[$key]=ConvertTo-PortalCanonicalValue $Value[$key]}
        return $result
    }
    if ($Value -is [array]) {return ,@(foreach($item in $Value){ConvertTo-PortalCanonicalValue $item})}
    return $Value
}
function Get-PortalScanParameters($Registration,$Profile,[string]$Directory) {
    $files=$Profile.Profile.files
    $suite=$script:Suite
    $exclusions=@($files['exclusions.json']) + @($Directory,$suite)
    Write-PortalJson $exclusions (Join-Path $Profile.ConfigDirectory 'exclusions.json') -Bom
    $incremental=@{}
    foreach($key in $files['incremental.json'].Keys){$incremental[$key]=$files['incremental.json'][$key]}
    $base=[Environment]::ExpandEnvironmentVariables($incremental.stateDirectory)
    $scope=@{roots=@(foreach($path in $Profile.Profile.execution.roots){[Environment]::ExpandEnvironmentVariables($path)})
        extensions=$files['extensions.json'];exclusions=@(foreach($path in $exclusions){[Environment]::ExpandEnvironmentVariables($path)})
        auditContent=$Profile.Profile.execution.auditContent;incremental=$incremental}
    if ($Profile.Profile.execution.auditContent) {$scope.classifiers=$files['classifiers.json']}
    $canonical=ConvertTo-Json -InputObject (ConvertTo-PortalCanonicalValue $scope) -Depth 20 -Compress
    $hash=Get-WinPSSha256 ([Text.Encoding]::UTF8.GetBytes($canonical))
    # A changed scope starts a separate resumable generation; an old journal is never discarded.
    $incremental.stateDirectory=Join-Path (Join-Path $base $Registration.registrationId) $hash
    Write-PortalJson $incremental (Join-Path $Profile.ConfigDirectory 'incremental.json') -Bom
    $logs=Join-Path $Directory 'logs'
    @{Root=@($Profile.Profile.execution.roots);ConfigDirectory=$Profile.ConfigDirectory;LogDirectory=$logs;LogScopeDirectory=$logs
        MaxSeconds=[int]$Profile.Profile.execution.maxSeconds;AuditContent=[bool]$Profile.Profile.execution.auditContent}
}

function New-PortalRunBatch($Registration, $Profile, $Summary, [string]$Directory) {
    $pending = Join-Path $Directory 'outbox/Pending'
    [void][IO.Directory]::CreateDirectory($pending)
    $id = $Summary.runId
    if($id -notmatch '^[a-f0-9]{32}$'){throw 'Expected deterministic scanner run ID.'}
    $final=Join-Path $pending $id
    if([IO.Directory]::Exists($final)){return $final}
    $uploaded=Join-Path (Join-Path $Directory 'outbox/Uploaded') $id
    if([IO.Directory]::Exists($uploaded)){return $uploaded}
    $temp = Join-Path $pending ('.' + $id + '-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    try {
    [IO.File]::Copy($Summary.logFile, (Join-Path $temp 'records.jsonl'))
    Write-PortalJson @{ schemaVersion=1; source='LocalMIPScanner.WinPS51'; summary=$Summary
        profileId=$Profile.Profile.profileId; profileVersion=$Profile.Profile.version; profileSha256=$Profile.Sha256
        profileSource=$Profile.Source; registrationId=$Registration.registrationId; deviceName=$Registration.deviceName
        tenantId=$Registration.bootstrap.tenantId; applicationId=$Registration.bootstrap.clientId
        executionAccountSid=$Registration.executionAccountSid; executionAccountName=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        actorAttribution='LocalScannerSelfReported'; authenticatedPrincipal='SharedApplication'
        contentAuditEngine='LocalRules'; contentAuditSupportedFormats=@('.txt','.csv') } (Join-Path $temp 'summary.json')
    $files = @(foreach ($name in 'records.jsonl','summary.json') {
        $path=Join-Path $temp $name
        if ((Get-Item -LiteralPath $path).Length -gt 64MB) { throw 'Report exceeds pilot per-file limit; retained locally.' }
        @{ name=$name; sha256=Get-PortalDigest $path; length=(Get-Item -LiteralPath $path).Length }
    })
    Write-PortalJson @{ schemaVersion=1; producerVersion='1.0.0'; contract='ScannerPortal.InventoryRun/1'; tenantId=$Registration.bootstrap.tenantId; batchId=$id
        registrationId=$Registration.registrationId; createdUtc=$Summary.startedUtc; files=$files } (Join-Path $temp 'manifest.json')
    [IO.Directory]::Move($temp,$final)
    return $final
    } finally {
        if([IO.Directory]::Exists($temp)) {
            $absolute=[IO.Path]::GetFullPath($temp)
            if(-not $absolute.StartsWith([IO.Path]::GetFullPath($pending).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe batch cleanup path.'}
            [IO.Directory]::Delete($absolute,$true)
        }
    }
}
function Restore-PortalRunBatches($Registration,[string]$Directory) {
    $logs=Join-Path $Directory 'logs'
    if(-not(Test-Path -LiteralPath $logs)){return}
    foreach($cycle in @(Get-ChildItem -LiteralPath $logs -Directory)) {
        $contextPath=Join-Path $cycle.FullName 'cycle.json'
        if(-not(Test-Path -LiteralPath $contextPath)){continue}
        $context=Read-PortalJson $contextPath
        foreach($log in @(Get-ChildItem -LiteralPath $cycle.FullName -Filter 'inventory-*.jsonl' -File)) {
            $id=[regex]::Match($log.Name,'^inventory-([a-f0-9]{32})\.jsonl$').Groups[1].Value
            if(-not $id){continue}
            if((Test-Path -LiteralPath (Join-Path $Directory ('outbox/Pending/'+$id))) -or
               (Test-Path -LiteralPath (Join-Path $Directory ('outbox/Uploaded/'+$id)))){continue}
            $summary=$null
            foreach($line in [IO.File]::ReadLines($log.FullName,[Text.Encoding]::UTF8)) {
                try {$record=ConvertFrom-WinPSJson $line;if($record.event -eq 'summary' -and $record.runId -eq $id){$summary=$record}}catch{}
            }
            if(-not $summary){$summary=@{event='summary';runId=$id;startedUtc=$context.startedUtc;interrupted=$true;generationComplete=$false;coverage='PartialInterruptedRun'}}
            $summary.logFile=$log.FullName
            $null=New-PortalRunBatch $Registration ([pscustomobject]$context.profile) ([pscustomobject]$summary) $Directory
        }
    }
}
function Send-PortalBatch($Registration, [string]$Token, [string]$BatchDirectory) {
    $manifest = Read-PortalJson (Join-Path $BatchDirectory 'manifest.json')
    if ($manifest.schemaVersion -ne 1 -or $manifest.contract -ne 'ScannerPortal.InventoryRun/1' -or
        $manifest.tenantId -ne $Registration.bootstrap.tenantId -or
        $manifest.batchId -notmatch '^[a-f0-9]{32}$' -or $manifest.registrationId -ne $Registration.registrationId -or
        @($manifest.files).Count -ne 2 -or @($manifest.files.name | Sort-Object -Unique).Count -ne 2) { throw 'Invalid run batch manifest.' }
    foreach ($file in $manifest.files) {
        if ($file.name -cnotin 'records.jsonl','summary.json' -or $file.length -gt 64MB -or
            (Get-PortalDigest (Join-Path $BatchDirectory $file.name)) -ine $file.sha256 -or
            (Get-Item -LiteralPath (Join-Path $BatchDirectory $file.name)).Length -ne $file.length) { throw 'Invalid local report content.' }
    }
    $drive = $Registration.bootstrap.landingDriveId
    $parent = (Invoke-PublisherGraph -Token $Token -Uri "https://graph.microsoft.com/v1.0/drives/$drive/root").id
    $prefix = 'devices/' + $Registration.registrationId + '/batches/' + $manifest.batchId
    foreach ($part in $prefix.Split('/')) { $parent = (Get-OrCreatePublisherFolder $Token $drive $parent $part).id }
    foreach ($name in @('records.jsonl','summary.json','manifest.json')) {
        $path = Join-Path $BatchDirectory $name
        # Verify existing content on retry. A conflicting same-ID batch is never overwritten.
        $exists=$true
        try { $remote = Get-PortalBytes $Token $drive ($prefix + '/' + $name) }
        catch { if ((Get-PublisherHttpStatus $_) -ne 404) { throw }; $exists=$false }
        if ($exists) {
            if ((Get-WinPSSha256 $remote) -ine (Get-PortalDigest $path)) { throw 'Remote same-ID report conflict.' }
        } else {
            $null=Invoke-PublisherGraph -Token $Token -Uri "https://graph.microsoft.com/v1.0/drives/$drive/items/${parent}:/${name}:/content" -Method PUT -Bytes ([IO.File]::ReadAllBytes($path))
            $remote=Get-PortalBytes $Token $drive ($prefix + '/' + $name)
            if ((Get-WinPSSha256 $remote) -ine (Get-PortalDigest $path)) { throw 'Remote report digest mismatch.' }
        }
    }
    # Delivery evidence is local verification, not a receipt from a trusted central processor.
    Write-PortalJson @{ deliveryState='UploadedVerified'; acceptedByCentralProcessor=$false; batchId=$manifest.batchId
        manifestSha256=Get-PortalDigest (Join-Path $BatchDirectory 'manifest.json'); verifiedUtc=[datetime]::UtcNow.ToString('o') } (Join-Path $BatchDirectory 'delivery.json')
    $sent = Join-Path (Split-Path -Parent (Split-Path -Parent $BatchDirectory)) 'Uploaded'
    [void][IO.Directory]::CreateDirectory($sent)
    [IO.Directory]::Move($BatchDirectory,(Join-Path $sent $manifest.batchId))
    [pscustomobject]@{ BatchId=$manifest.batchId; DeliveryState='UploadedVerified'; AcceptedByCentralProcessor=$false }
}
function Send-PortalHeartbeat($Registration, [string]$Token, $Profile, [string]$Directory, [string]$State) {
    $id = ([guid]$Registration.registrationId).ToString('D')
    $drive = $Registration.bootstrap.landingDriveId
    $suiteVersion = $null
    $installPath = Join-Path $script:Suite '.endpoint-install/status.json'
    if ([IO.File]::Exists($installPath)) {
        $install = Read-PortalJson $installPath
        if ($install.Status -eq 'Completed' -and $install.Stage -eq 'EndpointInstall') { $suiteVersion = $install.SuiteVersion }
    }
    $signal = [ordered]@{
        contract = 'ScannerPortal.Heartbeat/1'
        registrationId = $id
        computer = [Environment]::MachineName
        suiteVersion = $suiteVersion
        profileId = $Profile.Profile.profileId
        profileVersion = $Profile.Profile.version
        state = $State
    }
    $json = ConvertTo-Json -InputObject $signal -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $hash = Get-WinPSSha256 $bytes
    $cachePath = Join-Path $Directory 'last-heartbeat.json'
    if ([IO.File]::Exists($cachePath)) {
        try {
            $previous = Read-PortalJson $cachePath
            $age = [datetimeoffset]::UtcNow - [datetimeoffset]::Parse($previous.sentUtc)
            if ($previous.driveId -eq $drive -and $previous.sha256 -eq $hash -and $age.TotalHours -ge 0 -and $age.TotalHours -lt 4) { return 'Current' }
        } catch { Write-Verbose 'The heartbeat receipt will be refreshed.' }
    }
    $root = Invoke-PublisherGraph -Token $Token -Uri "https://graph.microsoft.com/v1.0/drives/$drive/root"
    $folder = Get-OrCreatePublisherFolder $Token $drive $root.id 'heartbeats'
    $uri = "https://graph.microsoft.com/v1.0/drives/$drive/items/$($folder.id):/$id.json:/content"
    $item = Invoke-PublisherGraph -Token $Token -Uri $uri -Method PUT -Bytes $bytes
    if ($item.name -ine "$id.json" -or $item.size -ne $bytes.Length) { throw 'Heartbeat write was not acknowledged.' }
    Write-PortalJson @{driveId=$drive;sha256=$hash;sentUtc=[datetimeoffset]::UtcNow.ToString('o')} $cachePath
    return 'Sent'
}

function Get-PortalHttpStatus($ErrorRecord) { Get-PublisherHttpStatus $ErrorRecord }
Export-ModuleMember -Function Send-PortalHeartbeat,New-PortalEnrollment,Test-PortalProfile,Sync-PortalProfile,Get-PortalCachedProfile,Get-PortalToken,New-PortalRunBatch,Send-PortalBatch,Read-PortalJson,Write-PortalJson,Assert-PortalBootstrap,Assert-PortalDirectory,Get-PortalHttpStatus,Get-PortalScanParameters,Restore-PortalRunBatches
