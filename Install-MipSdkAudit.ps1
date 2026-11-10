#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $Ref = 'main',
    [ValidateNotNullOrEmpty()][string] $Destination = (Get-Location).Path,
    [string] $DotNetPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The MIP SDK lab requires Windows.' }

function Test-LabDotNet {
    param([string] $Path)
    if (-not [IO.File]::Exists($Path)) { return $false }

    $stream = [IO.File]::OpenRead($Path)
    try {
        $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
        try { if ($pe.PEHeaders.CoffHeader.Machine -ne 'Amd64') { return $false } }
        finally { $pe.Dispose() }
    } catch [BadImageFormatException] { return $false }
    finally { $stream.Dispose() }

    $sdks = & $Path --list-sdks
    if ($LASTEXITCODE -ne 0 -or -not ($sdks -match '^10\.0\.\d+ \[')) { return $false }
    $runtimes = & $Path --list-runtimes
    return ($LASTEXITCODE -eq 0 -and [bool]($runtimes -match '^Microsoft\.NETCore\.App 10\.0\.\d+ \['))
}

function Install-LabDotNet {
    param([string] $Path)

    $metadata = Invoke-RestMethod 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
    $version = $metadata.'latest-sdk'
    $sdk = @($metadata.releases | Where-Object { $_.sdk.version -eq $version } | Select-Object -First 1)
    if ($sdk.Count -ne 1) { throw 'Could not resolve the latest .NET 10 SDK.' }
    $asset = @($sdk[0].sdk.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -eq 'dotnet-sdk-win-x64.zip' })
    if ($asset.Count -ne 1 -or $asset[0].hash -notmatch '^[0-9a-fA-F]{128}$' -or
        ([uri]$asset[0].url).Scheme -ne 'https') { throw 'Could not verify the .NET 10 x64 download metadata.' }

    $directory = Split-Path -Parent $Path
    $parent = Split-Path -Parent $directory
    if ([IO.Directory]::Exists($directory)) {
        throw "The managed .NET SDK directory already exists and is unusable: $directory. Rename it or specify -DotNetPath."
    }
    [void] [IO.Directory]::CreateDirectory($parent)
    $stage = Join-Path $parent ('dotnet-stage-' + [guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($stage)
    $archive = Join-Path $stage 'sdk.zip'
    $expanded = Join-Path $stage 'sdk'
    try {
        Write-Host "Downloading .NET SDK $version (Windows x64) from Microsoft..."
        Invoke-WebRequest -Uri $asset[0].url -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash -ine $asset[0].hash) {
            throw 'The downloaded .NET SDK failed SHA-512 verification.'
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded
        if (-not (Test-LabDotNet (Join-Path $expanded 'dotnet.exe'))) { throw 'The downloaded x64 SDK is unusable.' }
        [IO.Directory]::Move($expanded, $directory)
    } finally {
        if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) }
    }
}

function Get-GitBlobHash {
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash('SHA1')
    try {
        $hash.AppendData([Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)" + [char]0))
        $hash.AppendData($bytes)
        [Convert]::ToHexString($hash.GetHashAndReset())
    } finally { $hash.Dispose() }
}

$repository = 'ProfKaz/PurviewScripts'
$encodedRef = [uri]::EscapeDataString($Ref)
$api = "https://api.github.com/repos/$repository"
$headers = @{ 'User-Agent' = 'LocalMIPScanner-MipSdkAudit-Installer' }
$commit = Invoke-RestMethod -Uri "$api/commits/$encodedRef" -Headers $headers
$sha = $commit.sha
if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve a GitHub commit.' }
$tree = Invoke-RestMethod -Uri "$api/git/trees/$($commit.commit.tree.sha)?recursive=1" -Headers $headers
if ($tree.truncated) { throw 'GitHub returned an incomplete repository tree.' }
$files = 'MipSdkAudit.csproj', 'Program.cs', 'README.md', 'New-MipSdkAuditApp.ps1'
$hashes = @{}
foreach ($name in $files) {
    $relative = "labs/MipSdkAudit/$name"
    $entry = @($tree.tree | Where-Object { $_.path -ceq $relative -and $_.type -eq 'blob' -and $_.mode -in '100644','100755' })
    if ($entry.Count -ne 1) { throw "Lab file $relative is unavailable in ref '$Ref'." }
    $hashes[$name] = $entry[0].sha
}

$originalCertificate = $env:DOTNET_GENERATE_ASPNET_CERTIFICATE
$originalTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

try {
    $managedDotNet = Join-Path $env:LOCALAPPDATA 'LocalMIPScanner\MipSdkAudit\dotnet-10-x64\dotnet.exe'
    if ($DotNetPath) {
        $dotnet = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DotNetPath)
        if (-not (Test-LabDotNet $dotnet)) {
            throw '-DotNetPath must point to an x64 dotnet.exe with both a .NET 10 SDK and runtime.'
        }
    } else {
        $candidates = @(
            Get-Command dotnet -CommandType Application -All -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Source
            Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
            Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
            $managedDotNet
        )
        $dotnet = $candidates | Select-Object -Unique | Where-Object { Test-LabDotNet $_ } | Select-Object -First 1
        if (-not $dotnet) {
            Install-LabDotNet $managedDotNet
            $dotnet = $managedDotNet
        }
    }

    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
    $lab = Join-Path $root 'labs\MipSdkAudit'
    [void] [IO.Directory]::CreateDirectory($lab)
    $stamp = [guid]::NewGuid().ToString('N')
    $backup = Join-Path $lab ".installer-backups\$stamp"
    $downloads = @{}
    try {
        foreach ($name in $files) {
            $target = Join-Path $lab $name
            if ([IO.File]::Exists($target) -and (Get-GitBlobHash $target) -ieq $hashes[$name]) { continue }
            $temporary = "$target.$stamp.tmp"
            $downloads[$name] = $temporary
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repository/$sha/labs/MipSdkAudit/$name" -OutFile $temporary
            if ((Get-GitBlobHash $temporary) -ine $hashes[$name]) { throw "Git blob verification failed for $name." }
        }
        foreach ($name in $files) {
            $target = Join-Path $lab $name
            if ($downloads.ContainsKey($name)) {
                if ([IO.File]::Exists($target)) {
                    [void] [IO.Directory]::CreateDirectory($backup)
                    [IO.File]::Copy($target, (Join-Path $backup $name))
                }
                [IO.File]::Move($downloads[$name], $target, $true)
            }
            if ($name.EndsWith('.ps1')) { Unblock-File -LiteralPath $target }
        }
    } finally {
        foreach ($temporary in $downloads.Values) { [IO.File]::Delete($temporary) }
    }

    $output = Join-Path $lab 'bin\installer\net10.0'
    Write-Host "Building lab from $sha with $dotnet"
    Push-Location -LiteralPath $lab
    try {
        & $dotnet build (Join-Path $lab 'MipSdkAudit.csproj') -c Release --output $output | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Lab build failed with exit code $LASTEXITCODE." }
    } finally { Pop-Location }
    $assembly = Join-Path $output 'MipSdkAudit.dll'
    & $dotnet $assembly --self-test | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Lab self-test failed with exit code $LASTEXITCODE. If the SDK cannot initialize, check the Visual C++ x64 runtime."
    }
    [pscustomobject] @{
        SourceCommit = $sha
        LabDirectory = $lab
        DotNetPath = $dotnet
        LabAssembly = $assembly
        AppSetupScript = Join-Path $lab 'New-MipSdkAuditApp.ps1'
        SelfTestPassed = $true
    }
} finally {
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = $originalCertificate
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $originalTelemetry
}
