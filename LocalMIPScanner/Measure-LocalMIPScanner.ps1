#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Inventory', 'ContentAudit', 'PolicyAudit', 'SdkSelfTest')]
    [string[]] $Scenario = @('Inventory'),
    [string[]] $Root,
    [string] $ConfigDirectory = (Join-Path $PSScriptRoot 'Config'),
    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'LocalMIPScanner\Logs'),
    [string] $PolicyConfig,
    [string] $AuditLog,
    [string] $DotNetPath,
    [string] $LabAssembly,
    [ValidateRange(1, 20)][int] $RunCount = 1,
    [ValidateRange(100, 10000)][int] $SampleMilliseconds = 1000,
    [ValidateRange(0, 3600)][int] $IdleSeconds = 5,
    [ValidateSet('Normal', 'BelowNormal', 'Idle')][string] $Priority = 'Normal',
    [ValidateRange(0, 2147483647)][int] $MaxSeconds = 0,
    [ValidateRange(0, 2147483647)][int] $MaxDirectories = 0,
    [string] $ReportDirectory = (Join-Path $LogDirectory "Measurements\$([guid]::NewGuid().ToString('N'))")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Resource measurement requires Windows.' }
$Scenario = @($Scenario | Select-Object -Unique)
$scan = @($Scenario | Where-Object { $_ -in 'Inventory','ContentAudit' })
$sdk = @($Scenario | Where-Object { $_ -in 'PolicyAudit','SdkSelfTest' })
if ($scan.Count -gt 0 -and ($null -eq $Root -or $Root.Count -eq 0)) {
    throw 'Specify -Root for inventory or content audit measurements.'
}
if ($sdk.Count -gt 0) {
    if (-not $DotNetPath) {
        $command = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue
        $DotNetPath = if ($command) { $command.Source } else { Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe' }
    }
    if (-not $LabAssembly) {
        $LabAssembly = @(
            Join-Path $PSScriptRoot 'labs/MipSdkAudit/bin/installer/net10.0/MipSdkAudit.dll'
            Join-Path $PSScriptRoot '../labs/MipSdkAudit/bin/installer/net10.0/MipSdkAudit.dll'
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }
    if (-not $LabAssembly -or -not (Test-Path -LiteralPath $LabAssembly -PathType Leaf) -or
        -not (Test-Path -LiteralPath $DotNetPath -PathType Leaf)) {
        throw 'Specify -DotNetPath and -LabAssembly from the lab installation result.'
    }
}
if ('PolicyAudit' -in $Scenario -and (-not $PolicyConfig -or -not $AuditLog)) {
    throw 'PolicyAudit requires -PolicyConfig and a completed content -AuditLog.'
}

function Resolve-MeasurementPath {
    param([string] $Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

$ReportDirectory = Resolve-MeasurementPath $ReportDirectory
$ConfigDirectory = Resolve-MeasurementPath $ConfigDirectory
$LogDirectory = Resolve-MeasurementPath $LogDirectory
if ($scan.Count -gt 0 -and -not $ReportDirectory.StartsWith(
        $LogDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'For scanner measurements, -ReportDirectory must be inside -LogDirectory so the measurement files are excluded.'
}
if ($PolicyConfig) { $PolicyConfig = (Get-Item -LiteralPath $PolicyConfig).FullName }
if ($AuditLog) { $AuditLog = (Get-Item -LiteralPath $AuditLog).FullName }
if ($DotNetPath) { $DotNetPath = (Get-Item -LiteralPath $DotNetPath).FullName }
if ($LabAssembly) { $LabAssembly = (Get-Item -LiteralPath $LabAssembly).FullName }
$policyHash = $null
$auditHash = $null
$filePause = $null
if ($PolicyConfig) {
    $policyHash = (Get-FileHash -LiteralPath $PolicyConfig -Algorithm SHA256).Hash
    $policySettings = Get-Content -LiteralPath $PolicyConfig -Raw | ConvertFrom-Json -AsHashtable
    $filePause = if ($policySettings.ContainsKey('filePauseMilliseconds')) { $policySettings['filePauseMilliseconds'] } else { 0 }
}
if ($AuditLog) { $auditHash = (Get-FileHash -LiteralPath $AuditLog -Algorithm SHA256).Hash }
if ($Root) { $Root = @($Root | ForEach-Object { Resolve-MeasurementPath $_ }) }
if ([IO.Directory]::Exists($ReportDirectory) -and [IO.Directory]::EnumerateFileSystemEntries($ReportDirectory).GetEnumerator().MoveNext()) {
    throw 'Choose an empty -ReportDirectory for a new measurement.'
}
[void] [IO.Directory]::CreateDirectory($ReportDirectory)

if (-not ('LocalMIPScannerMeasurement.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace LocalMIPScannerMeasurement
{
    public sealed class Snapshot
    {
        public double CpuMilliseconds;
        public ulong WorkingSet, PeakWorkingSet, PrivateBytes;
        public ulong ReadBytes, WriteBytes, OtherBytes;
        public bool MemoryAvailable, IoAvailable;
    }
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperations, WriteOperations, OtherOperations;
            public ulong ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryCounters
        {
            public uint Size, PageFaultCount;
            public UIntPtr PeakWorkingSet, WorkingSet, PeakPagedPool, PagedPool;
            public UIntPtr PeakNonPagedPool, NonPagedPool, Pagefile, PeakPagefile, PrivateUsage;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessIoCounters(IntPtr process, out IoCounters counters);
        [DllImport("kernel32.dll", EntryPoint = "K32GetProcessMemoryInfo", SetLastError = true)]
        private static extern bool GetMemory(IntPtr process, ref MemoryCounters counters, uint size);

        public static Snapshot Read(IntPtr process)
        {
            long creation, exit, kernel, user;
            if (!GetProcessTimes(process, out creation, out exit, out kernel, out user))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var snapshot = new Snapshot { CpuMilliseconds = (kernel + user) / 10000.0 };
            IoCounters io;
            snapshot.IoAvailable = GetProcessIoCounters(process, out io);
            if (snapshot.IoAvailable)
            {
                snapshot.ReadBytes = io.ReadBytes;
                snapshot.WriteBytes = io.WriteBytes;
                snapshot.OtherBytes = io.OtherBytes;
            }
            var memory = new MemoryCounters { Size = (uint)Marshal.SizeOf<MemoryCounters>() };
            snapshot.MemoryAvailable = GetMemory(process, ref memory, memory.Size);
            if (snapshot.MemoryAvailable)
            {
                snapshot.WorkingSet = memory.WorkingSet.ToUInt64();
                snapshot.PeakWorkingSet = memory.PeakWorkingSet.ToUInt64();
                snapshot.PrivateBytes = memory.PrivateUsage.ToUInt64();
            }
            return snapshot;
        }
    }
}
'@
}

$reports = [Collections.Generic.List[object]]::new()
$logicalProcessors = [Environment]::ProcessorCount
foreach ($scenarioName in $Scenario) {
    for ($run = 1; $run -le $RunCount; $run++) {
        $directory = Join-Path $ReportDirectory "$scenarioName-$run"
        [void] [IO.Directory]::CreateDirectory($directory)
        $stdoutPath = Join-Path $directory 'stdout.jsonl'
        $stderrPath = Join-Path $directory 'stderr.txt'
        $samplesPath = Join-Path $directory 'samples.csv'
        $metricsPath = Join-Path $directory 'metrics.json'
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        if ($scenarioName -in 'Inventory','ContentAudit') {
            $parameters = @{
                Root = $Root; ConfigDirectory = $ConfigDirectory; LogDirectory = $LogDirectory
                MaxSeconds = $MaxSeconds; MaxDirectories = $MaxDirectories
                AuditContent = $scenarioName -eq 'ContentAudit'
            }
            $job = @{ Scanner = Join-Path $PSScriptRoot 'Invoke-LocalMIPScanner.ps1'; Parameters = $parameters }
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($job | ConvertTo-Json -Compress -Depth 5)))
            $worker = @'
$ErrorActionPreference = 'Stop'
try {
    $job = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('PAYLOAD')) | ConvertFrom-Json -AsHashtable
    $parameters = $job.Parameters
    $result = & $job.Scanner @parameters
    $result | ConvertTo-Json -Compress -Depth 8
    exit 0
} catch {
    [Console]::Error.WriteLine($_.ToString())
    exit 1
}
'@
            $worker = $worker.Replace('PAYLOAD', $payload)
            $startInfo.FileName = Join-Path $PSHOME 'pwsh.exe'
            $startInfo.ArgumentList.Add('-NoProfile')
            $startInfo.ArgumentList.Add('-NonInteractive')
            $startInfo.ArgumentList.Add('-EncodedCommand')
            $startInfo.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker)))
        } else {
            $startInfo.FileName = $DotNetPath
            $startInfo.ArgumentList.Add($LabAssembly)
            if ($scenarioName -eq 'SdkSelfTest') {
                $startInfo.ArgumentList.Add('--self-test')
            } else {
                foreach ($argument in '--config',$PolicyConfig,'--audit-log',$AuditLog) { $startInfo.ArgumentList.Add($argument) }
            }
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $stdout = $null; $stderr = $null; $sampleWriter = $null
        $outputTask = $null; $errorTask = $null
        $started = $false
        $controller = [Diagnostics.Process]::GetCurrentProcess()
        $controllerStart = $controller.TotalProcessorTime
        $timer = [Diagnostics.Stopwatch]::new()
        $startedUtc = [datetime]::UtcNow.ToString('o')
        $lastCpu = 0.0; $lastElapsed = 0.0; $peakCpu = 0.0
        $peakWorkingSet = [ulong]0; $sampledWorkingSet = [ulong]0; $sampledPrivate = [ulong]0
        $readBytes = $null; $writeBytes = $null; $otherBytes = $null
        $sampleCount = 0
        $memorySamples = 0
        try {
            $stdout = [IO.File]::Open($stdoutPath, 'CreateNew', 'Write', 'Read')
            $stderr = [IO.File]::Open($stderrPath, 'CreateNew', 'Write', 'Read')
            $sampleWriter = [IO.StreamWriter]::new($samplesPath, $false, [Text.UTF8Encoding]::new($false))
            $sampleWriter.WriteLine('elapsedMilliseconds,cpuPercentOfMachine,workingSetBytes,privateBytes,readBytes,writeBytes,otherBytes')
            $timer.Start()
            if (-not $process.Start()) { throw 'Could not start the measurement worker.' }
            $started = $true
            $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::$Priority
            $handle = $process.Handle
            $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
            $errorTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
            do {
                $exited = $process.HasExited
                $snapshot = [LocalMIPScannerMeasurement.Native]::Read($handle)
                $elapsed = $timer.Elapsed.TotalMilliseconds
                $cpu = 100.0 * ($snapshot.CpuMilliseconds - $lastCpu) / (($elapsed - $lastElapsed) * $logicalProcessors)
                if ($sampleCount -gt 0 -or $exited) { $peakCpu = [Math]::Max($peakCpu, $cpu) }
                $lastCpu = $snapshot.CpuMilliseconds
                $lastElapsed = $elapsed
                if ($snapshot.IoAvailable) {
                    $readBytes = $snapshot.ReadBytes; $writeBytes = $snapshot.WriteBytes; $otherBytes = $snapshot.OtherBytes
                }
                $workingSet = $null; $privateBytes = $null
                if ($snapshot.MemoryAvailable) {
                    $memorySamples++
                    $workingSet = $snapshot.WorkingSet; $privateBytes = $snapshot.PrivateBytes
                    $peakWorkingSet = [Math]::Max($peakWorkingSet, $snapshot.PeakWorkingSet)
                    $sampledWorkingSet = [Math]::Max($sampledWorkingSet, $snapshot.WorkingSet)
                    $sampledPrivate = [Math]::Max($sampledPrivate, $snapshot.PrivateBytes)
                }
                $sampleWriter.WriteLine(([string]::Join(',', [string[]]@(
                    $elapsed.ToString('F2', [Globalization.CultureInfo]::InvariantCulture),
                    $cpu.ToString('F2', [Globalization.CultureInfo]::InvariantCulture),
                    $workingSet, $privateBytes, $readBytes, $writeBytes, $otherBytes
                ))))
                $sampleCount++
                if (-not $exited) { [void] $process.WaitForExit($SampleMilliseconds) }
            } while (-not $exited)
            $timer.Stop()
            [void] $outputTask.GetAwaiter().GetResult()
            [void] $errorTask.GetAwaiter().GetResult()
            $exitCode = $process.ExitCode
        } finally {
            try {
                if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                if ($null -ne $outputTask) { [void] $outputTask.GetAwaiter().GetResult() }
                if ($null -ne $errorTask) { [void] $errorTask.GetAwaiter().GetResult() }
            } finally {
                if ($null -ne $sampleWriter) { $sampleWriter.Dispose() }
                if ($null -ne $stdout) { $stdout.Dispose() }
                if ($null -ne $stderr) { $stderr.Dispose() }
                $process.Dispose()
                $controller.Refresh()
                $controllerCpu = ($controller.TotalProcessorTime - $controllerStart).TotalMilliseconds
                $controller.Dispose()
            }
        }

        $events = @([IO.File]::ReadLines($stdoutPath) | Where-Object { $_ } | ConvertFrom-Json -AsHashtable)
        $workload = @($events | Where-Object { $_['event'] -in 'summary','auditSummary','policy','selfTest','error' })
        $performance = $null
        if ($scenarioName -in 'Inventory','ContentAudit') {
            $performance = Get-Content -LiteralPath (Join-Path $ConfigDirectory 'performance.json') -Raw | ConvertFrom-Json -AsHashtable
        }
        $report = [pscustomobject][ordered]@{
            schemaVersion = 1; scenario = $scenarioName; run = $run; startedUtc = $startedUtc; exitCode = $exitCode
            logicalProcessors = $logicalProcessors; sampleMilliseconds = $SampleMilliseconds; samples = $sampleCount
            memorySamples = $memorySamples
            priority = $Priority
            elapsedMilliseconds = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
            cpuMilliseconds = [Math]::Round($lastCpu, 2)
            cpuMeanPercentOfMachine = [Math]::Round(100.0 * $lastCpu / ($timer.Elapsed.TotalMilliseconds * $logicalProcessors), 2)
            cpuPeakSamplePercentOfMachine = [Math]::Round($peakCpu, 2)
            peakWorkingSetMiB = if ($memorySamples -gt 0) { [Math]::Round($peakWorkingSet / 1MB, 2) }
            sampledPeakWorkingSetMiB = if ($memorySamples -gt 0) { [Math]::Round($sampledWorkingSet / 1MB, 2) }
            sampledPeakPrivateCommitMiB = if ($memorySamples -gt 0) { [Math]::Round($sampledPrivate / 1MB, 2) }
            readBytes = $readBytes; writeBytes = $writeBytes; otherIoBytes = $otherBytes
            controllerCpuMilliseconds = [Math]::Round($controllerCpu, 2)
            sdkPolicyLoaded = [bool]@($events | Where-Object { $_['event'] -eq 'policy' }).Count
            root = $Root; configDirectory = $ConfigDirectory; logDirectory = $LogDirectory; performance = $performance
            policyConfig = $PolicyConfig; auditLog = $AuditLog; labAssembly = $LabAssembly; dotNetPath = $DotNetPath
            policyConfigSha256 = $policyHash; auditLogSha256 = $auditHash; filePauseMilliseconds = $filePause
            maxSeconds = $MaxSeconds; maxDirectories = $MaxDirectories
            workload = $workload; samplesFile = $samplesPath; stdoutFile = $stdoutPath; stderrFile = $stderrPath
            metricsFile = $metricsPath
        }
        $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $metricsPath -Encoding utf8
        $reports.Add($report)
        ConvertTo-Json -InputObject @($reports.ToArray()) -Depth 12 |
            Set-Content -LiteralPath (Join-Path $ReportDirectory 'summary.json') -Encoding utf8
        $report
        if ($exitCode -ne 0) { throw "Measurement worker failed with exit code $exitCode. Results are in $directory." }
        if ($IdleSeconds -gt 0 -and ($run -lt $RunCount -or $scenarioName -ne $Scenario[-1])) {
            Start-Sleep -Seconds $IdleSeconds
        }
    }
}
