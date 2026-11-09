Set-StrictMode -Version Latest

function Get-IncrementalSettings {
    param([string] $ConfigDirectory)
    $file = Join-Path $ConfigDirectory 'incremental.json'
    if (-not [IO.File]::Exists($file)) {
        return @{ Enabled = $false }
    }
    $raw = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    if ($raw -isnot [Collections.IDictionary]) { throw 'incremental.json must contain an object.' }
    foreach ($name in @('enabled','detectModifiedFiles','detectDeletedFiles','forceFullScan')) {
        if ($raw[$name] -isnot [bool]) { throw "incremental.json: $name must be boolean." }
    }
    foreach ($name in @('rescanIntervalDays','maxFileSizeMB')) {
        if ($raw[$name] -isnot [long] -or $raw[$name] -lt 1 -or $raw[$name] -gt 36500) {
            throw "incremental.json: $name must be an integer between 1 and 36500."
        }
    }
    if ($raw['stateDirectory'] -isnot [string] -or [string]::IsNullOrWhiteSpace($raw['stateDirectory'])) {
        throw 'incremental.json: stateDirectory must be an absolute Windows path.'
    }
    return @{
        Enabled = $raw['enabled']
        DetectModified = $raw['detectModifiedFiles']
        DetectDeleted = $raw['detectDeletedFiles']
        Force = $raw['forceFullScan']
        Days = $raw['rescanIntervalDays']
        MaxBytes = $raw['maxFileSizeMB'] * 1MB
        StateDirectory = ConvertTo-LocalPath $raw['stateDirectory']
    }
}

function Open-IncrementalState {
    param([hashtable] $Settings)
    $directory = $Settings.StateDirectory
    $existing = [IO.DirectoryInfo]::new($directory)
    while (-not $existing.Exists -and $null -ne $existing.Parent) { $existing = $existing.Parent }
    Assert-OrdinaryDirectory $existing.FullName
    [void][IO.Directory]::CreateDirectory($directory)
    Assert-OrdinaryDirectory $directory

    # FileShare.None prevents simultaneous writers; the handle stays open until the run finishes.
    $lock = [IO.FileStream]::new((Join-Path $directory 'inventory.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $entries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        $file = Join-Path $directory 'inventory-state.jsonl'
        if ([IO.File]::Exists($file)) {
            foreach ($line in [IO.File]::ReadLines($file)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $item = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop
                if ($item['schemaVersion'] -ne 1 -or
                    $item['path'] -isnot [string] -or
                    $item['sizeBytes'] -isnot [long] -or
                    $item['lastWriteUtc'] -isnot [string]) {
                    throw "Invalid incremental state entry in $file"
                }
                $entries[$item['path']] = $item
            }
        }
        return @{ Entries = $entries; File = $file; Lock = $lock }
    } catch {
        $lock.Dispose()
        throw
    }
}

function Save-IncrementalState {
    param([hashtable] $State)
    $tempFile = $State.File + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $writer = [IO.StreamWriter]::new($tempFile, $false, [Text.UTF8Encoding]::new($false))
        try {
            foreach ($entry in $State.Entries.Values) {
                $writer.WriteLine((ConvertTo-Json -InputObject $entry -Compress -Depth 8))
            }
        } finally { $writer.Dispose() }
        # Rename within the same directory; a failed write leaves the previous snapshot intact.
        [IO.File]::Move($tempFile, $State.File, $true)
    } finally {
        if ([IO.File]::Exists($tempFile)) { [IO.File]::Delete($tempFile) }
    }
}

function Get-FileInventoryDecision {
    param(
        [hashtable] $Settings,
        [Collections.Generic.Dictionary[string,object]] $Entries,
        [string] $Path,
        [long] $SizeBytes,
        [string] $LastWriteUtc,
        [datetime] $Now
    )
    $old = $null
    if (-not $Entries.TryGetValue($Path, [ref] $old)) { return 'new' }
    if ($Settings.Force) { return 'due' }
    if ($Settings.DetectModified -and
        ($old['sizeBytes'] -ne $SizeBytes -or $old['lastWriteUtc'] -ne $LastWriteUtc)) {
        return 'modified'
    }
    # Never use discovery time as evidence of a completed content scan.
    if ($old['lastContentScannedUtc'] -is [string] -and $old['lastContentScannedUtc']) {
        $lastScan = [datetime]::Parse($old['lastContentScannedUtc'],
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
        if ($Now.ToUniversalTime() -ge $lastScan.ToUniversalTime().AddDays($Settings.Days)) {
            return 'due'
        }
        return 'unchanged'
    }
    # M2 has no content classifier yet. Existing unclassified files remain pending,
    # but can be skipped for metadata refresh using the unchanged status.
    return 'unchanged'
}
