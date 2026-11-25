<#PSScriptInfo
.VERSION 1.1.0
.GUID 90597121-8cef-4f5a-8319-8dcbc209e048
.AUTHOR Kaz Demos / ProfKaz
.RELEASENOTES
1.1.0 Preserve the scan session identity from the verified managed summary.
2026-11-23 1.0.0 Validate and aggregate the managed inventory contract.
#>
function Read-ManagedInventoryProjection($Directory, $Manifest, [guid]$TenantId, [string]$RegistrationId, [string]$RunId) {
    if ($Manifest.contract -cne 'ScannerPortal.InventoryRun/1' -or $Manifest.schemaVersion -ne 1 -or
        $Manifest.tenantId -ne $TenantId.ToString() -or $Manifest.registrationId -ne $RegistrationId -or
        $Manifest.batchId -cne $RunId -or @($Manifest.files).Count -ne 2) {
        throw 'Managed inventory manifest identity or schema mismatch.'
    }
    foreach ($name in 'records.jsonl','summary.json') {
        $entry=@($Manifest.files | Where-Object name -CEQ $name)
        $file=Get-Item -LiteralPath (Join-Path $Directory $name)
        if ($entry.Count -ne 1 -or $file.Length -ne $entry[0].length -or
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ine $entry[0].sha256) {
            throw "Managed inventory payload verification failed: $name"
        }
    }

    $wrapper=Get-Content -LiteralPath (Join-Path $Directory 'summary.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $summary=$wrapper.summary
    if ($wrapper.schemaVersion -ne 1 -or $wrapper.source -cne 'LocalMIPScanner.WinPS51' -or
        $wrapper.tenantId -ne $TenantId.ToString() -or $wrapper.registrationId -ne $RegistrationId -or
        $summary.runId -cne $RunId -or $summary.interrupted -or $summary.generationComplete -isnot [bool]) {
        throw 'Expected a completed scanner cycle with a verified summary. Interrupted runs require separate reporting.'
    }
    $auditEnabled=$summary.Contains('contentAudited')
    $extensions=@{}; $rules=@{}
    $counts=[ordered]@{InventoriedFiles=0;InventoryErrors=0;AnalyzedFiles=0;FilesWithMatches=0;AuditSkippedFiles=0;AuditErrors=0;ReusedFiles=0}
    $terminal=$null
    foreach ($line in [IO.File]::ReadLines((Join-Path $Directory 'records.jsonl'),[Text.Encoding]::UTF8)) {
        $event=ConvertFrom-Json -InputObject $line -AsHashtable
        if ($terminal) { throw 'Unexpected record after managed summary.' }
        switch -CaseSensitive ($event.event) {
            'file' {
                if ($event.extension -cnotmatch '^\.[a-z0-9][a-z0-9+_-]{0,31}$') { throw 'Invalid inventory extension.' }
                $extensions[$event.extension]++
                $counts.InventoriedFiles++
            }
            'error' { $counts.InventoryErrors++ }
            'summary' { $terminal=$event }
            'contentAudit' {
                if (-not $auditEnabled) { throw 'Unexpected content audit event.' }
                switch -CaseSensitive ($event.outcome) {
                    'error' { $counts.AuditErrors++ }
                    'skipped' { $counts.AuditSkippedFiles++ }
                    'completed' {
                        $counts.AnalyzedFiles++
                        if ($event.matchesByRule -isnot [Collections.IDictionary]) { throw 'Invalid local rule matches.' }
                        if ($event.matchesByRule.Count) { $counts.FilesWithMatches++ }
                        foreach ($rule in $event.matchesByRule.Keys) {
                            $matchCount=$event.matchesByRule[$rule]
                            if ($rule -notmatch '^[a-z0-9][a-z0-9_.-]{0,63}$' -or
                                $matchCount -isnot [long] -or $matchCount -lt 1) { throw 'Invalid local rule count.' }
                            if (-not $rules.ContainsKey($rule)) { $rules[$rule]=[ordered]@{RuleId=$rule;Files=0;Matches=0L} }
                            $rules[$rule].Files++
                            $rules[$rule].Matches+=$matchCount
                        }
                    }
                    default { throw 'Unexpected content audit outcome.' }
                }
            }
        }
    }
    if ($terminal.runId -cne $RunId -or $terminal.generationComplete -ne $summary.generationComplete) {
        throw 'Missing or inconsistent terminal inventory summary.'
    }
    $fields=@{InventoriedFiles='inventoried';InventoryErrors='errors'}
    if ($auditEnabled) {
        $fields.AnalyzedFiles='contentAudited';$fields.FilesWithMatches='contentAuditFilesWithMatches'
        $fields.AuditSkippedFiles='contentAuditSkipped';$fields.AuditErrors='contentAuditErrors'
        $reuse=$summary.contentAuditReused
        if ($reuse -isnot [long] -or $reuse -lt 0 -or $terminal.contentAuditReused -ne $reuse) { throw 'Invalid audit reuse count.' }
        $counts.ReusedFiles=$reuse
    }
    if ($counts.AnalyzedFiles + $counts.ReusedFiles + $counts.AuditSkippedFiles + $counts.AuditErrors -gt $counts.InventoriedFiles) {
        throw 'Audit counts exceed the inventoried file count.'
    }
    foreach ($key in $fields.Keys) {
        $value=$summary[$fields[$key]]
        if ($value -isnot [long] -or $value -ne $counts[$key] -or $terminal[$fields[$key]] -ne $value) {
            throw "Managed inventory count does not reconcile: $key"
        }
    }
    $identity = @{}
    $sourceFields = @{RunComputer='deviceName'; RunAccount='executionAccountName'; RunAccountSid='executionAccountSid'}
    foreach ($column in $sourceFields.Keys) {
        $value = $wrapper[$sourceFields[$column]]
        if ($null -eq $value -or $value -ceq '') { continue }
        if ($value -isnot [string] -or $value.Length -gt 255 -or $value -match '[\x00-\x1F\x7F]') {
            throw "Invalid scan identity in $column."
        }
        $identity[$column] = $value
    }
    [ordered]@{
        RunIdentity=$identity
        Counts=$counts
        ByExtension=@($extensions.Keys | Sort-Object | ForEach-Object { [ordered]@{Extension=$_;Files=$extensions[$_]} })
        ByOutcome=@(if ($counts.InventoriedFiles) { [ordered]@{Outcome='Inventoried';Files=$counts.InventoriedFiles} })
        Inventory=[ordered]@{
            AuditEnabled=$auditEnabled;AnalyzedFiles=$counts.AnalyzedFiles;ReusedFiles=$counts.ReusedFiles
            FilesWithMatches=$counts.FilesWithMatches;AuditSkippedFiles=$counts.AuditSkippedFiles;AuditErrors=$counts.AuditErrors
            GenerationComplete=$summary.generationComplete
            ByLocalRule=@($rules.Keys | Sort-Object | ForEach-Object { $rules[$_] })
        }
    }
}
