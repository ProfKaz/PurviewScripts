<#PSScriptInfo
.VERSION 0.1.0
.GUID a3efe777-a548-4386-bdbb-f6626e8d512f
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
0.1.0 Provision a site-scoped receiver application, machine certificate and recurring startup task.
#>
#Requires -Version 7.4
#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][guid]$TenantId,[Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][switch]$GrantReceiverSiteFullControl,
    [Parameter(Mandatory)][switch]$AcknowledgePublisherDenied)
$ErrorActionPreference='Stop'
if (!$IsWindows -or ![Environment]::Is64BitProcess -or !$GrantReceiverSiteFullControl -or !$AcknowledgePublisherDenied -or
    $TenantId -eq [guid]::Empty -or $SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[a-z0-9_-]+/?$' -or $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or !$SiteUrl.IsDefaultPort) {
    throw 'Use elevated x64 PowerShell on the administrative host and specify the dedicated pilot site and both acknowledgments.'
}
$site=$SiteUrl.AbsoluteUri.TrimEnd('/')
$tag=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$TenantId|$($site.ToLowerInvariant())"))).Substring(0,16)
$base=Join-Path $env:ProgramFiles "Endpoint MIP Scanner Receiver/$tag"
$exe=Join-Path $env:ProgramFiles 'PowerShell/7/pwsh.exe'
if (!(Test-Path -LiteralPath $exe -PathType Leaf)) {throw 'Install machine-wide x64 PowerShell 7.4.6 or later before running setup.'}
$runtime=& $exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0 -or [version]$runtime -lt [version]'7.4.6') {throw 'The machine-wide PowerShell runtime must be at least 7.4.6.'}
$taskName="ScannerPortal-Receiver-$tag"
$description="Endpoint MIP Scanner receiver for $site ($TenantId)"
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and ($task.Description -ne $description -or $task.State -eq 'Running')) {throw 'A different or running task occupies this name. Retry between passes.'}
$service=[Security.Principal.SecurityIdentifier]::new('S-1-5-19')
$state=Join-Path $base 'state'
$metadata=Join-Path $base 'receiver.json'
function Write-AtomicJson($path,$value) {
    [IO.File]::WriteAllText("$path.new",($value|ConvertTo-Json -Depth 5))
    [IO.File]::Move("$path.new",$path,$true)
}
# Administrative configuration and code inherit Program Files permissions.
# Only the separate checkpoint/health directory is writable by LOCAL SERVICE.
[void][IO.Directory]::CreateDirectory($base)
$setupLock=[IO.File]::Open((Join-Path $base 'setup.lock'),'OpenOrCreate','ReadWrite','None')
try {
    $files=@{
        'Work/SharePointUpload/Start-ScannerPortalReceiver.ps1'='436709931086e3e53c0d193c76590c939f08dca7'
        'Work/SharePointUpload/Test-WorkPortalReception.ps1'='0533fc009ffc26802ba5d45f157de5a6fe41aa10'
        'Work/SharePointUpload/Read-ManagedInventoryProjection.ps1'='80d7a36bf2498a2d1af5fffd8328c0d8963d5658'
        'deployment/Publish-ScannerPortalOverview.ps1'='f8cbb9f5697f82efae98fa1733cc58ff02d6c9a2'
        'deployment/Invoke-ScannerPortalReceiverTask.ps1'='f377e5d4baf3dd60467645eb826eec7aa642a2c6'
    }
    $release='https://raw.githubusercontent.com/ProfKaz/PurviewScripts/d3e4a5062eb81752cfd1faeb0f971c8fa5530c80/Endpoint%20MIP%20Scanner/ScannerPortal'
    foreach ($relative in $files.Keys) {
        $target=Join-Path $base $relative
        [void][IO.Directory]::CreateDirectory((Split-Path $target))
        Invoke-WebRequest "$release/$relative" -OutFile "$target.new"
        $bytes=[IO.File]::ReadAllBytes("$target.new")
        $header=[Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header+$bytes)))
        if ($hash -ine $files[$relative]) {throw "Download integrity check failed for $relative."}
        Unblock-File -LiteralPath "$target.new"
        [IO.File]::Move("$target.new",$target,$true)
    }
    [void][IO.Directory]::CreateDirectory($state)
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in 'S-1-5-18','S-1-5-32-544','S-1-5-19') {
        $rights=if ($sid -eq $service.Value) {'Modify'} else {'FullControl'}
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,'ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $state -AclObject $acl
    $allUsersModule=Join-Path $env:ProgramFiles 'PowerShell/Modules/PnP.PowerShell/3.2.0/PnP.PowerShell.psd1'
    if (!(Test-Path -LiteralPath $allUsersModule)) {Install-Module PnP.PowerShell -RequiredVersion 3.2.0 -Scope AllUsers -Repository PSGallery -Force}
    if (!(Test-Path -LiteralPath $allUsersModule)) {throw 'PnP.PowerShell 3.2.0 must be installed for all users.'}
    if (!(Get-Module -ListAvailable Microsoft.Graph.Authentication)) {Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force}
    Import-Module Microsoft.Graph.Authentication
    $saved=if ([IO.File]::Exists($metadata)) {Get-Content -LiteralPath $metadata -Raw|ConvertFrom-Json}
    if ($saved -and ($saved.siteUrl -ne $site -or $saved.tenantId -ne "$TenantId")) {throw 'Saved host identity differs from setup target.'}
    $subject="CN=ScannerPortalReceiver-$tag"
    $cert=if ($saved) {Get-Item -LiteralPath "Cert:\LocalMachine\My\$($saved.thumbprint)"} else {
        $candidates=@(Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq $subject)
        if ($candidates.Count -gt 1) {throw 'Ambiguous machine certificates; review receiver certificate ownership.'}
        if ($candidates.Count) {$candidates[0]} else {
            New-SelfSignedCertificate -Subject $subject -CertStoreLocation Cert:\LocalMachine\My -KeyAlgorithm RSA -KeyLength 3072 -KeyUsage DigitalSignature -KeyExportPolicy NonExportable -Provider 'Microsoft Software Key Storage Provider' -NotAfter (Get-Date).AddYears(1)
        }
    }
    if (!$cert.HasPrivateKey -or $cert.Subject -ne $subject -or $cert.NotAfter -le (Get-Date)) {throw 'Receiver certificate is unavailable or expired.'}
    $rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    try {
        if ($rsa.Key.ExportPolicy -ne [Security.Cryptography.CngExportPolicies]::None) {throw 'Receiver requires a non-exportable CNG key.'}
        $keyPath=Join-Path $env:ProgramData "Microsoft/Crypto/Keys/$($rsa.Key.UniqueName)"
    } finally {$rsa.Dispose()}
    $keyAcl=Get-Acl -LiteralPath $keyPath
    $keyAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($service,'Read','Allow'))
    Set-Acl -LiteralPath $keyPath -AclObject $keyAcl
    $name="ScannerPortal Receiver $tag"
    Connect-MgGraph -TenantId $TenantId -Scopes Application.ReadWrite.All,AppRoleAssignment.ReadWrite.All,Sites.FullControl.All -ContextScope Process -NoWelcome
    try {
        if ((Get-MgContext).TenantId -ne "$TenantId") {throw 'Wrong Graph tenant.'}
        function Graph($path,$method='GET',$body) {
            $params=@{Method=$method;Uri="https://graph.microsoft.com/v1.0/$path";OutputType='Hashtable'}
            if ($null -ne $body) {$params.Body=$body|ConvertTo-Json -Depth 10 -Compress;$params.ContentType='application/json'}
            Invoke-MgGraphRequest @params
        }
        function Rows($path) {
            $page=Graph $path
            while ($true) {
                foreach ($row in $page.value) {$row}
                if (!$page['@odata.nextLink']) {break}
                $page=Invoke-MgGraphRequest -Method GET -Uri $page['@odata.nextLink'] -OutputType Hashtable
            }
        }
        $targetSite=Graph ("sites/"+$SiteUrl.Host+':'+$SiteUrl.AbsolutePath.TrimEnd('/'))
        if ($targetSite.webUrl.TrimEnd('/') -ne $site) {throw 'SharePoint site lookup mismatch.'}
        $resourceApp='00000003-0000-0ff1-ce00-000000000000'
        $resources=@(Rows "servicePrincipals?`$filter=appId eq '$resourceApp'&`$select=id,appRoles")
        $roles=@($resources[0].appRoles|Where-Object {$_.value -eq 'Sites.Selected' -and $_.isEnabled -and 'Application' -in $_.allowedMemberTypes})
        if ($resources.Count -ne 1 -or $roles.Count -ne 1) {throw 'Cannot resolve SharePoint Sites.Selected application role.'}
        $certId=[Convert]::ToBase64String($cert.GetCertHash())
        $apps=@(Rows "applications?`$filter=displayName eq '$name'&`$select=id,appId")
        if (!$apps.Count) {
            if ($saved) {throw 'Registered receiver application is missing.'}
            $app=Graph applications POST @{displayName=$name;signInAudience='AzureADMyOrg'
                requiredResourceAccess=@(@{resourceAppId=$resourceApp;resourceAccess=@(@{id=$roles[0].id;type='Role'})})
                keyCredentials=@(@{type='AsymmetricX509Cert';usage='Verify';key=[Convert]::ToBase64String($cert.RawData);customKeyIdentifier=$certId;endDateTime=$cert.NotAfter.ToUniversalTime().ToString('o')})}
        } elseif ($apps.Count -eq 1) {$app=$apps[0]} else {throw 'Ambiguous receiver registration.'}
        $app=Graph "applications/$($app.id)?`$select=id,appId,keyCredentials,passwordCredentials,requiredResourceAccess"
        if (($saved -and $saved.clientId -ne $app.appId) -or $app.keyCredentials.Count -ne 1 -or $app.keyCredentials[0].customKeyIdentifier -cne $certId -or $app.passwordCredentials.Count -or
            $app.requiredResourceAccess.Count -ne 1 -or $app.requiredResourceAccess[0].resourceAppId -ne $resourceApp -or $app.requiredResourceAccess[0].resourceAccess.Count -ne 1 -or
            $app.requiredResourceAccess[0].resourceAccess[0].id -ne $roles[0].id) {throw 'Receiver application credentials or requested permissions differ; inspect before continuing.'}
        $principals=@(Rows "servicePrincipals?`$filter=appId eq '$($app.appId)'")
        $sp=if ($principals.Count -eq 0) {Graph servicePrincipals POST @{appId=$app.appId}} else {$principals[0]}
        $assignments=@(Rows "servicePrincipals/$($sp.id)/appRoleAssignments")
        if (@($assignments|Where-Object {$_.resourceId -ne $resources[0].id -or $_.appRoleId -ne $roles[0].id}).Count) {throw 'Unexpected effective receiver app role.'}
        if (!$assignments.Count) {$null=Graph "servicePrincipals/$($sp.id)/appRoleAssignments" POST @{principalId=$sp.id;resourceId=$resources[0].id;appRoleId=$roles[0].id}}
        $permPath="sites/$($targetSite.id)/permissions"
        function ReceiverGrant {
            Rows $permPath | Where-Object {$app.appId -in @($_.grantedToIdentitiesV2.application.id) -or $app.appId -in @($_.grantedToIdentities.application.id) -or $_.grantedToV2.application.id -eq $app.appId}
        }
        $grants=@(ReceiverGrant)
        if (!$grants.Count) {
            $null=Graph $permPath POST @{roles=@('fullcontrol');grantedToIdentities=@(@{application=@{id=$app.appId;displayName=$name}})}
            $grants=@(ReceiverGrant)
        }
        if ($grants.Count -ne 1 -or $grants[0].roles.Count -ne 1 -or $grants[0].roles[0] -ne 'fullcontrol') {throw 'Site-scoped receiver grant could not be verified.'}
        Write-AtomicJson $metadata @{siteUrl=$site;tenantId="$TenantId";clientId=$app.appId;thumbprint=$cert.Thumbprint}
    } finally {Disconnect-MgGraph|Out-Null}
    $runner=Join-Path $base 'deployment/Invoke-ScannerPortalReceiverTask.ps1'
    $action=New-ScheduledTaskAction -Execute $exe -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "'+$runner+'"')
    $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 2)))
    $principal=New-ScheduledTaskPrincipal -UserId $service.Value -LogonType ServiceAccount -RunLevel Limited
    $options=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 8)
    $null=Register-ScheduledTask -TaskName $taskName -Description $description -Principal $principal -Action $action -Trigger $triggers -Settings $options -Force
    $installed=Get-ScheduledTask -TaskName $taskName
    if ($installed.Principal.LogonType -ne 'ServiceAccount' -or $installed.Principal.UserId -notin @($service.Value,$service.Translate([Security.Principal.NTAccount]).Value,'LOCAL SERVICE') -or
        $installed.Actions.Count -ne 1 -or $installed.Actions[0].Execute -ne $exe -or $installed.Triggers.Count -ne 2) {throw 'Scheduled task readback differs from setup.'}
    Start-ScheduledTask -TaskName $taskName
    [pscustomobject]@{Outcome='TaskRegistered';TaskName=$taskName;ReceiverClientId=$app.appId;CertificateExpires=$cert.NotAfter;RunAs='LOCAL SERVICE';Site=$site;StatusPath=(Join-Path $state 'status.json')}
} finally {$setupLock.Dispose()}
