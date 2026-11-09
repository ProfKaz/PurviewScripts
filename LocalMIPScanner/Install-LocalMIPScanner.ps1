#Requires -Version 7.2
<#
.SYNOPSIS
Installs or updates LocalMIPScanner from a pinned GitHub commit.
.DESCRIPTION
Uses GitHub's recursive tree as a manifest, compares Git blob hashes locally,
stages and verifies downloads, backs up changed configuration, and optionally
unblocks PowerShell scripts. Does not require Git or administrator privileges.
.EXAMPLE
.\Install-LocalMIPScanner.ps1 -Destination 'C:\Deploy\LocalMIPScanner'
.EXAMPLE
.\Install-LocalMIPScanner.ps1 -Ref main -Unblock
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $Destination = (Get-Location).Path,
    [ValidatePattern('^[a-zA-Z0-9._/-]+$')]
    [string] $Ref = 'main',
    [switch] $Unblock,
    [switch] $NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = 'ProfKaz/PurviewScripts'
$sourcePrefix = 'LocalMIPScanner/'
$api = 'https://api.github.com/repos/' + $repository
$headers = @{ 'Accept'='application/vnd.github+json'; 'User-Agent'='LocalMIPScanner-Installer'; 'X-GitHub-Api-Version'='2022-11-28' }

function Get-GitBlobHash {
    param([Parameter(Mandatory)][string] $File)
    [byte[]] $bytes = [IO.File]::ReadAllBytes($File)
    [byte[]] $prefix = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA1)
    try {
        $hasher.AppendData($prefix)
        $hasher.AppendData($bytes)
        return [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    } finally { $hasher.Dispose() }
}

function Test-ManagedPath {
    param([string] $Relative)
    if ([string]::IsNullOrWhiteSpace($Relative) -or
        $Relative.StartsWith('/') -or $Relative.StartsWith('\\') -or
        $Relative.Contains('\\') -or $Relative.Contains(':')) { return $false }
    foreach ($segment in $Relative.Split('/')) {
        if ($segment -in @('', '.', '..')) { return $false }
    }
    return $true
}

function Get-SafeDestination {
    param([string] $Relative)
    if (-not (Test-ManagedPath $Relative)) { throw "Unsafe repository path: $Relative" }
    $full = [IO.Path]::GetFullPath((Join-Path $destinationRoot ($Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    if (-not $full.StartsWith(($destinationRoot.TrimEnd([char[]]@('\','/')) + [IO.Path]::DirectorySeparatorChar),
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Repository path escapes destination: $Relative"
    }
    return $full
}

function Assert-NoReparseAncestors {
    param([string] $Path)
    for ($dir = [IO.DirectoryInfo]::new($Path); $null -ne $dir; $dir = $dir.Parent) {
        if ($dir.Exists -and ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Installation path must not contain junctions or symlinks: $($dir.FullName)"
        }
    }
}

$destinationRoot = [IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables($Destination))
if (-not $IsWindows) { throw 'This installer requires Windows.' }
Assert-NoReparseAncestors $destinationRoot
[void][IO.Directory]::CreateDirectory($destinationRoot)
$manifestPath = Join-Path $destinationRoot '.localmipscanner-install.json'
$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$staging = Join-Path $destinationRoot ('.install-staging-' + $stamp)
$backup = Join-Path $destinationRoot ('.installer-backups\' + $stamp)
$previous = @{}
if ([IO.File]::Exists($manifestPath)) {
    $oldManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($oldManifest.repository -eq $repository -and $oldManifest.files -is [Collections.IDictionary]) {
        $previous = $oldManifest.files
    }
}

Write-Host "Checking $repository @ $Ref ..."
$commit = Invoke-RestMethod -Uri ($api + '/commits/' + [uri]::EscapeDataString($Ref)) -Headers $headers
$commitSha = [string]$commit.sha
if ($commitSha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub returned an invalid commit SHA.' }
$treeSha = [string]$commit.commit.tree.sha
$tree = Invoke-RestMethod -Uri ($api + '/git/trees/' + $treeSha + '?recursive=1') -Headers $headers
if ($tree.truncated) { throw 'GitHub tree was truncated. Refusing an incomplete installation.' }
$files = @($tree.tree | Where-Object {
    $_.type -eq 'blob' -and $_.path.StartsWith($sourcePrefix, [StringComparison]::Ordinal) -and
    $_.mode -in @('100644','100755')
} | Sort-Object path)
if ($files.Count -eq 0) { throw 'No files found in LocalMIPScanner at selected ref.' }

$desired = @{}
$pending = [Collections.Generic.List[object]]::new()
foreach ($item in $files) {
    $relative = [string]$item.path.Substring($sourcePrefix.Length)
    $target = Get-SafeDestination $relative
    $expected = [string]$item.sha
    if ($expected -notmatch '^[0-9a-f]{40}$') { throw "Invalid Git blob SHA for $relative" }
    $desired[$relative] = $expected
    if ([IO.File]::Exists($target) -and (Get-GitBlobHash $target) -eq $expected) {
        Write-Host "OK        $relative"
    } else {
        [void]$pending.Add([pscustomobject]@{ Relative=$relative; Target=$target; Hash=$expected })
        Write-Host "UPDATE    $relative"
    }
}
Write-Host ("Files: {0}; downloads required: {1}" -f $files.Count, $pending.Count)

try {
    # Download and verify every pending file BEFORE touching any installed file.
    [void][IO.Directory]::CreateDirectory($staging)
    foreach ($item in $pending) {
        $temp = Join-Path $staging ([guid]::NewGuid().ToString('N') + '.download')
        $urlPath = (($sourcePrefix + $item.Relative).Split('/') |
            ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $url = "https://raw.githubusercontent.com/$repository/$commitSha/$urlPath"
        Invoke-WebRequest -Uri $url -OutFile $temp -ErrorAction Stop
        $actual = Get-GitBlobHash $temp
        if ($actual -ne $item.Hash) { throw "Downloaded content hash mismatch for $($item.Relative)" }
        Add-Member -InputObject $item -NotePropertyName Temp -NotePropertyValue $temp
    }

    foreach ($item in $pending) {
        $parent = [IO.Path]::GetDirectoryName($item.Target)
        Assert-NoReparseAncestors $parent
        [void][IO.Directory]::CreateDirectory($parent)
        if ([IO.File]::Exists($item.Target) -and $item.Relative.StartsWith('Config/', [StringComparison]::OrdinalIgnoreCase)) {
            $backupFile = Join-Path $backup ($item.Relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backupFile))
            [IO.File]::Copy($item.Target, $backupFile, $false)
            Write-Host "BACKUP    $($item.Relative) -> $backupFile"
        }
        [IO.File]::Move($item.Temp, $item.Target, $true)
    }

    # Remove only stale files installed by this tool and unchanged since its prior run.
    foreach ($oldPath in @($previous.Keys)) {
        if ($desired.ContainsKey($oldPath) -or -not (Test-ManagedPath $oldPath)) { continue }
        $oldTarget = Get-SafeDestination $oldPath
        if (-not [IO.File]::Exists($oldTarget)) { continue }
        if ((Get-GitBlobHash $oldTarget) -ne $previous[$oldPath]) {
            Write-Warning "Obsolete but locally modified: $oldPath (left untouched)"
            continue
        }
        $backupFile = Join-Path $backup ('obsolete\' + $oldPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backupFile))
        [IO.File]::Move($oldTarget, $backupFile)
        Write-Host "ARCHIVE   $oldPath"
    }

    $newManifest = @{
        schemaVersion = 1
        repository = $repository
        ref = $Ref
        commit = $commitSha
        updatedUtc = [datetime]::UtcNow.ToString('o')
        files = $desired
    } | ConvertTo-Json -Depth 10
    $manifestTemp = Join-Path $staging 'manifest.tmp'
    [IO.File]::WriteAllText($manifestTemp, $newManifest, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($manifestTemp, $manifestPath, $true)
} finally {
    if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging, $true) }
}

$doUnblock = [bool]$Unblock
if (-not $Unblock -and -not $NoPrompt) {
    $answer = Read-Host 'Unblock all .ps1/.psm1 in root and tests? [y/N]'
    $doUnblock = $answer -match '^(y|yes|s|si|sí)$'
}
if ($doUnblock) {
    $scriptFiles = @(
        foreach ($folder in @($destinationRoot, (Join-Path $destinationRoot 'tests'))) {
            if ([IO.Directory]::Exists($folder)) {
                Get-ChildItem -LiteralPath $folder -File |
                    Where-Object { $_.Extension -in '.ps1','.psm1' }
            }
        }
    )
    foreach ($file in $scriptFiles) { Unblock-File -LiteralPath $file.FullName -ErrorAction Stop }
    Write-Host "Unblocked $($scriptFiles.Count) PowerShell scripts."
}
Write-Host "Installation complete: $destinationRoot"
Write-Host "Source commit: $commitSha"
Write-Host 'Run: pwsh -NoProfile -File .\tests\Test-Incremental.ps1'
