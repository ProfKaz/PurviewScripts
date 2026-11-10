Set-StrictMode -Version Latest

function Get-ContentAuditSettings {
    param([string] $ConfigDirectory)

    $path = Join-Path $ConfigDirectory 'classifiers.json'
    $json = Get-Content -LiteralPath $path -Raw
    $config = ConvertFrom-Json -InputObject $json -AsHashtable
    if ($config -isnot [Collections.IDictionary] -or
        $config['maxBytes'] -isnot [long] -or $config['maxBytes'] -lt 1 -or $config['maxBytes'] -gt 4MB -or
        $config['rules'] -isnot [array] -or $config['rules'].Count -lt 1 -or $config['rules'].Count -gt 32) {
        throw 'classifiers.json requires maxBytes (1–4194304) and 1–32 rules.'
    }

    $rules = @{}
    foreach ($rule in $config['rules']) {
        if ($rule -isnot [Collections.IDictionary] -or
            $rule['id'] -isnot [string] -or $rule['id'] -notmatch '^[a-z][a-z0-9-]{0,63}$' -or
            $rule['pattern'] -isnot [string] -or $rule['pattern'].Length -lt 1 -or $rule['pattern'].Length -gt 1024 -or
            $rules.ContainsKey($rule['id'])) {
            throw 'Each classifier needs a unique id and a pattern of 1–1024 characters.'
        }
        try {
            $rules.Add($rule['id'], [regex]::new($rule['pattern'], 'CultureInvariant', [timespan]::FromMilliseconds(100)))
        } catch {
            throw "Invalid regular expression for classifier '$($rule['id'])'."
        }
    }

    @{
        MaxBytes = $config['maxBytes']
        Rules = $rules
        Fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes("local-text-v2" + [char]10 + $json)))
    }
}

function Read-AuditText {
    param([string] $Path, [int] $Size, [string] $LastWriteUtc)

    $attributes = [IO.File]::GetAttributes($Path)
    if ($attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Offline)) {
        throw [IO.IOException]::new('File is no longer available as local text.')
    }
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    try {
        # The handle denies concurrent writes and replacement for the duration of the read.
        $timestamp = [IO.File]::GetLastWriteTimeUtc($Path).ToString('o')
        $attributes = [IO.File]::GetAttributes($Path)
        if ($stream.Length -ne $Size -or $timestamp -cne $LastWriteUtc -or
            ($attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Offline))) {
            throw [IO.IOException]::new('File metadata changed before content audit.')
        }
        $bytes = [byte[]]::new($Size)
        $offset = 0
        while ($offset -lt $Size) {
            $read = $stream.Read($bytes, $offset, $Size - $offset)
            if ($read -eq 0) { throw [IO.IOException]::new('Incomplete content read.') }
            $offset += $read
        }
        $bomLength = 0
        if ($Size -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
            $bomLength = 3
        }
        return @{ Text = $script:Utf8.GetString($bytes, $bomLength, $Size - $bomLength); Bytes = $bytes }
    } finally { $stream.Dispose() }
}

function Invoke-FileContentAudit {
    param($Audit, $Summary, $Writer, $Observation, $Previous, [string] $Extension,
        [long] $Size, [string] $LastWriteUtc, [int] $RescanDays)

    if ($Extension -notin '.txt', '.csv' -or $Size -gt $Audit.MaxBytes) {
        $reason = if ($Extension -notin '.txt', '.csv') { 'unsupportedFormat' } else { 'auditSizeLimit' }
        $Summary.contentAuditSkipped++
        Write-InventoryEvent $Writer @{ event = 'contentAudit'; path = $Observation.path; outcome = 'skipped'; reason = $reason }
        return
    }

    $now = [datetime]::UtcNow
    if (-not $Observation.ContainsKey('item') -and $Previous['localAuditRulesHash'] -ceq $Audit.Fingerprint -and
        $now -lt [datetime]::ParseExact($Previous['lastLocalAuditUtc'], 'o',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).AddDays($RescanDays)) {
        $Summary.contentAuditReused++
        return
    }

    $reason = $null
    $findings = @{}
    try {
        $content = Read-AuditText $Observation.path $Size $LastWriteUtc
        foreach ($rule in $Audit.Rules.GetEnumerator()) {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $count = 0
            $match = $rule.Value.Match($content.Text)
            while ($match.Success) {
                $count++
                if ($count -eq 1000) { break }
                $match = $match.NextMatch()
                if ($timer.ElapsedMilliseconds -gt 100) {
                    throw [Text.RegularExpressions.RegexMatchTimeoutException]::new()
                }
            }
            if ($count -gt 0) { $findings[$rule.Key] = $count }
        }
    } catch {
        $exception = $_.Exception.GetBaseException()
        $reason = switch ($exception) {
            { $_ -is [Text.DecoderFallbackException] } { 'invalidEncoding'; break }
            { $_ -is [Text.RegularExpressions.RegexMatchTimeoutException] } { 'ruleTimeout'; break }
            { $_ -is [IO.IOException] -or $_ -is [UnauthorizedAccessException] } { 'fileUnavailable'; break }
            default { throw }
        }
    }

    if ($reason) {
        $Summary.contentAuditErrors++
        Write-InventoryEvent $Writer @{ event = 'contentAudit'; path = $Observation.path; outcome = 'error'; reason = $reason }
        return
    }

    if (-not $Observation.ContainsKey('item')) {
        $Observation.item = $Previous.Clone()
    }
    $Observation.item['lastLocalAuditUtc'] = $now.ToString('o')
    $Observation.item['localAuditRulesHash'] = $Audit.Fingerprint
    $Summary.contentAudited++
    $event = @{
        event = 'contentAudit'; path = $Observation.path; outcome = 'completed'
        rulesHash = $Audit.Fingerprint; matchesByRule = $findings
    }
    if ($findings.Count -gt 0) {
        $Summary.contentAuditFilesWithMatches++
        $event.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($content.Bytes))
    }
    Write-InventoryEvent $Writer $event
}
