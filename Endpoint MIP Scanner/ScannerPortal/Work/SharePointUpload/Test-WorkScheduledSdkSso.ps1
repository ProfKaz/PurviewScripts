<#PSScriptInfo
.VERSION 0.1.0
.GUID c614da41-0173-40bc-b364-47460fcc3483
.AUTHOR Kaz Demos / ProfKaz
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$ClientId,
    [Parameter(Mandatory)][string]$ExpectedUser,
    [Parameter(Mandatory)][string]$Assembly,
    [string]$Dotnet = (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe')
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this test from a non-elevated Windows PowerShell session.'
}
foreach ($file in @($Dotnet, $Assembly)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing SDK component: $file" }
}
$taskName = 'EndpointMIPScanner-W08A3-' + [guid]::NewGuid().ToString('N')
$pilot = Join-Path $env:LOCALAPPDATA "EndpointMIPScanner\Tests\$taskName"
$root = Join-Path $pilot 'EmptyDocuments'
$null = New-Item -ItemType Directory -Path $root -Force
$config = Join-Path $pilot 'policy-audit.json'
$log = Join-Path $pilot 'check-sso.jsonl'
$stderr = Join-Path $pilot 'check-sso.stderr.txt'
$resultPath = Join-Path $pilot 'task-result.json'
@{
    tenantId = $TenantId.ToString()
    clientId = $ClientId.ToString()
    expectedUser = $ExpectedUser
    roots = @($root)
    rules = @(@{ ruleId = 'synthetic-pilot-id'; sitId = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'; confidence = 85 })
    maxFiles = 1
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding UTF8
$paramsFile = Join-Path $pilot 'task-params.json'
@{
    Dotnet = (Get-Item -LiteralPath $Dotnet).FullName
    Assembly = (Get-Item -LiteralPath $Assembly).FullName
    Config = $config; Log = $log; Stderr = $stderr; Result = $resultPath
} | ConvertTo-Json | Set-Content -LiteralPath $paramsFile -Encoding UTF8

$payload = @'
$ErrorActionPreference = 'Stop'
$p = Get-Content -LiteralPath '__PARAMS_FILE__' -Raw | ConvertFrom-Json
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$r = [ordered]@{
    Sid = $identity.User.Value
    AdministratorToken = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    ExitCode = $null
    Error = $null
}
try {
    $arguments = '"' + $p.Assembly + '" --check-sso "' + $p.Config + '"'
    $start = @{
        FilePath = $p.Dotnet; ArgumentList = $arguments; WindowStyle = 'Hidden'
        RedirectStandardOutput = $p.Log; RedirectStandardError = $p.Stderr
        PassThru = $true; Wait = $true
    }
    $process = Start-Process @start
    $r.ExitCode = $process.ExitCode
}
catch { $r.Error = $_.Exception.Message }
$temp = $p.Result + '.tmp'
$r | ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
[IO.File]::Move($temp, $p.Result)
'@
$payload = $payload.Replace('__PARAMS_FILE__', $paramsFile.Replace("'", "''"))
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
$action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
$registered = $false
try {
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Settings $settings
    $registered = $true
    Start-ScheduledTask -TaskName $taskName
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) { break }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        $code = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
        throw "Task result unavailable. LastTaskResult: $code. Logs: $pilot"
    }
    $actual = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    $events = @()
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        $events = @(Get-Content -LiteralPath $log -Encoding UTF8 | Where-Object { $_.Trim() } |
            ForEach-Object { ConvertFrom-Json -InputObject $_ })
    }
    $silent = @($events | Where-Object {
        $_.event -eq 'authentication' -and $_.mode -eq 'windowsSilent' -and $_.outcome -eq 'authenticated'
    }).Count -gt 0
    $policy = $events | Where-Object event -eq 'policy' | Select-Object -First 1
    $sameUser = $actual.Sid -eq $identity.User.Value
    $outcome = 'Mismatch'
    if ($sameUser -and -not $actual.AdministratorToken -and $null -ne $actual.ExitCode -and
        $actual.ExitCode -eq 0 -and $silent -and $null -ne $policy) { $outcome = 'Verified' }
    $publishedLabels = $null
    if ($policy) { $publishedLabels = $policy.publishedLabelCount }
    $summary = [ordered]@{
        Outcome = $outcome
        SameUserSid = $sameUser
        AdministratorToken = $actual.AdministratorToken
        ExitCode = $actual.ExitCode
        WindowsSilent = $silent
        PolicyLoaded = $null -ne $policy
        PublishedLabels = $publishedLabels
        SdkErrors = @($events | Where-Object event -eq 'error' | Select-Object stage,type,reason,authError)
        TaskError = $actual.Error
        Log = $log
        StderrLog = $stderr
    }
    Write-Host '=== WORK W08A.3 FOR SHARING ===' -ForegroundColor Magenta
    Write-Host ($summary | ConvertTo-Json -Depth 5) -ForegroundColor Magenta
}
finally {
    if ($registered) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
