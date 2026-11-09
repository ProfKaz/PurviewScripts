Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-LocalPath {
    param([string] $Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -notmatch '^[A-Za-z]:[\\/]' -or $expanded.Substring(2).Contains(':')) {
        throw "Expected an absolute Windows drive path: $Path"
    }

    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($expanded))
}

function Test-PathWithin {
    param([string] $Path, [string] $Directory)

    $comparison = [StringComparison]::OrdinalIgnoreCase
    $prefix = $Directory.TrimEnd('\') + '\'
    $Path.Equals($Directory, $comparison) -or $Path.StartsWith($prefix, $comparison)
}

function Assert-OrdinaryDirectory {
    param([string] $Path)

    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
    if ($drive.DriveType -notin 'Fixed', 'Removable', 'Ram') {
        throw "Unsupported drive type: $($drive.DriveType)"
    }

    $ancestors = [Collections.Generic.Stack[string]]::new()
    for ($current = [IO.DirectoryInfo]::new($Path); $null -ne $current; $current = $current.Parent) {
        $ancestors.Push($current.FullName)
    }

    foreach ($ancestor in $ancestors) {
        $attributes = [IO.File]::GetAttributes($ancestor)
        if (($attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
            ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Expected a directory without reparse points in its path: $ancestor"
        }
    }
}

function Get-InventoryConfig {
    param([string] $Directory)

    $extensions = Get-Content -LiteralPath (Join-Path $Directory 'extensions.json') -Raw |
        ConvertFrom-Json -NoEnumerate
    if ($extensions -isnot [array] -or $extensions.Count -eq 0) {
        throw 'extensions.json must contain a nonempty array of extensions.'
    }

    $extensionSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in $extensions) {
        if ($extension -isnot [string] -or $extension -notmatch '^\.[A-Za-z0-9]+$') {
            throw "Invalid extension in extensions.json: $extension"
        }
        [void] $extensionSet.Add($extension)
    }

    $exclusions = Get-Content -LiteralPath (Join-Path $Directory 'exclusions.json') -Raw |
        ConvertFrom-Json -NoEnumerate
    if ($exclusions -isnot [array]) {
        throw 'exclusions.json must contain an array of absolute directory paths.'
    }

    $performance = Get-Content -LiteralPath (Join-Path $Directory 'performance.json') -Raw |
        ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($performance -isnot [Collections.IDictionary] -or
        $performance['batchSize'] -isnot [long] -or $performance['batchSize'] -lt 1 -or $performance['batchSize'] -gt 10000 -or
        $performance['pauseMilliseconds'] -isnot [long] -or $performance['pauseMilliseconds'] -lt 0 -or $performance['pauseMilliseconds'] -gt 10000) {
        throw 'performance.json requires integer batchSize (1–10000) and pauseMilliseconds (0–10000).'
    }

    @{
        Extensions = $extensionSet
        Exclusions = @(foreach ($directoryPath in $exclusions) {
            if ($directoryPath -isnot [string]) {
                throw 'Each exclusion must be a string.'
            }
            ConvertTo-LocalPath $directoryPath
        })
        BatchSize = $performance['batchSize']
        PauseMilliseconds = $performance['pauseMilliseconds']
    }
}

function Write-InventoryEvent {
    param([IO.StreamWriter] $Writer, [System.Collections.IDictionary] $Event)

    $Writer.WriteLine((ConvertTo-Json -InputObject $Event -Compress))
}

function Invoke-LocalMIPInventory {
    param([string[]] $Root, [string] $ConfigDirectory, [string] $LogDirectory)

    if (-not $IsWindows) { throw 'LocalMIPScanner requires Windows.' }
    $config = Get-InventoryConfig $ConfigDirectory
    $logPath = ConvertTo-LocalPath $LogDirectory
    $roots = @($Root | ForEach-Object { ConvertTo-LocalPath $_ } | Sort-Object -Property Length)
    $config.Exclusions += $logPath

    $logParent = [IO.DirectoryInfo]::new($logPath)
    while (-not $logParent.Exists -and $null -ne $logParent.Parent) {
        $logParent = $logParent.Parent
    }
    Assert-OrdinaryDirectory $logParent.FullName
    [void] [IO.Directory]::CreateDirectory($logPath)
    Assert-OrdinaryDirectory $logPath

    $runId = [guid]::NewGuid().ToString('N')
    $logFile = Join-Path $logPath "inventory-$runId.jsonl"
    $writer = [IO.StreamWriter]::new($logFile, $false)
    $summary = [ordered] @{
        event = 'summary'
        runId = $runId
        startedUtc = [datetime]::UtcNow.ToString('o')
        inventoried = 0
        entriesVisited = 0
        excluded = 0
        reparsePointsSkipped = 0
        offlineFilesSkipped = 0
        errors = 0
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $completedRoots = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $options = [IO.EnumerationOptions]::new()
    $options.AttributesToSkip = 0
    $options.IgnoreInaccessible = $false

    try {
        Write-InventoryEvent $writer ([ordered] @{
            event = 'start'
            schemaVersion = 1
            runId = $runId
            startedUtc = $summary.startedUtc
            roots = $roots
        })

        foreach ($rootPath in $roots) {
            if ($completedRoots.Where({ Test-PathWithin $rootPath $_ }, 'First').Count -gt 0) {
                continue
            }

            if ($config.Exclusions.Where({ Test-PathWithin $rootPath $_ }, 'First').Count -gt 0) {
                $summary.excluded++
                continue
            }

            try {
                Assert-OrdinaryDirectory $rootPath
            } catch {
                $summary.errors++
                Write-InventoryEvent $writer @{ event = 'error'; operation = 'openRoot'; path = $rootPath; message = $_.Exception.Message }
                continue
            }

            $pending.Push($rootPath)
            $errorsBeforeRoot = $summary.errors
            while ($pending.Count -gt 0) {
                $directory = $pending.Pop()
                $entries = $null
                try {
                    $info = [IO.DirectoryInfo]::new($directory)
                    if (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $summary.reparsePointsSkipped++
                        continue
                    }
                    $entries = $info.EnumerateFileSystemInfos('*', $options).GetEnumerator()
                } catch {
                    $summary.errors++
                    Write-InventoryEvent $writer @{ event = 'error'; operation = 'openDirectory'; path = $directory; message = $_.Exception.Message }
                    continue
                }

                try {
                    while ($true) {
                        try {
                            if (-not $entries.MoveNext()) { break }
                            $entry = $entries.Current
                        } catch {
                            $summary.errors++
                            Write-InventoryEvent $writer @{ event = 'error'; operation = 'enumerateDirectory'; path = $directory; message = $_.Exception.Message }
                            break
                        }

                        $summary.entriesVisited++
                        if ($config.PauseMilliseconds -gt 0 -and $summary.entriesVisited % $config.BatchSize -eq 0) {
                            Start-Sleep -Milliseconds $config.PauseMilliseconds
                        }

                        if ($config.Exclusions.Where({ Test-PathWithin $entry.FullName $_ }, 'First').Count -gt 0) {
                            $summary.excluded++
                            continue
                        }

                        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                            $summary.reparsePointsSkipped++
                            continue
                        }

                        if ($entry -is [IO.DirectoryInfo]) {
                            $pending.Push($entry.FullName)
                            continue
                        }

                        if (-not $config.Extensions.Contains($entry.Extension)) {
                            continue
                        }

                        if (($entry.Attributes -band [IO.FileAttributes]::Offline) -ne 0) {
                            $summary.offlineFilesSkipped++
                            continue
                        }

                        Write-InventoryEvent $writer ([ordered] @{
                            event = 'file'
                            path = $entry.FullName
                            extension = $entry.Extension.ToLowerInvariant()
                            sizeBytes = $entry.Length
                            lastWriteUtc = $entry.LastWriteTimeUtc.ToString('o')
                        })
                        $summary.inventoried++
                    }
                } finally {
                    $entries.Dispose()
                }
            }

            # A nested root can still be useful when part of its parent was unreadable.
            if ($summary.errors -eq $errorsBeforeRoot) {
                $completedRoots.Add($rootPath)
            }
        }

        $summary.elapsedMilliseconds = $timer.ElapsedMilliseconds
        Write-InventoryEvent $writer $summary
    } finally {
        $writer.Dispose()
    }

    [pscustomobject] ($summary + @{ logFile = $logFile })
}

Export-ModuleMember -Function Invoke-LocalMIPInventory
