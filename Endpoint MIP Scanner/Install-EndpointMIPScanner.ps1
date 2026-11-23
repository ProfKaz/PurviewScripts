<#PSScriptInfo

.VERSION 1.4.1

.GUID 0576cc7a-692e-4876-bfe5-d1fb62a30116

.AUTHOR Kaz Demos / ProfKaz

.COMPANYNAME Kaz Demos

.PROJECTURI https://github.com/ProfKaz/PurviewScripts

.RELEASENOTES
2026-11-23  1.4.1  Preserve the existing pilot Landing publisher during control plane setup.
2026-11-23  1.4.0  Program Files installation and user-context endpoint configuration.
2026-11-20  1.3.0  Portal control plane and managed endpoint enrollment stages.
2026-11-20  1.2.1  CurrentUser publisher credentials without local elevation.
2026-11-20  1.2.0  Add Publisher stage for an existing portal site.
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: 0576cc7a-692e-4876-bfe5-d1fb62a30116
#>

<#
.DESCRIPTION
Endpoint MIP Scanner component: Install-EndpointMIPScanner.ps1.
.NOTES
HISTORY
Script      : Install-EndpointMIPScanner.ps1
Version     : 1.4.1
Tracking ID : 0576cc7a-692e-4876-bfe5-d1fb62a30116
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._/-]+$')][string] $Ref = 'main',
    [string] $Destination,
    [ValidateSet('Download','Local','MipApp','Portal','Publisher','ControlPlane','ManagedEndpoint','EndpointInstall','EndpointConfigure','All')][string] $Stage = 'Local',
    [string] $DotNetPath,
    [guid] $TenantId = [guid]::Empty,
    [guid] $MipClientId = [guid]::Empty,
    [guid] $PortalClientId = [guid]::Empty,
    [guid] $PublisherClientId = [guid]::Empty,
    [guid] $ControlPlaneClientId = [guid]::Empty,
    [string] $AdminUrl,
    [string] $SiteUrl,
    [string] $Owner,
    [switch] $ResumeFoundation,
    [ValidateSet('Initialize','Approve','Publish')][string] $ControlPlaneAction = 'Initialize',
    [string] $ControlPlaneStateDirectory,
    [string] $BootstrapPath,
    [string] $EnrollmentRequest,
    [string] $ProfilePath,
    [guid] $RegistrationId = [guid]::Empty,
    [string] $EndpointDirectory,
    [switch] $AllowSharedIngress,
    [switch] $RegisterTask,
    [switch] $SyncOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Use Windows PowerShell 5.1 x64.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if ($SyncOnly -and $Stage -ne 'EndpointConfigure') { throw 'SyncOnly requires EndpointConfigure.' }
if ($Stage -in 'EndpointInstall','EndpointConfigure') {
    if ($Destination) { throw 'Endpoint installation and configuration use the system Program Files directory.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($Stage -eq 'EndpointInstall' -and -not $elevated) {
        throw 'Run EndpointInstall once in an elevated Windows PowerShell 5.1 x64 session.'
    }
    if ($Stage -eq 'EndpointConfigure' -and $elevated) {
        throw 'Run EndpointConfigure in a non-elevated session as the enrolled scanner user.'
    }
    $Destination = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Endpoint MIP Scanner'
}
if (-not $Destination) { $Destination = $PSScriptRoot }
$root = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) { throw 'Choose a project directory, not a drive root.' }
$work = Join-Path $root '.endpoint-install'
$machineBootstrap = Join-Path $work 'endpoint-bootstrap.json'
function Assert-InstallPath([string] $Path) {
    for ($parent = [IO.DirectoryInfo]::new($Path); $parent; $parent = $parent.Parent) {
        if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse directory in installation path: $($parent.FullName)"
        }
    }
}


function Get-BlobHash([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hash = [Security.Cryptography.SHA1]::Create()
    try {
        $prefix = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)" + [char]0)
        $payload = New-Object byte[] ($prefix.Length + $bytes.Length)
        [Array]::Copy($prefix, 0, $payload, 0, $prefix.Length)
        [Array]::Copy($bytes, 0, $payload, $prefix.Length, $bytes.Length)
        [BitConverter]::ToString($hash.ComputeHash($payload)).Replace('-', '').ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Write-SetupJson([string] $Path, $Value) {
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Invoke-ChildScript([string] $Executable, [string] $Script, [hashtable] $Parameters) {
    $arguments = @('-NoProfile','-File', $Script)
    foreach ($key in $Parameters.Keys) {
        if ($Parameters[$key] -is [switch] -or $Parameters[$key] -is [bool]) {
            if ($Parameters[$key]) { $arguments += "-$key" }
        } else { $arguments += "-$key"; $arguments += [string]$Parameters[$key] }
    }
    & $Executable @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Step failed ($LASTEXITCODE): $Script" }
}

function Install-VisualCpp {
    $runtime = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
    if ($runtime -and $runtime.Installed -eq 1) { return }
    $package = Join-Path $work 'vc_redist.x64.exe'
    Invoke-WebRequest -UseBasicParsing 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $package
    $signature = Get-AuthenticodeSignature -LiteralPath $package
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw 'Visual C++ package signature validation failed.'
    }
    $state.VisualCppPackageSha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    $process = Start-Process -FilePath $package -ArgumentList '/install','/passive','/norestart' -PassThru -Wait -WindowStyle Hidden
    if ($process.ExitCode -notin 0,3010) { throw "Visual C++ install failed: $($process.ExitCode)" }
    $state.RestartRequired = $process.ExitCode -eq 3010
}

function Install-AdministrativePowerShell {
    $directory = Join-Path $work 'powershell-7.6.0'
    $executable = Join-Path $directory 'pwsh.exe'
    if ([IO.File]::Exists($executable)) {
        $version = & $executable -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        if ($LASTEXITCODE -ne 0 -or $version -ne '7.6.0') { throw 'Administrative PowerShell is unusable.' }
        return $executable
    }
    $release = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.0'
    $name = 'PowerShell-7.6.0-win-x64.zip'
    $hashFile = Join-Path $work 'powershell-hashes.sha256'
    $archive = Join-Path $work $name
    Invoke-WebRequest -UseBasicParsing "$release/hashes.sha256" -OutFile $hashFile
    $line = @(Get-Content -LiteralPath $hashFile | Where-Object { $_ -match ("\s\*?" + [regex]::Escape($name) + '$') })
    if ($line.Count -ne 1 -or $line[0] -notmatch '^([A-Fa-f0-9]{64})\s') { throw 'Invalid PowerShell release hashes.' }
    $expected = $Matches[1]
    Invoke-WebRequest -UseBasicParsing "$release/$name" -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expected) {
        throw 'Administrative PowerShell SHA256 mismatch.'
    }
    $temporary = Join-Path $work ('pwsh-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $archive -DestinationPath $temporary
    [IO.Directory]::Move($temporary, $directory)
    & $executable -NoProfile -Command 'exit 0'
    if ($LASTEXITCODE -ne 0) { throw 'Downloaded administrative PowerShell failed to start.' }
    return $executable
}

if ($Stage -eq 'EndpointConfigure') {
    Assert-InstallPath $work
    $manifestPath = Join-Path $work 'files.json'
    $statusPath = Join-Path $work 'status.json'
    if (-not [IO.File]::Exists($manifestPath) -or -not [IO.File]::Exists($statusPath)) {
        throw 'Run EndpointInstall before configuring this Windows user.'
    }
    $installed = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $verified = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($installed.Status -ne 'Completed' -or $installed.Stage -ne 'EndpointInstall' -or
        $installed.Commit -ne $verified.Commit -or -not $verified.Files.Count) {
        throw 'Machine installation is incomplete. Rerun EndpointInstall.'
    }
    foreach ($entry in $verified.Files) {
        $path = [IO.Path]::GetFullPath((Join-Path $root $entry.Path))
        if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid installed manifest path.' }
        Assert-InstallPath ([IO.Path]::GetDirectoryName($path))
        if (-not [IO.File]::Exists($path) -or ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -or
            (Get-BlobHash $path) -ne $entry.GitBlobSha1) {
            throw "Installed component is missing or differs: $($entry.Path). Rerun EndpointInstall."
        }
    }

    Import-Module (Join-Path $root 'ScannerPortal/src/ScannerPortal.Endpoint.psm1') -Force
    if (-not $EndpointDirectory) { $EndpointDirectory = Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/ManagedEndpoint' }
    $EndpointDirectory = Assert-PortalDirectory $EndpointDirectory
    $registration = Join-Path $EndpointDirectory 'registration.json'
    if (-not $SiteUrl) { $SiteUrl = (Read-Host 'SharePoint portal site URL').Trim() }
    if (-not $SiteUrl) { throw 'Enter the SharePoint portal site URL.' }

    if (-not $BootstrapPath -and [IO.File]::Exists($machineBootstrap)) { $BootstrapPath = $machineBootstrap }
    if ($BootstrapPath) {
        $bootstrap = Read-PortalJson $BootstrapPath
    } elseif ([IO.File]::Exists($registration)) {
        $bootstrap = (Read-PortalJson $registration).bootstrap
    } else {
        $BootstrapPath = (Read-Host 'Path to endpoint-bootstrap.json from the portal administrator').Trim().Trim('"')
        if (-not $BootstrapPath) { throw 'An administrator-provided endpoint-bootstrap.json is required for first enrollment.' }
        $bootstrap = Read-PortalJson $BootstrapPath
    }
    Assert-PortalBootstrap $bootstrap
    if (([uri]$SiteUrl).AbsoluteUri.TrimEnd('/') -ne ([uri]$bootstrap.siteUrl).AbsoluteUri.TrimEnd('/')) {
        throw 'The requested portal URL differs from the enrollment bootstrap.'
    }

    if (-not [IO.File]::Exists($registration)) {
        if ($SyncOnly -or $RegisterTask) { throw 'Enroll this Windows user and obtain portal approval before synchronizing or registering the task.' }
        & (Join-Path $root 'ScannerPortal/deployment/Install-ScannerPortalEndpoint.ps1') -BootstrapPath $BootstrapPath -Directory $EndpointDirectory
        return
    }
    $saved = Read-PortalJson $registration
    foreach ($key in $bootstrap.Keys) {
        if ($saved.bootstrap[$key] -cne $bootstrap[$key]) { throw 'The bootstrap differs from the enrolled portal.' }
    }
    if ($RegisterTask) {
        if (-not $BootstrapPath) { throw 'Supply the existing endpoint-bootstrap.json with RegisterTask.' }
        & (Join-Path $root 'ScannerPortal/deployment/Install-ScannerPortalEndpoint.ps1') -BootstrapPath $BootstrapPath -Directory $EndpointDirectory -RegisterTask
    } else {
        & (Join-Path $root 'ScannerPortal/Invoke-ScannerPortalEndpoint.ps1') -Directory $EndpointDirectory -SyncOnly
    }

    return
}

Assert-InstallPath $work
[void][IO.Directory]::CreateDirectory($work)
$lockPath = Join-Path $work 'writer.lock'
if ([IO.File]::Exists($lockPath) -and ([IO.File]::GetAttributes($lockPath) -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Reparse installation lock is not allowed.'
}
$lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')

try {
    $repository = 'ProfKaz/PurviewScripts'
    $headers = @{ 'User-Agent' = 'EndpointMIPScanner-Installer'; Accept = 'application/vnd.github+json' }
    $api = "https://api.github.com/repos/$repository"
    $commit = Invoke-RestMethod "$api/commits/$([uri]::EscapeDataString($Ref))" -Headers $headers
    $sha = [string]$commit.sha
    if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'Invalid source commit.' }
    $tree = Invoke-RestMethod "$api/git/trees/$($commit.commit.tree.sha)?recursive=1" -Headers $headers
    if ($tree.truncated) { throw 'Incomplete GitHub tree.' }
    $prefix = 'Endpoint MIP Scanner/'
    $files = @($tree.tree | Where-Object {
        $_.type -eq 'blob' -and $_.mode -in '100644','100755' -and $_.path.StartsWith($prefix)
    })
    if ($files.Count -eq 0) { throw 'Suite not found in this reference.' }
    Write-Host "Endpoint MIP Scanner 1.4.1 | Commit $sha | Stage $Stage" -ForegroundColor Magenta
    Write-Host "Verifying $($files.Count) suite files in $root"
    $stamp = [guid]::NewGuid().ToString('N')
    $staging = Join-Path $work $stamp
    [void][IO.Directory]::CreateDirectory($staging)
    $downloads = New-Object 'System.Collections.Generic.List[object]'
    $manifest = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $files) {
        $relative = $entry.path.Substring($prefix.Length)
        if ($relative -match '(^|/)\.\.(/|$)|[:\\]' -or [IO.Path]::IsPathRooted($relative)) {
            throw "Unsafe repository path: $relative"
        }
        $target = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not $target.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escaped destination.' }
        for ($parent = [IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($target)); $parent; $parent = $parent.Parent) {
            if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Reparse directory in installation path: $($parent.FullName)"
            }
        }
        if ([IO.File]::Exists($target) -and ([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse file in installation path: $target"
        }
        $actualTarget = $target
        $preserved = $false
        if (-not [IO.File]::Exists($target) -or (Get-BlobHash $target) -ne $entry.sha) {
            $temporary = Join-Path $staging ([guid]::NewGuid().ToString('N'))
            $encoded = ($entry.path.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/$repository/$sha/$encoded" -OutFile $temporary
            if ((Get-BlobHash $temporary) -ne $entry.sha) { throw "Download hash mismatch: $relative" }
            if ($Stage -ne 'EndpointInstall' -and [IO.File]::Exists($target) -and $relative -match '(^|/)[Cc]onfig/') {
                $actualTarget = "$target.distribution"
                $preserved = $true
            }
            $downloads.Add(@{ Temp = $temporary; Target = $actualTarget })
        }
        $manifest.Add(@{ Path = $relative; GitBlobSha1 = $entry.sha; LocalConfigurationPreserved = $preserved })
    }
    if ($Stage -eq 'EndpointInstall') {
        Write-SetupJson (Join-Path $work 'status.json') @{ Status = 'Publishing'; Stage = $Stage; Commit = $sha }
    }
    # Every download is verified before publishing. A rerun reconciles interrupted publication.
    foreach ($item in $downloads) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($item.Target))
        if ([IO.File]::Exists($item.Target)) {
            $backup = Join-Path $work ("backups/$stamp/" + $item.Target.Substring($root.Length + 1))
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup))
            [IO.File]::Copy($item.Target, $backup)
            [IO.File]::Replace($item.Temp, $item.Target, [NullString]::Value)
        } else { [IO.File]::Move($item.Temp, $item.Target) }
        if ([IO.Path]::GetExtension($item.Target) -in '.ps1','.psm1') { Unblock-File -LiteralPath $item.Target }
    }
    Write-SetupJson (Join-Path $work 'files.json') @{ Repository = $repository; Commit = $sha; Files = $manifest.ToArray() }
    $state = [ordered]@{
        InstallId = $stamp; SuiteVersion = '1.4.1'; Commit = $sha; Stage = $Stage; StartedUtc = [datetime]::UtcNow.ToString('o')
        Completed = @(); Status = 'Running'; RestartRequired = $false; VisualCppPackageSha256 = $null
    }
    $state.Completed += 'VerifiedDownload'
    Write-Host "Verified suite. Published $($downloads.Count) changed files."
    Write-SetupJson (Join-Path $work 'status.json') $state
    if ($Stage -notin 'Download','EndpointInstall') {
        if ($Stage -notin 'Publisher','ControlPlane','ManagedEndpoint') {
        Install-VisualCpp
        $sdkParameters = @{ Ref = $sha; Destination = $root }
        if ($DotNetPath) { $sdkParameters.DotNetPath = $DotNetPath }
        $lab = & (Join-Path $root 'deployment/Install-MipSdkAudit.ps1') @sdkParameters
        $state.Completed += 'SdkSelfTest'
        Write-SetupJson (Join-Path $work 'lab.json') $lab
        Invoke-ChildScript (Join-Path $PSHOME 'powershell.exe') (Join-Path $root 'LocalMIPScanner.WinPS51/tests/Test-StateFormat.ps1') @{}
        $state.Completed += 'ScannerStateSmokeTest'
        }
        if ($Stage -in 'MipApp','All') {
            if ($TenantId -eq [guid]::Empty) { $TenantId = [guid](Read-Host 'Tenant ID') }
            $savedMipPath = Join-Path $work 'mip-app.json'
            if (Test-Path -LiteralPath $savedMipPath) {
                $savedMip = Get-Content -LiteralPath $savedMipPath -Raw | ConvertFrom-Json
                if ($savedMip.TenantId -ne $TenantId.ToString()) { throw 'Saved MIP app belongs to another tenant.' }
                if ($MipClientId -ne [guid]::Empty -and $MipClientId.ToString() -ne $savedMip.ClientId) {
                    throw 'MIP client ID differs from the saved installation.'
                }
                $MipClientId = [guid]$savedMip.ClientId
            }
            $setup = @{ TenantId = $TenantId; LogoPath = Join-Path $root 'labs/MipSdkAudit/kaz-demos-entra-215.png' }
            if ($MipClientId -ne [guid]::Empty) { $setup.ClientId = $MipClientId }
            $app = & $lab.AppSetupScript @setup
            Write-SetupJson (Join-Path $work 'mip-app.json') $app
            $state.Completed += 'MipApp'
        }
        if ($Stage -in 'Portal','All') {
            if ($TenantId -eq [guid]::Empty) { $TenantId = [guid](Read-Host 'Tenant ID') }
            if (-not $AdminUrl) { $AdminUrl = Read-Host 'SharePoint admin URL' }
            if (-not $SiteUrl) { $SiteUrl = Read-Host 'Dedicated pilot site URL' }
            if (-not $Owner) { $Owner = Read-Host 'Pilot owner UPN' }
            $pwsh = Install-AdministrativePowerShell
            $portal = Join-Path $root 'deployment/Invoke-PortalSetup.ps1'
            $parameters = @{ TenantId = $TenantId; AdminUrl = $AdminUrl; SiteUrl = $SiteUrl; Owner = $Owner; EvidenceDirectory = $work }
            if ($PortalClientId -ne [guid]::Empty) { $parameters.ClientId = $PortalClientId }
            if ($ResumeFoundation) { $parameters.ResumeFoundation = $true }
            $previousDotNetRoot = $env:DOTNET_ROOT
            try {
                $env:DOTNET_ROOT = Split-Path -Parent $lab.DotNetPath
                Invoke-ChildScript $pwsh $portal $parameters
            } finally { $env:DOTNET_ROOT = $previousDotNetRoot }
            $state.Completed += 'PortalFoundation'
        }
        if ($Stage -eq 'Publisher') {
            if ($TenantId -eq [guid]::Empty) { $TenantId = [guid](Read-Host 'Tenant ID') }
            if (-not $SiteUrl) { $SiteUrl = Read-Host 'Existing ScannerPortal site URL' }
            $pwsh = Install-AdministrativePowerShell
            $parameters = @{
                TenantId = $TenantId; SiteUrl = $SiteUrl; EvidenceDirectory = $work; Mode = 'Apply'
            }
            if ($PortalClientId -ne [guid]::Empty) { $parameters.PortalClientId = $PortalClientId }
            if ($PublisherClientId -ne [guid]::Empty) { $parameters.PublisherClientId = $PublisherClientId }
            Invoke-ChildScript $pwsh (Join-Path $root 'deployment/Initialize-ScannerPortalPublisher.ps1') $parameters
            $state.Completed += 'PublisherPreflight'
        }
        if ($Stage -eq 'ControlPlane') {
            if ($TenantId -eq [guid]::Empty -or -not $SiteUrl) { throw 'ControlPlane requires TenantId and the existing SiteUrl.' }
            if (-not $ControlPlaneStateDirectory) { $ControlPlaneStateDirectory = Join-Path $work 'controlplane' }
            if ($PortalClientId -eq [guid]::Empty -and (Test-Path -LiteralPath (Join-Path $work 'portal-app.json'))) {
                $savedPortal = Get-Content -LiteralPath (Join-Path $work 'portal-app.json') -Raw -Encoding utf8 | ConvertFrom-Json
                if ($savedPortal.TenantId -ne $TenantId.ToString()) { throw 'Saved portal app belongs to another tenant.' }
                $PortalClientId = [guid]$savedPortal.ClientId
            }
            $parameters = @{ TenantId=$TenantId; SiteUrl=$SiteUrl; StateDirectory=$ControlPlaneStateDirectory; Action=$ControlPlaneAction; Mode='Apply' }
            if ($PortalClientId -ne [guid]::Empty) { $parameters.PortalClientId=$PortalClientId }
            if ($ControlPlaneClientId -ne [guid]::Empty) { $parameters.ClientId=$ControlPlaneClientId }
            if ($PublisherClientId -ne [guid]::Empty -and $ControlPlaneAction -eq 'Initialize') {
                $parameters.ExistingLandingPublisherClientId=$PublisherClientId
            }
            if ($EnrollmentRequest) { $parameters.RequestPath=$EnrollmentRequest }
            if ($ProfilePath) { $parameters.ProfilePath=$ProfilePath }
            if ($RegistrationId -ne [guid]::Empty) { $parameters.RegistrationId=$RegistrationId }
            if ($AllowSharedIngress) { $parameters.AllowSharedIngress=$true }
            Invoke-ChildScript (Install-AdministrativePowerShell) (Join-Path $root 'ScannerPortal/deployment/Set-ScannerPortalControlPlane.ps1') $parameters
            $state.Completed += ('ControlPlane-' + $ControlPlaneAction)
        }
        if ($Stage -eq 'ManagedEndpoint') {
            if (-not $BootstrapPath) { throw 'ManagedEndpoint requires BootstrapPath from the portal administrator.' }
            $parameters = @{ BootstrapPath=$BootstrapPath }
            if ($EndpointDirectory) { $parameters.Directory=$EndpointDirectory }
            if ($RegisterTask) { $parameters.RegisterTask=$true }
            Invoke-ChildScript (Join-Path $PSHOME 'powershell.exe') (Join-Path $root 'ScannerPortal/deployment/Install-ScannerPortalEndpoint.ps1') $parameters
            $state.Completed += 'ManagedEndpointEnrollment'
        }
    }
    if ($Stage -eq 'EndpointInstall') {
        Invoke-ChildScript (Join-Path $PSHOME 'powershell.exe') (Join-Path $root 'LocalMIPScanner.WinPS51/tests/Test-StateFormat.ps1') @{}
        $state.Completed += 'ScannerStateSmokeTest'
        if ($BootstrapPath) {
            Import-Module (Join-Path $root 'ScannerPortal/src/ScannerPortal.Endpoint.psm1') -Force
            $bootstrap = Read-PortalJson $BootstrapPath
            Assert-PortalBootstrap $bootstrap
            if ([IO.File]::Exists($machineBootstrap) -and
                ([IO.File]::GetAttributes($machineBootstrap) -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Reparse machine bootstrap is not allowed.'
            }
            Write-PortalJson $bootstrap $machineBootstrap
            $state.Completed += 'MachineBootstrap'
        }
        $state.InstallDirectory = $root
    }
    $state.Status = 'Completed'
    $dependencyEvidence = @{
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Modules = @(Get-Module | Select-Object Name, Version, Path)
        Scripts = (Get-Content -LiteralPath (Join-Path $root 'suite-manifest.json') -Raw | ConvertFrom-Json).Scripts
    }
    if (Get-Variable lab -Scope Script -ErrorAction SilentlyContinue) {
        $dependencyEvidence.DotNetPath = $lab.DotNetPath
        $dependencyEvidence.DotNetSdks = @(& $lab.DotNetPath --list-sdks)
        $dependencyEvidence.DotNetRuntimes = @(& $lab.DotNetPath --list-runtimes)
    }
    Write-SetupJson (Join-Path $work 'dependencies.json') $dependencyEvidence
    $state.FinishedUtc = [datetime]::UtcNow.ToString('o')
    Write-SetupJson (Join-Path $work 'status.json') $state
    [pscustomobject]$state
} catch {
    if (Get-Variable state -ErrorAction SilentlyContinue) {
        $state.Status = 'Failed'
        $state.Error = $_.Exception.Message
        Write-SetupJson (Join-Path $work 'status.json') $state
    }
    throw
} finally {
    $lock.Dispose()
}
