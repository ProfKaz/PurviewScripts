#Requires -Version 7.2
param([string] $DotNetPath, [string] $LabAssembly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) "LocalMIPScanner-M5-$([guid]::NewGuid().ToString('N'))"
$root = Join-Path $fixture 'root'
$config = Join-Path $fixture 'config'
$logs = Join-Path $fixture 'logs'
$measure = Join-Path $PSScriptRoot '../Measure-LocalMIPScanner.ps1'
try {
    [void][IO.Directory]::CreateDirectory($config)
    for ($i = 0; $i -lt 200; $i++) {
        $directory = Join-Path $root ("part-" + [Math]::Floor($i / 40))
        [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllText((Join-Path $directory "sample-$i.txt"), 'PILOT-123456')
    }
    foreach ($name in 'classifiers','extensions','performance') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../Config/$name.json") -Destination $config
    }
    Set-Content -LiteralPath "$config\exclusions.json" -Value '[]'
    @{
        enabled = $true; rescanIntervalDays = 30; detectModifiedFiles = $true
        detectDeletedFiles = $true; forceFullScan = $false; maxFileSizeMB = 1
        stateDirectory = Join-Path $fixture 'state'
    } | ConvertTo-Json | Set-Content -LiteralPath "$config\incremental.json"

    $culture = [Globalization.CultureInfo]::CurrentCulture
    try {
        [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('es-CL')
        $results = @(& $measure -Scenario Inventory,ContentAudit -Root $root -ConfigDirectory $config -LogDirectory $logs -ReportDirectory "$logs\first" -RunCount 2 -SampleMilliseconds 100 -IdleSeconds 0 -Priority BelowNormal)
    } finally { [Globalization.CultureInfo]::CurrentCulture = $culture }

    if ($results.Count -ne 4) { throw "Expected four worker reports, got $($results.Count)." }
    foreach ($result in $results) {
        if ($result.exitCode -ne 0 -or $result.cpuMilliseconds -le 0 -or $result.peakWorkingSetMiB -le 0 -or
            $result.readBytes -le 0 -or $result.samples -lt 1 -or $result.sdkPolicyLoaded) {
            throw "Invalid process measurement for $($result.scenario)."
        }
        if ($result.workload[0].inventoried -ne 200) { throw 'Measurement changed the inventory.' }
        $rows = @(Import-Csv -LiteralPath $result.samplesFile)
        if ($rows.Count -ne $result.samples -or @($rows[0].PSObject.Properties).Count -ne 7) {
            throw 'Invalid sample CSV.'
        }
        $expectedMean = 100.0 * $result.cpuMilliseconds / ($result.elapsedMilliseconds * $result.logicalProcessors)
        if ([Math]::Abs($expectedMean - $result.cpuMeanPercentOfMachine) -gt 0.02) {
            throw 'CPU normalization is inconsistent with the reported CPU time.'
        }
    }
    if ($results[2].workload[0].contentAudited -ne 200 -or $results[3].workload[0].contentAuditReused -ne 200) {
        throw 'Repeated content audit did not reuse its confirmed results.'
    }

    Set-Content -LiteralPath "$config\performance.json" -Value '{"batchSize":0,"pauseMilliseconds":0}'
    $rejected = $false
    try {
        $null = & $measure -Scenario Inventory -Root $root -ConfigDirectory $config -LogDirectory $logs -ReportDirectory "$logs\failed" -SampleMilliseconds 100 -IdleSeconds 0
    } catch {
        if ($_.Exception.Message -notlike 'Measurement worker failed*') { throw }
        $rejected = $true
    }
    $failed = Get-Content -LiteralPath "$logs\failed\Inventory-1\metrics.json" -Raw | ConvertFrom-Json
    if (-not $rejected -or $failed.exitCode -eq 0 -or (Get-Item -LiteralPath $failed.stderrFile).Length -eq 0) {
        throw 'Worker failure did not preserve its diagnostics.'
    }
    if ($DotNetPath -and $LabAssembly) {
        $sdk = & $measure -Scenario SdkSelfTest -DotNetPath $DotNetPath -LabAssembly $LabAssembly -ReportDirectory "$logs\sdk" -SampleMilliseconds 100 -IdleSeconds 0
        if ($sdk.exitCode -ne 0 -or $sdk.workload[0].nativeSdkInitialized -ne $true -or $sdk.sdkPolicyLoaded) {
            throw 'SDK self-test measurement was misclassified.'
        }
    }
    $results | Select-Object scenario,run,elapsedMilliseconds,cpuMeanPercentOfMachine,cpuPeakSamplePercentOfMachine,peakWorkingSetMiB
    'PASS: fresh workers, native counters, repeat/reuse, invariant samples and worker failure diagnostics'
} finally {
    if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture, $true) }
}
