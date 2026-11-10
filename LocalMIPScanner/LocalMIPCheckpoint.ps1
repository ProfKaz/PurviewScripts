Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-StateJson {
    param($Record)
    ConvertTo-Json -InputObject $Record -Compress -Depth 8
}

function Read-StateJson {
    param([string] $Line)
    # System.Text.Json keeps ISO timestamps as strings on every supported PowerShell version.
    $document = [Text.Json.JsonDocument]::Parse($Line)
    try {
        if ($document.RootElement.ValueKind -ne 'Object') { throw 'Expected a JSON object.' }
        $result = @{}
        foreach ($property in $document.RootElement.EnumerateObject()) {
            if ($result.ContainsKey($property.Name)) { throw 'Duplicate JSON property.' }
            $result[$property.Name] = switch ($property.Value.ValueKind) {
                'String' { $property.Value.GetString() }
                'Number' { $property.Value.GetInt64() }
                'True' { $true }
                'False' { $false }
                'Null' { $null }
                'Object' { Read-StateJson $property.Value.GetRawText() }
                default { throw 'Unsupported JSON value in state.' }
            }
        }
        return $result
    } finally { $document.Dispose() }
}

function Assert-StateEntry {
    param([hashtable] $Item)
    if ($Item['schemaVersion'] -ne 1 -or $Item['path'] -isnot [string] -or
        $Item['path'] -notmatch '^[A-Za-z]:\\' -or
        $Item['sizeBytes'] -isnot [long] -or $Item['sizeBytes'] -lt 0 -or
        $Item['status'] -ne 'PendingClassification') { throw 'Invalid inventory entry.' }
    if ($Item.ContainsKey('lastLocalAuditUtc') -ne $Item.ContainsKey('localAuditRulesHash') -or
        ($Item.ContainsKey('localAuditRulesHash') -and
            ($Item['localAuditRulesHash'] -isnot [string] -or $Item['localAuditRulesHash'] -cnotmatch '^[0-9A-F]{64}$'))) {
        throw 'Invalid local content audit fingerprint.'
    }
    foreach ($field in 'lastWriteUtc', 'lastDiscoveredUtc', 'lastContentScannedUtc', 'lastLocalAuditUtc') {
        if (($field -eq 'lastContentScannedUtc' -and $null -eq $Item[$field]) -or
            ($field -eq 'lastLocalAuditUtc' -and -not $Item.ContainsKey($field))) { continue }
        $date = [datetime]::MinValue
        if ($Item[$field] -isnot [string] -or -not [datetime]::TryParseExact($Item[$field], 'o',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind,
                [ref] $date)) { throw "Invalid inventory timestamp: $field" }
    }
}

function New-EntryMap {
    return ,([Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase))
}

function Add-HashLine {
    param([Security.Cryptography.IncrementalHash] $Hash, [string] $Line)
    $Hash.AppendData($script:Utf8.GetBytes($Line + [char]10))
}

function Read-InventoryIndex {
    param([string] $Path, [switch] $ValidateOnly, [switch] $Legacy)
    $entries = New-EntryMap
    $reader = [IO.StreamReader]::new($Path, $script:Utf8)
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash('SHA256')
    try {
        $generation = 'baseline'
        if (-not $Legacy) {
            $line = $reader.ReadLine()
            $header = Read-StateJson $line
            if ($header['kind'] -ne 'index' -or $header['version'] -ne 2 -or
                $header['generation'] -notmatch '^(baseline|[0-9a-f]{32})$') { throw 'Invalid index header.' }
            $generation = $header.generation
            Add-HashLine $hash $line
        }
        $count = 0
        $sealed = $false
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($Legacy -and [string]::IsNullOrWhiteSpace($line)) { continue }
            $item = Read-StateJson $line
            if (-not $Legacy -and $item['kind'] -eq 'end') {
                $digest = [Convert]::ToHexString($hash.GetHashAndReset())
                if ($item['count'] -ne $count -or $item['sha256'] -cne $digest -or -not $reader.EndOfStream) {
                    throw 'Invalid index footer or checksum.'
                }
                $sealed = $true
                break
            }
            Assert-StateEntry $item
            if (-not $Legacy) { Add-HashLine $hash $line }
            if (-not $ValidateOnly) { $entries.Add($item.path, $item) }
            $count++
        }
        if (-not ($Legacy -or $sealed)) { throw 'Index footer missing.' }
        return @{ Generation = $generation; Entries = $entries }
    } finally {
        $reader.Dispose()
        $hash.Dispose()
    }
}

function New-StateWriter {
    param([IO.FileStream] $Stream)
    $writer = [IO.StreamWriter]::new($Stream, $script:Utf8, 16384, $true)
    $writer.NewLine = [string][char]10
    return $writer
}

function Write-InventoryIndex {
    param([hashtable] $State, [string] $Generation, [scriptblock] $Keep)
    $stream = [IO.File]::Open($State.Temp, 'CreateNew', 'Write', 'None')
    $writer = $null
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash('SHA256')
    try {
        $writer = New-StateWriter $stream
        $line = Get-StateJson @{ kind = 'index'; version = 2; generation = $Generation }
        $writer.WriteLine($line)
        Add-HashLine $hash $line
        $count = 0
        foreach ($entry in $State.Entries.Values) {
            if ($null -ne $Keep -and -not (& $Keep $entry.path)) { continue }
            $line = Get-StateJson $entry
            $writer.WriteLine($line)
            Add-HashLine $hash $line
            $count++
        }
        $writer.WriteLine((Get-StateJson @{ kind = 'end'; count = $count; sha256 = [Convert]::ToHexString($hash.GetHashAndReset()) }))
        $writer.Flush()
        $stream.Flush($true)
    } finally {
        try { if ($null -ne $writer) { $writer.Dispose() } }
        finally { $stream.Dispose(); $hash.Dispose() }
    }
    $null = Read-InventoryIndex $State.Temp -ValidateOnly
}

function Copy-StateFile {
    param([string] $Source, [string] $Destination, [string] $Temp, [string] $Generation)
    [IO.File]::Copy($Source, $Temp)
    $stream = [IO.File]::Open($Temp, 'Open', 'Write', 'None')
    try { $stream.Flush($true) } finally { $stream.Dispose() }
    if ((Read-InventoryIndex $Temp -ValidateOnly).Generation -ne $Generation) {
        throw 'Index generation changed while preparing a state copy.'
    }
    [IO.File]::Move($Temp, $Destination, $true)
}

function Repair-JournalTail {
    param([string] $Path)
    $stream = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
    try {
        # All durable records end in LF. A partial UTF-8 or JSON record has no LF.
        $buffer = [byte[]]::new(4096)
        $offset = $stream.Length
        while ($offset -gt 0) {
            $length = [int][Math]::Min($offset, $buffer.Length)
            $offset -= $length
            $stream.Position = $offset
            if ($stream.Read($buffer, 0, $length) -ne $length) { throw 'Could not read journal tail.' }
            $last = [Array]::LastIndexOf($buffer, [byte]10, ($length - 1), $length)
            if ($last -ge 0) {
                $end = $offset + $last + 1
                if ($end -lt $stream.Length) {
                    $stream.SetLength($end)
                    $stream.Flush($true)
                }
                return
            }
        }
        if ($stream.Length -gt 0) {
            # The header was published as a complete file. A missing LF here is corruption.
            throw 'Journal has no complete header.'
        }
    } finally { $stream.Dispose() }
}

function Get-JournalHeader {
    param([string] $Path)
    # The read buffer can extend into an incomplete tail. Validate the ASCII
    # header fields here, then decode the repaired journal strictly on replay.
    $reader = [IO.StreamReader]::new($Path, [Text.Encoding]::UTF8)
    try {
        $header = Read-StateJson $reader.ReadLine()
        if ($header['kind'] -ne 'journal' -or $header['version'] -ne 2 -or
            $header['generation'] -notmatch '^[0-9a-f]{32}$' -or
            $header['base'] -notmatch '^(baseline|[0-9a-f]{32})$' -or
            $header['base'] -eq $header['generation'] -or $header['scope'] -notmatch '^[0-9A-F]{64}$') {
            throw 'Invalid journal header.'
        }
        return $header
    } finally { $reader.Dispose() }
}

function Write-JournalRecord {
    param([hashtable] $State, [hashtable] $Record)
    $line = Get-StateJson $Record
    $State.JournalWriter.WriteLine($line)
    if ($Record.kind -in 'begin', 'child', 'seen', 'protect') { Add-HashLine $State.BatchHash $line }
}

function Get-CheckpointDigest {
    param([hashtable] $State, [bool] $Failed)
    Add-HashLine $State.BatchHash ([string] $Failed)
    return [Convert]::ToHexString($State.BatchHash.GetHashAndReset())
}

function Sync-Journal {
    param([hashtable] $State)
    $State.JournalWriter.Flush()
    $State.JournalStream.Flush($true)
}

function Add-PendingDirectory {
    param([hashtable] $State, [string] $Path)
    if ($State.Scheduled.Add($Path)) { $State.Pending.Push($Path) }
}

function Confirm-Directory {
    param([hashtable] $State, [bool] $Failed)
    [void] $State.Pending.Pop()
    foreach ($record in $State.Batch) {
        switch ($record.kind) {
            'child' { Add-PendingDirectory $State $record.path }
            'protect' { [void] $State.Protected.Add($record.path) }
            'seen' {
                [void] $State.Seen.Add($record.path)
                if ($null -ne $record['item']) { $State.Entries[$record.path] = $record.item }
            }
        }
    }
    $State.Batch.Clear()
    $State.Completed++
    $State.ScanErrors = $State.ScanErrors -or $Failed
}

function Read-ActiveJournal {
    param([hashtable] $State)
    $reader = [IO.StreamReader]::new($State.Journal, $script:Utf8)
    $active = $false
    try {
        [void] $reader.ReadLine()
        while ($null -ne ($line = $reader.ReadLine())) {
            $record = Read-StateJson $line
            if ($State.Sealed) { throw 'Unexpected record after journal end.' }
            if ($record.kind -eq 'end') {
                if ($active -or $State.Pending.Count -ne 0 -or $record.generation -ne $State.Generation) {
                    throw 'Premature journal end.'
                }
                $State.Sealed = $true
                continue
            }
            if ($State.Pending.Count -eq 0) { throw 'Unexpected journal directory.' }
            $directory = $State.Pending.Peek()
            switch ($record.kind) {
                'begin' {
                    if ($record.path -cne $directory) { throw 'Invalid journal directory begin.' }
                    $State.Batch.Clear()
                    [void] $State.BatchHash.GetHashAndReset()
                    Add-HashLine $State.BatchHash $line
                    $active = $true
                }
                'checkpoint' {
                    if (-not $active -or $record.path -cne $directory -or $record.failed -isnot [bool]) {
                        throw 'Invalid directory checkpoint.'
                    }
                    if ($record.sha256 -cne (Get-CheckpointDigest $State $record.failed)) {
                        throw 'Invalid directory checkpoint checksum.'
                    }
                    Confirm-Directory $State $record.failed
                    $active = $false
                }
                { $_ -in 'child', 'seen', 'protect' } {
                    $path = $record.path
                    if (-not $active -or $path -isnot [string] -or
                        ([IO.Path]::GetDirectoryName($path) -cne $directory -and
                            -not ($record.kind -eq 'protect' -and $path -ceq $directory))) {
                        throw 'Invalid journal directory record.'
                    }
                    if ($null -ne $record['item']) {
                        Assert-StateEntry $record.item
                        if ($record.kind -ne 'seen' -or $record.item.path -cne $path) {
                            throw 'Invalid journal entry path.'
                        }
                    }
                    $State.Batch.Add($record)
                    Add-HashLine $State.BatchHash $line
                }
                default { throw 'Unknown journal record.' }
            }
        }
    } finally {
        $reader.Dispose()
        $State.Batch.Clear()
        [void] $State.BatchHash.GetHashAndReset()
    }
}

function Close-IncrementalState {
    param([hashtable] $State)
    try {
        if ($null -ne $State.JournalWriter) { $State.JournalWriter.Dispose() }
    } finally {
        try { if ($null -ne $State.JournalStream) { $State.JournalStream.Dispose() } }
        finally {
            $State.Lock.Dispose()
            if ($null -ne $State.BatchHash) { $State.BatchHash.Dispose() }
        }
    }
}

function Open-IncrementalState {
    param([hashtable] $Settings, [string[]] $Roots, [string] $Scope)
    $directory = $Settings.StateDirectory
    $existing = [IO.DirectoryInfo]::new($directory)
    while (-not $existing.Exists -and $null -ne $existing.Parent) { $existing = $existing.Parent }
    Assert-OrdinaryDirectory $existing.FullName
    [void] [IO.Directory]::CreateDirectory($directory)
    Assert-OrdinaryDirectory $directory

    $state = @{
        File = Join-Path $directory 'inventory.index.jsonl'
        Backup = Join-Path $directory 'inventory.index.backup'
        Journal = Join-Path $directory 'inventory.active.jsonl'
        Temp = Join-Path $directory 'inventory.index.tmp'
        CopyTemp = Join-Path $directory 'inventory.copy.tmp'
        Legacy = Join-Path $directory 'inventory-state.jsonl'
        LockPath = Join-Path $directory 'inventory.lock'
        Pending = [Collections.Generic.Stack[string]]::new()
        Scheduled = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Protected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Batch = [Collections.Generic.List[hashtable]]::new()
        Completed = 0; ScanErrors = $false; Sealed = $false; Recovered = $false
        JournalWriter = $null; JournalStream = $null; BatchHash = $null
    }
    foreach ($key in 'File', 'Backup', 'Journal', 'Temp', 'CopyTemp', 'Legacy', 'LockPath') {
        try { $attributes = [IO.File]::GetAttributes($state[$key]) }
        catch [IO.FileNotFoundException] { continue }
        if ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) {
            throw "Invalid scanner state file: $($state[$key])"
        }
    }
    $state.Lock = [IO.File]::Open($state.LockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $state.BatchHash = [Security.Cryptography.IncrementalHash]::CreateHash('SHA256')
        [IO.File]::Delete($state.Temp)
        [IO.File]::Delete($state.CopyTemp)
        $index = $null
        $invalidIndex = $null
        if ([IO.File]::Exists($state.File)) {
            try { $index = Read-InventoryIndex $state.File }
            catch {
                # Sharing, permissions and other I/O errors should surface without replacing the index.
                if ($_.Exception.GetBaseException() -is [IO.IOException] -or
                    $_.Exception.GetBaseException() -is [UnauthorizedAccessException]) { throw }
                $invalidIndex = $_
            }
        }
        $header = $null
        if ([IO.File]::Exists($state.Journal)) {
            $header = Get-JournalHeader $state.Journal
            Repair-JournalTail $state.Journal
        }
        if ($null -eq $index) {
            if ([IO.File]::Exists($state.Backup)) {
                $index = Read-InventoryIndex $state.Backup
                if ($null -ne $header) {
                    if ($header.base -ne $index.Generation -and $header.generation -ne $index.Generation) {
                        [IO.File]::Delete($state.Journal)
                        $header = $null
                    }
                }
                Copy-StateFile $state.Backup $state.File $state.CopyTemp $index.Generation
                $state.Recovered = $true
            } elseif ($null -ne $invalidIndex) {
                throw "Index is invalid and no backup exists. $invalidIndex"
            } elseif ($null -ne $header) {
                throw 'Journal exists without a confirmed index or backup.'
            } else {
                $state.Entries = New-EntryMap
                if ([IO.File]::Exists($state.Legacy)) {
                    $state.Entries = (Read-InventoryIndex $state.Legacy -Legacy).Entries
                }
                Write-InventoryIndex $state 'baseline'
                [IO.File]::Move($state.Temp, $state.File)
                $index = @{ Generation = 'baseline'; Entries = $state.Entries }
            }
        }
        $state.Entries = $index.Entries
        $state.BaseGeneration = $index.Generation
        for ($i = $Roots.Count - 1; $i -ge 0; $i--) { Add-PendingDirectory $state $Roots[$i] }

        if ($null -ne $header) {
            if ($header.generation -eq $index.Generation) {
                # A previous run published the index and stopped before retiring the journal.
                [IO.File]::Delete($state.Journal)
                $header = $null
            } else {
                if ($header.base -ne $index.Generation) { throw 'Journal base does not match the confirmed index.' }
                if ($header.scope -cne $Scope) { throw 'Active journal scope changed. Resume with the original settings or archive the active journal while stopped.' }
                $state.Generation = $header.generation
                Read-ActiveJournal $state
            }
        }
        if ($null -eq $header) {
            $state.Generation = [guid]::NewGuid().ToString('N')
            $state.JournalStream = [IO.File]::Open($state.Temp, 'CreateNew', 'Write', 'None')
            $state.JournalWriter = New-StateWriter $state.JournalStream
            Write-JournalRecord $state @{ kind = 'journal'; version = 2; generation = $state.Generation
                base = $index.Generation; scope = $Scope }
            Sync-Journal $state
            $state.JournalWriter.Dispose()
            $state.JournalStream.Dispose()
            [IO.File]::Move($state.Temp, $state.Journal)
        }
        $state.JournalStream = [IO.File]::Open($state.Journal, 'Append', 'Write', 'Read')
        $state.JournalWriter = New-StateWriter $state.JournalStream
        return $state
    } catch {
        Close-IncrementalState $state
        throw
    }
}

function Add-DirectoryRecord {
    param([hashtable] $State, [hashtable] $Record)
    Write-JournalRecord $State $Record
    $State.Batch.Add($Record)
}

function Complete-StateDirectory {
    param([hashtable] $State, [string] $Path, [bool] $Failed)
    Write-JournalRecord $State @{
        kind = 'checkpoint'; path = $Path; failed = $Failed
        sha256 = Get-CheckpointDigest $State $Failed
    }
    Sync-Journal $State
    Confirm-Directory $State $Failed
}

function Save-IncrementalState {
    param([hashtable] $State, [scriptblock] $Keep)
    if (-not $State.Sealed) {
        if ($State.Pending.Count -ne 0) { throw 'Cannot seal an incomplete generation.' }
        Write-JournalRecord $State @{ kind = 'end'; generation = $State.Generation }
        Sync-Journal $State
        $State.Sealed = $true
    }
    Write-InventoryIndex $State $State.Generation $Keep
    # The confirmed primary was validated under the lock. Publish it over the sole
    # backup before replacing the primary, so either version survives either rename.
    Copy-StateFile $State.File $State.Backup $State.CopyTemp $State.BaseGeneration
    [IO.File]::Move($State.Temp, $State.File, $true)
    $State.JournalWriter.Dispose()
    $State.JournalStream.Dispose()
    $State.JournalWriter = $null
    $State.JournalStream = $null
    [IO.File]::Delete($State.Journal)
}
