<#PSScriptInfo
.VERSION 1.1.0
.GUID 0576cc7a-692e-4876-bfe5-d1fb62a30116
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.PROJECTURI https://github.com/ProfKaz/PurviewScripts
.RELEASENOTES
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: 0576cc7a-692e-4876-bfe5-d1fb62a30116
#>
<#
.DESCRIPTION
Endpoint MIP Scanner component: Install-EndpointMIPScanner.ps1.
.NOTES
HISTORY
Script      : Install-EndpointMIPScanner.ps1
Version     : 1.1.0
Tracking ID : 0576cc7a-692e-4876-bfe5-d1fb62a30116
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._/-]+$')][string] $Ref = 'main',
    [string] $Destination,
    [ValidateSet('Download','Local','MipApp','Portal','All')][string] $Stage = 'Local',
    [string] $DotNetPath,
    [guid] $TenantId = [guid]::Empty,
    [guid] $MipClientId = [guid]::Empty,
    [guid] $PortalClientId = [guid]::Empty,
    [string] $AdminUrl,
    [string] $SiteUrl,
    [string] $Owner,
    [switch] $ResumeFoundation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Destination) { $Destination = $PSScriptRoot }
if (-not [Environment]::Is64BitProcess) { throw 'Use Windows PowerShell 5.1 x64.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$root = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
if ($root -eq [IO.Path]::GetPathRoot($root).TrimEnd('\')) { throw 'Choose a project directory, not a drive root.' }
[void][IO.Directory]::CreateDirectory($root)
$work = Join-Path $root '.endpoint-install'
[void][IO.Directory]::CreateDirectory($work)
$lock = [IO.File]::Open((Join-Path $work 'writer.lock'), 'OpenOrCreate', 'ReadWrite', 'None')

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
    Write-Host "Endpoint MIP Scanner 1.1.0 | Commit $sha | Stage $Stage" -ForegroundColor Magenta
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
            if ([IO.File]::Exists($target) -and $relative -match '(^|/)[Cc]onfig/') {
                $actualTarget = "$target.distribution"
                $preserved = $true
            }
            $downloads.Add(@{ Temp = $temporary; Target = $actualTarget })
        }
        $manifest.Add(@{ Path = $relative; GitBlobSha1 = $entry.sha; LocalConfigurationPreserved = $preserved })
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
        InstallId = $stamp; SuiteVersion = '1.1.0'; Commit = $sha; Stage = $Stage; StartedUtc = [datetime]::UtcNow.ToString('o')
        Completed = @(); Status = 'Running'; RestartRequired = $false; VisualCppPackageSha256 = $null
    }
    $state.Completed += 'VerifiedDownload'
    Write-Host "Verified suite. Published $($downloads.Count) changed files."
    Write-SetupJson (Join-Path $work 'status.json') $state
    if ($Stage -ne 'Download') {
        Install-VisualCpp
        $sdkParameters = @{ Ref = $sha; Destination = $root }
        if ($DotNetPath) { $sdkParameters.DotNetPath = $DotNetPath }
        $lab = & (Join-Path $root 'deployment/Install-MipSdkAudit.ps1') @sdkParameters
        $state.Completed += 'SdkSelfTest'
        Write-SetupJson (Join-Path $work 'lab.json') $lab
        Invoke-ChildScript (Join-Path $PSHOME 'powershell.exe') (Join-Path $root 'LocalMIPScanner.WinPS51/tests/Test-StateFormat.ps1') @{}
        $state.Completed += 'ScannerStateSmokeTest'
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
    }
    $state.Status = 'Completed'
    $dependencyEvidence = @{
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Modules = @(Get-Module | Select-Object Name, Version, Path)
        Scripts = (Get-Content -LiteralPath (Join-Path $root 'suite-manifest.json') -Raw | ConvertFrom-Json).Scripts
    }
    if (Get-Variable lab -ErrorAction SilentlyContinue) {
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
