<#PSScriptInfo

.VERSION 1.0.0

.GUID 6fbce7f4-ce63-4e3b-b992-fc31301dca4d

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-20  1.0.0  Device-folder publisher registration and app-only permission preflight.
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: deployment/Initialize-ScannerPortalPublisher.ps1.
.NOTES
HISTORY
Version     : 1.0.0
Tracking ID : 6fbce7f4-ce63-4e3b-b992-fc31301dca4d
2026-11-20  Kaz Demos  Initial publisher preparation and permission verification.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid] $TenantId,
    [Parameter(Mandatory)][uri] $SiteUrl,
    [guid] $PortalClientId = [guid]::Empty,
    [guid] $PublisherClientId = [guid]::Empty,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [ValidateSet('Plan','Apply')][string] $Mode = 'Plan'
)
$ErrorActionPreference = 'Stop'
if ($TenantId -eq [guid]::Empty -or $SiteUrl.Scheme -ne 'https' -or
    $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or
    $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort) {
    throw 'Specify a tenant GUID and a commercial SharePoint /sites/ URL.'
}
$plan = [ordered]@{
    SiteUrl = $SiteUrl.AbsoluteUri.TrimEnd('/'); TenantId = $TenantId.ToString()
    Library = 'ScannerPortalLanding'; RuntimePermission = 'Files.SelectedOperations.Selected'
    Grant = 'write on one registered device folder'; Authentication = 'LocalMachine certificate'
    FolderPattern = 'devices/<shard>/<deviceId>/batches/<yyyy>/<MM>/<batchId>'
    PublishesRealBatch = $false; RequiresElevation = $true
}
if ($Mode -eq 'Plan') { [pscustomobject]$plan; return }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Publisher setup requires an elevated administrative console for the machine certificate.'
}
$suite = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $suite 'LocalMIPScanner.WinPS51/LocalMIPSharePoint.psm1') -Force
foreach ($module in 'Microsoft.Graph.Authentication','Microsoft.Graph.Applications') {
    if (-not (Get-Module -ListAvailable $module)) { Install-Module $module -Scope CurrentUser -Force -Repository PSGallery }
}
if (-not (Get-Module -ListAvailable PnP.PowerShell | Where-Object Version -eq ([version]'3.2.0'))) {
    Install-Module PnP.PowerShell -RequiredVersion 3.2.0 -Scope CurrentUser -Force -Repository PSGallery
}
Import-Module Microsoft.Graph.Authentication,Microsoft.Graph.Applications
Import-Module PnP.PowerShell -RequiredVersion 3.2.0

function Save-PublisherSetup($Value, [string] $Path) {
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $null) }
    else { [IO.File]::Move($temporary, $Path) }
}
function Invoke-SetupGraph([string] $Uri, [string] $Method = 'GET', $Body) {
    $parameters = @{ Uri = $Uri; Method = $Method; OutputType = 'Hashtable' }
    if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 12; $parameters.ContentType = 'application/json' }
    Invoke-MgGraphRequest @parameters
}
function Get-SetupPages([string] $Uri) {
    while ($Uri) {
        if (-not $Uri.StartsWith('https://graph.microsoft.com/v1.0/')) { throw 'Unexpected pagination host.' }
        $page = Invoke-SetupGraph $Uri
        foreach ($item in $page.value) { $item }
        $Uri = $page['@odata.nextLink']
    }
}
function Assert-RestrictedLanding($List, $Connection, [string] $AllowedAppId) {
    $unique = Get-PnPProperty -ClientObject $List -Property HasUniqueRoleAssignments -Connection $Connection
    if (-not $unique) { throw 'Landing inherits permissions. Review library access before enrolling a publisher.' }
    $admins = @(Get-PnPSiteCollectionAdmin -Connection $Connection | ForEach-Object { $_.LoginName.ToLowerInvariant() })
    $roles = Get-PnPProperty -ClientObject $List -Property RoleAssignments -Connection $Connection
    foreach ($assignment in $roles) {
        $member = Get-PnPProperty -ClientObject $assignment -Property Member -Connection $Connection
        $bindings = @(Get-PnPProperty -ClientObject $assignment -Property RoleDefinitionBindings -Connection $Connection)
        $substantive = @($bindings | Where-Object {
            [int](Get-PnPProperty -ClientObject $_ -Property RoleTypeKind -Connection $Connection) -ne 1
        })
        if ($substantive.Count -eq 0) { continue }
        if ($AllowedAppId -and $member.LoginName -match ('(^|\|)' + [regex]::Escape($AllowedAppId) + '@')) { continue }
        if ([string]$member.PrincipalType -eq 'SharePointGroup') {
            $members = @(Get-PnPGroupMember -Group $member.Id -Connection $Connection)
            foreach ($user in $members) {
                if ($user.LoginName.ToLowerInvariant() -notin $admins) { throw "Landing group includes a non-site-admin: $($member.Title)" }
            }
        } elseif ($member.LoginName.ToLowerInvariant() -notin $admins) {
            throw "Landing has a non-site-admin role assignment: $($member.Title)"
        }
    }
}

# The authoritative publisher configuration is kept outside the user-writable deployment.
$protected = Join-Path $env:ProgramData 'EndpointMIPScanner/Publisher'
for ($dir = [IO.DirectoryInfo]::new($protected); $dir; $dir = $dir.Parent) {
    if ($dir.Exists -and ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse publisher configuration path.' }
}
[void][IO.Directory]::CreateDirectory($protected)
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
    $identity = [Security.Principal.SecurityIdentifier]::new($sid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $protected -AclObject $acl
Set-Acl -LiteralPath (Split-Path -Parent $protected) -AclObject $acl
$configurationPath = Join-Path $protected 'publisher.json'
if ((Test-Path -LiteralPath $configurationPath) -and
    ((Get-Item -LiteralPath $configurationPath).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Reparse publisher configuration file.'
}
$state = if (Test-Path -LiteralPath $configurationPath) {
    Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json -AsHashtable
} else {
    @{ SchemaVersion = 1; TenantId = $TenantId.ToString(); SiteUrl = $plan.SiteUrl
        DeviceId = [guid]::NewGuid().ToString(); DeviceName = $env:COMPUTERNAME }
}
if ($state.TenantId -ne $TenantId.ToString() -or $state.SiteUrl -ne $plan.SiteUrl -or $state.DeviceName -ne $env:COMPUTERNAME) {
    throw 'Saved publisher registration does not match this tenant, site or computer.'
}
if ($PublisherClientId -ne [guid]::Empty -and $state.ClientId -and $state.ClientId -ne $PublisherClientId.ToString()) {
    throw 'Explicit publisher differs from the saved registration.'
}
if ($state.ClientId) { $PublisherClientId = [guid]$state.ClientId }
Save-PublisherSetup $state $configurationPath

$portalAppFile = Join-Path $EvidenceDirectory 'portal-app.json'
if ($PortalClientId -eq [guid]::Empty -and $state.PortalClientId) { $PortalClientId = [guid]$state.PortalClientId }
if ($PortalClientId -eq [guid]::Empty -and (Test-Path -LiteralPath $portalAppFile)) {
    $saved = Get-Content -LiteralPath $portalAppFile -Raw | ConvertFrom-Json
    if ($saved.TenantId -ne $TenantId.ToString()) { throw 'Portal setup app belongs to a different tenant.' }
    $PortalClientId = [guid]$saved.ClientId
}
$connection = $null
Connect-MgGraph -TenantId $TenantId -Scopes Application.ReadWrite.All,AppRoleAssignment.ReadWrite.All,Sites.FullControl.All -NoWelcome
try {
    if ((Get-MgContext).TenantId -ne $TenantId.ToString()) { throw 'Wrong Graph tenant.' }
    if ($PortalClientId -eq [guid]::Empty) {
        Get-MgApplication -Filter "startswith(displayName,'Kaz Demos Scanner Portal')" |
            Select-Object DisplayName, AppId | Format-Table | Out-Host
        $PortalClientId = [guid](Read-Host 'Existing ScannerPortal administrative app client ID')
    }
    if (@(Get-MgApplication -Filter "appId eq '$PortalClientId'").Count -ne 1) { throw 'Portal app is not owned by this tenant.' }
    $state.PortalClientId = $PortalClientId.ToString()
    Save-PublisherSetup $state $configurationPath
    $connection = Connect-PnPOnline -Url $plan.SiteUrl -ClientId $PortalClientId -Tenant $TenantId -Interactive -ReturnConnection
    $libraries = @(Get-PnPList -Includes HasUniqueRoleAssignments,RootFolder -Connection $connection |
        Where-Object Title -eq $plan.Library)
    if ($libraries.Count -ne 1 -or [int]$libraries[0].BaseTemplate -ne 101) { throw 'Expected one existing ScannerPortalLanding document library.' }
    Assert-RestrictedLanding $libraries[0] $connection
    Set-PnPList -Identity $libraries[0].Id -Hidden:$true -NoCrawl:$true -Connection $connection | Out-Null
    $checkedLibrary = Get-PnPList -Identity $libraries[0].Id -Includes Hidden,NoCrawl,HasUniqueRoleAssignments -Connection $connection
    if (-not ($checkedLibrary.Hidden -and $checkedLibrary.NoCrawl -and $checkedLibrary.HasUniqueRoleAssignments)) {
        throw 'Restricted library settings could not be verified.'
    }
    $state.LibraryAccessReviewedUtc = [datetime]::UtcNow.ToString('o')
    $site = Invoke-SetupGraph ("https://graph.microsoft.com/v1.0/sites/" + $SiteUrl.Host + ':' + $SiteUrl.AbsolutePath.TrimEnd('/'))
    $listId = $libraries[0].Id.ToString()
    $drive = Invoke-SetupGraph "https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$listId/drive"
    $root = Invoke-SetupGraph "https://graph.microsoft.com/v1.0/drives/$($drive.id)/root"

    if (-not $state.CertificateThumbprint) {
        $cert = New-SelfSignedCertificate -Subject ("CN=EndpointMIPScanner-" + $state.DeviceId) -CertStoreLocation Cert:\LocalMachine\My -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy NonExportable -KeyUsage DigitalSignature -Provider 'Microsoft Software Key Storage Provider' -NotAfter (Get-Date).AddYears(1)
        $state.CertificateThumbprint = $cert.Thumbprint
        Save-PublisherSetup $state $configurationPath
    }
    $cert = Get-Item -LiteralPath ("Cert:\LocalMachine\My\" + $state.CertificateThumbprint)
    if (-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date)) { throw 'Existing publisher certificate needs explicit renewal.' }
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    try { $keyPath = Join-Path $env:ProgramData ("Microsoft/Crypto/Keys/" + $rsa.Key.UniqueName) }
    finally { $rsa.Dispose() }
    $keyAcl = [Security.AccessControl.FileSecurity]::new()
    $keyAcl.SetAccessRuleProtection($true,$false)
    foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
        $keyAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))
    }
    Set-Acl -LiteralPath $keyPath -AclObject $keyAcl

    $graph = @(Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'")[0]
    $role = @($graph.AppRoles | Where-Object { $_.Value -eq 'Files.SelectedOperations.Selected' -and $_.IsEnabled -and 'Application' -in $_.AllowedMemberTypes })
    if ($role.Count -ne 1) { throw 'Selected folder application role unavailable.' }
    $name = 'Kaz Demos Endpoint Publisher ' + $state.DeviceId
    if ($PublisherClientId -eq [guid]::Empty) {
        if (@(Get-MgApplication -Filter "displayName eq '$name'").Count) { throw 'Publisher app exists; supply its explicit ID to reuse it.' }
        $created = New-MgApplication -DisplayName $name -SignInAudience AzureADMyOrg
        $PublisherClientId = [guid]$created.AppId
        $state.ClientId = $created.AppId
        Save-PublisherSetup $state $configurationPath
    }
    $apps = @(Get-MgApplication -Filter "appId eq '$PublisherClientId'" -Property Id,AppId,DisplayName,KeyCredentials,RequiredResourceAccess)
    if ($apps.Count -ne 1 -or $apps[0].DisplayName -ne $name) { throw 'Use the dedicated publisher application for this device.' }
    $app = $apps[0]
    $credentials = @($app.KeyCredentials | Where-Object { $null -ne $_ })
    if (-not @($credentials | Where-Object { $_.CustomKeyIdentifier -and [Convert]::ToBase64String($_.CustomKeyIdentifier) -eq [Convert]::ToBase64String($cert.GetCertHash()) }).Count) {
        $credentials += @{ Type = 'AsymmetricX509Cert'; Usage = 'Verify'; Key = $cert.RawData; DisplayName = 'Device publisher'; StartDateTime = $cert.NotBefore.ToUniversalTime(); EndDateTime = $cert.NotAfter.ToUniversalTime() }
    }
    $required = @(@{ ResourceAppId = $graph.AppId; ResourceAccess = @(@{ Id = $role[0].Id; Type = 'Role' }) })
    if (@($app.RequiredResourceAccess | Where-Object { $_.ResourceAppId -ne $graph.AppId -or @($_.ResourceAccess | Where-Object { $_.Id -ne $role[0].Id }).Count }).Count) {
        throw 'Publisher has additional API permissions. Review them before enrollment.'
    }
    Update-MgApplication -ApplicationId $app.Id -KeyCredentials $credentials -RequiredResourceAccess $required
    $principals = @(Get-MgServicePrincipal -Filter "appId eq '$PublisherClientId'")
    if ($principals.Count -eq 0) { $principals = @(New-MgServicePrincipal -AppId $PublisherClientId) }
    $sp = $principals[0]
    $assigned = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All)
    if (@($assigned | Where-Object { $_.ResourceId -ne $graph.Id -or $_.AppRoleId -ne $role[0].Id }).Count) { throw 'Publisher has unexpected effective API grants.' }
    if (-not @($assigned | Where-Object AppRoleId -eq $role[0].Id).Count) {
        $null = New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graph.Id -AppRoleId $role[0].Id
    }
    $logo = Join-Path $suite 'labs/MipSdkAudit/kaz-demos-entra-215.png'
    $logoHash = (Get-FileHash -LiteralPath $logo -Algorithm SHA256).Hash
    if ($state.LogoSha256 -ne $logoHash) { Set-MgApplicationLogo -ApplicationId $app.Id -InFile $logo }
    $state.LogoSha256 = $logoHash
    $state.AppObjectId = $app.Id; $state.ServicePrincipalId = $sp.Id
    Save-PublisherSetup $state $configurationPath

    # Folder preparation uses the delegated Graph session. Persist only public IDs.
    $parts = @('devices', $state.DeviceId.Replace('-','').Substring(0,2), $state.DeviceId)
    $parent = $root
    foreach ($part in $parts) {
        $uri = "https://graph.microsoft.com/v1.0/drives/$($drive.id)/items/$($parent.id):/$part"
        try { $child = Invoke-SetupGraph $uri }
        catch {
            if ((Get-PublisherHttpStatus $_) -ne 404) { throw }
            $child = Invoke-SetupGraph "https://graph.microsoft.com/v1.0/drives/$($drive.id)/items/$($parent.id)/children" POST @{ name = $part; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' }
        }
        if ($null -eq $child.folder) { throw 'Expected folder in publisher path.' }
        $parent = $child
    }
    $deviceFolder = $parent
    $listItem = Invoke-SetupGraph "https://graph.microsoft.com/v1.0/drives/$($drive.id)/items/$($deviceFolder.id)/listItem"
    $permissionUri = "https://graph.microsoft.com/v1.0/sites/$($site.id)/lists/$listId/items/$($listItem.id)/permissions"
    $permissions = @(Get-SetupPages $permissionUri)
    $grant = @($permissions | Where-Object { $_.grantedToV2.application.id -eq $PublisherClientId.ToString() })
    if ($grant.Count -eq 0) {
        $grant = @(Invoke-SetupGraph $permissionUri POST @{ grantedToV2 = @{ application = @{ id = $PublisherClientId.ToString(); displayName = $name } }; roles = @('write') })
    }
    if ($grant.Count -ne 1 -or @($grant[0].roles).Count -ne 1 -or $grant[0].roles[0] -ne 'write') { throw 'Unexpected device folder grant.' }
    $folderAcl = Get-PnPListItem -List $listId -Id ([int]$listItem.id) -Connection $connection
    Assert-RestrictedLanding $folderAcl $connection $PublisherClientId.ToString()

    $isolationUri = "https://graph.microsoft.com/v1.0/drives/$($drive.id)/items/$($root.id):/_permission-control"
    try { $isolation = Invoke-SetupGraph $isolationUri }
    catch {
        if ((Get-PublisherHttpStatus $_) -ne 404) { throw }
        $isolation = Invoke-SetupGraph "https://graph.microsoft.com/v1.0/drives/$($drive.id)/items/$($root.id)/children" POST @{ name = '_permission-control'; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' }
    }
    $state.SiteId = $site.id; $state.ListId = $listId; $state.DriveId = $drive.id
    $state.Library = $plan.Library; $state.DeviceFolderId = $deviceFolder.id
    $state.DeviceFolderPath = $parts -join '/'; $state.IsolationFolderId = $isolation.id
    $state.SelectedPermissionId = $grant[0].id; $state.ConfigurationPath = $configurationPath
    Save-PublisherSetup $state $configurationPath
    Save-PublisherSetup @{ ConfigurationPath = $configurationPath; DeviceId = $state.DeviceId; SiteUrl = $state.SiteUrl } (Join-Path $EvidenceDirectory 'publisher-pointer.json')

    $result = Test-LocalMIPPublisher ([pscustomobject]$state)
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $EvidenceDirectory 'publisher-preflight.json') -Encoding utf8
    Write-Host '=== PUBLICADOR SHAREPOINT PARA COMPARTIR ===' -ForegroundColor Magenta
    Write-Host ($result | ConvertTo-Json -Depth 6) -ForegroundColor Magenta
    $result
} finally {
    if ($connection) { Disconnect-PnPOnline -ErrorAction SilentlyContinue }
    Disconnect-MgGraph | Out-Null
}
