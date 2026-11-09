#Requires -Version 7.2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Expected, $Actual, [string] $Context)
    if ($Expected -ne $Actual) {
        throw "$Context expected [$Expected], received [$Actual]."
    }
}

$scanner = Join-Path $PSScriptRoot '../Invoke-LocalMIPScanner.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) "LocalMIPScanner-test-$([guid]::NewGuid().ToString('N'))"
$root = Join-Path $fixture 'Root'
$config = Join-Path $fixture 'Config'
$logs = Join-Path $root 'Logs'
$junction = Join-Path $root 'linked'
$rootJunction = Join-Path $fixture 'linkedRoot'

try {
    $null = New-Item -ItemType Directory -Path $config, $logs,
        "$root\Private", "$root\PrivateCopy", "$root\Nested", "$fixture\Outside"
    Set-Content -LiteralPath "$config\extensions.json" -Value '[".txt", ".csv"]'
    Set-Content -LiteralPath "$config\exclusions.json" -Value (
        ConvertTo-Json -InputObject @("$root\Private")
    )
    Set-Content -LiteralPath "$config\performance.json" -Value '{"batchSize": 2, "pauseMilliseconds": 1}'

    $expectedPaths = @("$root\sample.TXT", "$root\PrivateCopy\visible.csv", "$root\Nested\document [1].txt")
    Set-Content -LiteralPath $expectedPaths -Value 'synthetic test content'
    Set-Content -LiteralPath "$root\Private\excluded.txt", "$root\excluded.txt.bak",
        "$logs\previous.csv", "$fixture\Outside\linked.txt" -Value 'must be skipped'
    $null = New-Item -ItemType Junction -Path $junction, $rootJunction -Target "$fixture\Outside"

    $hashBefore = (Get-FileHash -LiteralPath $expectedPaths[0]).Hash
    $timeBefore = (Get-Item -LiteralPath $expectedPaths[0]).LastWriteTimeUtc
    $arguments = @{ ConfigDirectory = $config; LogDirectory = $logs }
    $result = & $scanner -Root $root, "$root\Nested", "$fixture\Missing", "$rootJunction\missing" @arguments
    $events = @(Get-Content -LiteralPath $result.logFile | ConvertFrom-Json)
    $files = @($events | Where-Object event -eq 'file')
    Assert-Equal 3 $files.Count 'Inventoried files'
    Assert-Equal 3 $result.inventoried 'Summary file count'
    Assert-Equal 2 $result.errors 'Invalid roots'
    Assert-Equal 1 $result.reparsePointsSkipped 'Junctions skipped'
    Assert-Equal 2 $result.excluded 'Excluded directories'
    Assert-Equal 'start' $events[0].event 'First event'
    Assert-Equal 'summary' $events[-1].event 'Last event'
    foreach ($path in $expectedPaths) {
        $record = @($files | Where-Object path -eq $path)
        Assert-Equal 1 $record.Count "Inventory entry for $path"
        Assert-Equal (Get-Item -LiteralPath $path).Length $record[0].sizeBytes 'Recorded length'
    }
    Assert-Equal $hashBefore (Get-FileHash -LiteralPath $expectedPaths[0]).Hash 'Document hash'
    Assert-Equal $timeBefore (Get-Item -LiteralPath $expectedPaths[0]).LastWriteTimeUtc 'Document modification time'

    $second = & $scanner -Root $root @arguments
    Assert-Equal 3 $second.inventoried 'Repeat inventory'
    Assert-Equal 0 $second.errors 'Clean scan errors'
    Assert-Equal $false ($result.logFile -eq $second.logFile) 'Distinct run logs'

    $blocked = "$root\Denied"
    $null = New-Item -ItemType Directory -Path $blocked
    Set-Content -LiteralPath "$blocked\hidden.txt" -Value 'access denied fixture'
    $originalAcl = Get-Acl -LiteralPath $blocked
    $restrictedAcl = Get-Acl -LiteralPath $blocked
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $deny = [Security.AccessControl.FileSystemAccessRule]::new($user, 'ListDirectory', 'Deny')
    $restrictedAcl.AddAccessRule($deny)
    try {
        Set-Acl -LiteralPath $blocked -AclObject $restrictedAcl
        $partial = & $scanner -Root $root @arguments
        Assert-Equal 3 $partial.inventoried 'Accessible files in partial scan'
        Assert-Equal 1 $partial.errors 'Access denied recorded'
        $errorEvents = @(Get-Content -LiteralPath $partial.logFile | ConvertFrom-Json | Where-Object event -eq 'error')
        Assert-Equal 1 $errorEvents.Count 'Access error log entries'
        Assert-Equal $blocked $errorEvents[0].path 'Access error path'
    } finally {
        Set-Acl -LiteralPath $blocked -AclObject $originalAcl
    }

    Set-Content -LiteralPath "$config\exclusions.json" -Value '[]'
    Set-Content -LiteralPath "$config\extensions.json" -Value '[".txt"]'
    $singleExtension = & $scanner -Root "$root\Nested" @arguments
    Assert-Equal 1 $singleExtension.inventoried 'Single extension and empty exclusions'

    Set-Content -LiteralPath "$config\performance.json" -Value '{"batchSize": 0, "pauseMilliseconds": 0}'
    $rejected = $false
    try {
        $null = & $scanner -Root $root @arguments
    } catch {
        if ($_.Exception.Message -notlike 'performance.json requires*') { throw }
        $rejected = $true
    }
    Assert-Equal $true $rejected 'Invalid configuration rejected'
    'PASS: inventory, scope, junctions, errors, log schema, source integrity, repeat scans and configuration'
} finally {
    if (Test-Path -LiteralPath $rootJunction) { [IO.Directory]::Delete($rootJunction) }
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    $resolved = Get-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
    if ($resolved -and $resolved.Parent.FullName -eq [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetTempPath()) -and
        $resolved.Name -match '^LocalMIPScanner-test-[0-9a-f]{32}$' -and
        -not ($resolved.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $resolved.FullName -Recurse -Force
    }
}
