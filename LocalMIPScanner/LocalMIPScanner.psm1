Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'LocalMIPState.psm1') -Force
. (Join-Path $PSScriptRoot 'LocalMIPCheckpoint.ps1')
. (Join-Path $PSScriptRoot 'LocalMIPContentAudit.ps1')

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
    param([string] $Path, [switch] $SkipOffline)

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
            ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($SkipOffline -and ($attributes -band [IO.FileAttributes]::Offline) -ne 0)) {
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

function Invoke-InventoryDirectory {
    param(
        [string] $Directory, $Config, $Incremental, $Summary,
        [IO.StreamWriter] $Writer, [IO.EnumerationOptions] $Options, $Pending, $State
    )
    try {
        if ($null -ne $State) {
            # A directory may have been moved or replaced since its parent checkpoint.
            Assert-OrdinaryDirectory $Directory -SkipOffline
        } elseif (([IO.File]::GetAttributes($Directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $Summary.reparsePointsSkipped++
            return
        }
        $entries = [IO.DirectoryInfo]::new($Directory).EnumerateFileSystemInfos('*', $Options).GetEnumerator()
    } catch {
        $Summary.errors++
        Write-InventoryEvent $Writer @{ event = 'error'; operation = 'openDirectory'; path = $Directory; message = $_.Exception.Message }
        return
    }

    try {
        while ($true) {
            try {
                if (-not $entries.MoveNext()) { break }
                $entry = $entries.Current
            } catch {
                $Summary.errors++
                Write-InventoryEvent $Writer @{ event = 'error'; operation = 'enumerateDirectory'; path = $Directory; message = $_.Exception.Message }
                break
            }

            $Summary.entriesVisited++
            if ($Config.PauseMilliseconds -gt 0 -and $Summary.entriesVisited % $Config.BatchSize -eq 0) {
                Start-Sleep -Milliseconds $Config.PauseMilliseconds
            }

            $path = $entry.FullName
            if ($Config.Exclusions.Where({ Test-PathWithin $path $_ }, 'First').Count -gt 0) {
                $Summary.excluded++
                continue
            }

            try {
                $attributes = $entry.Attributes
                if ([int] $attributes -eq -1) { throw 'Entry is no longer available.' }
                if (($attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Offline)) -eq 0 -and
                    $entry -isnot [IO.DirectoryInfo] -and $Config.Extensions.Contains($entry.Extension)) {
                    $size = [long] $entry.Length
                    $modified = $entry.LastWriteTimeUtc.ToString('o')
                }
            } catch {
                $Summary.errors++
                Write-InventoryEvent $Writer @{ event = 'error'; operation = 'readMetadata'; path = $path; message = $_.Exception.Message }
                continue
            }

            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ($null -ne $State) { Add-DirectoryRecord $State @{ kind = 'protect'; path = $path } }
                $Summary.reparsePointsSkipped++
                continue
            }

            if ($entry -is [IO.DirectoryInfo]) {
                if ($null -ne $State) {
                    if (($attributes -band [IO.FileAttributes]::Offline) -ne 0) {
                        Add-DirectoryRecord $State @{ kind = 'protect'; path = $path }
                        continue
                    }
                    Add-DirectoryRecord $State @{ kind = 'child'; path = $path }
                } else { $Pending.Push($path) }
                continue
            }

            if (-not $Config.Extensions.Contains($entry.Extension)) { continue }

            if (($attributes -band [IO.FileAttributes]::Offline) -ne 0) {
                if ($null -ne $State) { Add-DirectoryRecord $State @{ kind = 'seen'; path = $path } }
                $Summary.offlineFilesSkipped++
                continue
            }

            $decision = 'inventory'
            if ($null -ne $State) {
                $observation = @{ kind = 'seen'; path = $path }
                if ($size -gt $Incremental.MaxBytes) {
                    Add-DirectoryRecord $State $observation
                    $Summary.oversizedFiles++
                    Write-InventoryEvent $Writer @{ event = 'skip'; reason = 'oversized'; path = $path; sizeBytes = $size }
                    continue
                }

                $decision = Get-FileInventoryDecision -Settings $Incremental -Entries $State.Entries -Path $path -SizeBytes $size -LastWriteUtc $modified -Now ([datetime]::UtcNow)
                switch ($decision) {
                    'new' { $Summary.newFiles++ }
                    'modified' { $Summary.modifiedFiles++ }
                    'due' { $Summary.dueFiles++ }
                    'unchanged' { $Summary.unchangedFiles++ }
                }

                $previous = $null
                [void] $State.Entries.TryGetValue($path, [ref] $previous)
                if ($decision -ne 'unchanged' -or $previous.sizeBytes -ne $size -or $previous.lastWriteUtc -cne $modified) {
                    $lastScanned = $null
                    if ($decision -eq 'unchanged') { $lastScanned = $previous['lastContentScannedUtc'] }
                    $observation.item = @{
                        schemaVersion = 1; path = $path; sizeBytes = $size; lastWriteUtc = $modified
                        lastDiscoveredUtc = [datetime]::UtcNow.ToString('o')
                        lastContentScannedUtc = $lastScanned; status = 'PendingClassification'
                    }
                }
                if ($null -ne $Config.ContentAudit) {
                    Invoke-FileContentAudit $Config.ContentAudit $Summary $Writer $observation $previous $entry.Extension $size $modified $Incremental.Days
                }
                if (-not $observation.ContainsKey('item')) { $Summary.metadataUpdatesSkipped++ }
                Add-DirectoryRecord $State $observation
                $Summary.pendingClassification++
            }

            Write-InventoryEvent $Writer ([ordered] @{
                event = 'file'; path = $path; extension = $entry.Extension.ToLowerInvariant()
                sizeBytes = $size; lastWriteUtc = $modified; decision = $decision
            })
            $Summary.inventoried++
        }
    } finally { $entries.Dispose() }
}

function Invoke-CheckpointedDiscovery {
    param($State, $Config, $Incremental, $Summary, $Writer, $Options, [int] $MaxDirectories, [int] $MaxSeconds)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $Summary.resumedDirectories = $State.Completed
    while ($State.Pending.Count -gt 0) {
        $directory = $State.Pending.Peek()
        $errorsBefore = $Summary.errors
        Write-JournalRecord $State @{ kind = 'begin'; path = $directory }
        Invoke-InventoryDirectory $directory $Config $Incremental $Summary $Writer $Options $null $State
        $Writer.Flush()
        Complete-StateDirectory $State $directory ($Summary.errors -ne $errorsBefore)
        $Summary.directoriesCompleted++
        if (($MaxDirectories -gt 0 -and $Summary.directoriesCompleted -ge $MaxDirectories) -or
            ($MaxSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $MaxSeconds)) { break }
    }
}

function Test-KeepInventoryEntry {
    param([string] $Path, $State, $Config, $Roots)
    if ($State.Seen.Contains($Path) -or -not $Config.Extensions.Contains([IO.Path]::GetExtension($Path))) {
        return $true
    }
    if (-not $Roots.Where({ Test-PathWithin $Path $_ }, 'First').Count -or
        $Config.Exclusions.Where({ Test-PathWithin $Path $_ }, 'First').Count) { return $true }

    for ($parent = $Path; $parent; $parent = [IO.Path]::GetDirectoryName($parent)) {
        if ($State.Protected.Contains($parent)) { return $true }
    }
    return $false
}

function Invoke-LocalMIPInventory {
    param(
        [string[]] $Root, [string] $ConfigDirectory, [string] $LogDirectory,
        [ValidateRange(0, 2147483647)] [int] $MaxDirectories = 0,
        [ValidateRange(0, 2147483647)] [int] $MaxSeconds = 0,
        [switch] $AuditContent
    )

    if (-not $IsWindows) { throw 'LocalMIPScanner requires Windows.' }
    $config = Get-InventoryConfig $ConfigDirectory
    $incremental = Get-IncrementalSettings $ConfigDirectory
    $config.ContentAudit = $null
    if ($AuditContent) {
        if (-not $incremental.Enabled) { throw 'Content audit requires incremental discovery.' }
        $config.ContentAudit = Get-ContentAuditSettings $ConfigDirectory
    }
    $logPath = ConvertTo-LocalPath $LogDirectory
    $roots = @($Root | ForEach-Object { ConvertTo-LocalPath $_ } | Sort-Object -Property Length, { $_ })
    $config.Exclusions += $logPath
    if ($incremental.Enabled) {
        $config.Exclusions += $incremental.StateDirectory
    } elseif ($MaxDirectories -gt 0 -or $MaxSeconds -gt 0) {
        throw 'Execution limits require incremental discovery.'
    }

    $logParent = [IO.DirectoryInfo]::new($logPath)
    while (-not $logParent.Exists -and $null -ne $logParent.Parent) {
        $logParent = $logParent.Parent
    }
    Assert-OrdinaryDirectory $logParent.FullName
    [void] [IO.Directory]::CreateDirectory($logPath)
    Assert-OrdinaryDirectory $logPath

    $runId = [guid]::NewGuid().ToString('N')
    $logFile = Join-Path $logPath "inventory-$runId.jsonl"
    $writer = $null
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
        newFiles = 0
        modifiedFiles = 0
        unchangedFiles = 0
        metadataUpdatesSkipped = 0
        dueFiles = 0
        deletedFiles = 0
        oversizedFiles = 0
        pendingClassification = 0
        directoriesCompleted = 0
        resumedDirectories = 0
        generation = $null
        generationComplete = $false
        generationHasErrors = $false
        recoveredIndex = $false
        stateLoadMilliseconds = 0
        enumerationMilliseconds = 0
        stateSaveMilliseconds = 0
    }
    if ($AuditContent) {
        $summary.contentAudited = 0
        $summary.contentAuditReused = 0
        $summary.contentAuditSkipped = 0
        $summary.contentAuditErrors = 0
        $summary.contentAuditFilesWithMatches = 0
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $state = $null

    $completedRoots = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $options = [IO.EnumerationOptions]::new()
    $options.AttributesToSkip = 0
    $options.IgnoreInaccessible = $false

    try {
        # Keep both the state lock and the log writer inside the same protected scope.
        # Failure opening the state must never leak a locked JSONL file.
        if ($incremental.Enabled) {
            $stateTimer = [Diagnostics.Stopwatch]::StartNew()
            $activeRoots = @($roots | Where-Object {
                $candidate = $_
                if ($config.Exclusions.Where({ Test-PathWithin $candidate $_ }, 'First').Count) {
                    $summary.excluded++
                    return $false
                }
                return $true
            })
            $scopeSettings = [ordered] @{
                roots = $activeRoots; exclusions = @($config.Exclusions | Sort-Object -Unique)
                extensions = @($config.Extensions | Sort-Object)
                maxBytes = $incremental.MaxBytes; detectDeleted = $incremental.DetectDeleted
                detectModified = $incremental.DetectModified; force = $incremental.Force; days = $incremental.Days
            }
            if ($AuditContent) { $scopeSettings.contentAudit = $config.ContentAudit.Fingerprint }
            $scopeJson = Get-StateJson $scopeSettings
            $scope = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($scopeJson)))
            $state = Open-IncrementalState $incremental $activeRoots $scope
            $summary.generation = $state.Generation
            $summary.recoveredIndex = $state.Recovered
            $summary.stateLoadMilliseconds = $stateTimer.ElapsedMilliseconds
        }
        $writer = [IO.StreamWriter]::new($logFile, $false)
        Write-InventoryEvent $writer ([ordered] @{
            event = 'start'
            schemaVersion = 1
            runId = $runId
            startedUtc = $summary.startedUtc
            roots = $roots
            incrementalEnabled = [bool] $incremental.Enabled
        })

        if ($null -ne $state) {
            Invoke-CheckpointedDiscovery $state $config $incremental $summary $writer $options $MaxDirectories $MaxSeconds
            $summary.generationHasErrors = $state.ScanErrors
        } else {
            foreach ($rootPath in $roots) {
                if ($completedRoots.Where({ Test-PathWithin $rootPath $_ }, 'First').Count) { continue }
                if ($config.Exclusions.Where({ Test-PathWithin $rootPath $_ }, 'First').Count) {
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
                    Invoke-InventoryDirectory ($pending.Pop()) $config $incremental $summary $writer $options $pending $null
                }
                # A nested root can still be useful when part of its parent was unreadable.
                if ($summary.errors -eq $errorsBeforeRoot) { $completedRoots.Add($rootPath) }
            }
        }

        $summary.enumerationMilliseconds = $timer.ElapsedMilliseconds - $summary.stateLoadMilliseconds
        if ($null -ne $state -and $state.Pending.Count -eq 0) {
            $keep = $null
            $deleted = [Collections.Generic.List[string]]::new()
            if (-not $state.ScanErrors -and $incremental.DetectDeleted) {
                $keep = {
                    param($path)
                    if (Test-KeepInventoryEntry $path $state $config $activeRoots) { return $true }
                    $deleted.Add($path)
                    return $false
                }
            }
            $saveTimer = [Diagnostics.Stopwatch]::StartNew()
            Save-IncrementalState $state $keep
            $summary.stateSaveMilliseconds = $saveTimer.ElapsedMilliseconds
            $summary.generationComplete = $true
            $summary.deletedFiles = $deleted.Count
            foreach ($path in $deleted) { Write-InventoryEvent $writer @{ event = 'deleted'; path = $path } }
        }
        $summary.elapsedMilliseconds = $timer.ElapsedMilliseconds
        Write-InventoryEvent $writer $summary
    } finally {
        try { if ($null -ne $writer) { $writer.Dispose() } }
        finally { if ($null -ne $state) { Close-IncrementalState $state } }
    }

    [pscustomobject] ($summary + @{ logFile = $logFile })
}

Export-ModuleMember -Function Invoke-LocalMIPInventory
