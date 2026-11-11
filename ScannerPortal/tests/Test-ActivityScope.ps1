#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../src/ScannerPortal.Activity.psm1') -Force

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-True $thrown $Message
}

foreach ($invalid in @($null, @(), @(''), @('   '), @('*@example.invalid'), @('svc?'), @('[svc]'))) {
    Assert-Throws { New-ScannerActivityQuery -ServiceAccounts $invalid } 'Unsafe account scope accepted by query builder.'
    Assert-Throws { Select-ScannerActivityRecord -Records @() -ServiceAccounts $invalid } 'Unsafe account scope accepted by record filter.'
}
$accounts = @(' SCANNER-A@example.invalid ', 'scanner-b@example.invalid', 'scanner-a@example.invalid')
$query = New-ScannerActivityQuery -ServiceAccounts $accounts -Activities LabelApplied,LabelChanged -Workloads OnPremisesFileShareScanner
Assert-True ($query.Count -eq 3) 'Combined query must have three filters.'
Assert-True (($query.Filter1 -join ',') -eq 'User,scanner-a@example.invalid,scanner-b@example.invalid') 'Account normalization/deduplication failed.'
Assert-True (($query.Filter2 -join ',') -eq 'Activity,LabelApplied,LabelChanged') 'Activity filter changed.'
Assert-True (($query.Filter3 -join ',') -eq 'Workload,OnPremisesFileShareScanner') 'Workload filter changed.'
$workloadOnly = New-ScannerActivityQuery -ServiceAccounts $accounts -Workloads Endpoint
Assert-True ($workloadOnly.ContainsKey('Filter2') -and -not $workloadOnly.ContainsKey('Filter3')) 'Filter numbering must remain consecutive.'
$userOnly = New-ScannerActivityQuery -ServiceAccounts $accounts
Assert-True ($userOnly.Count -eq 1) 'User-only scope must still restrict export.'
Assert-Throws { New-ScannerActivityQuery -ServiceAccounts $accounts -Activities '*' } 'Wildcard activity accepted.'
Assert-Throws { New-ScannerActivityQuery -ServiceAccounts $accounts -Workloads '' } 'Empty workload accepted.'

$records = @(
    [pscustomobject]@{ Id = 1; User = 'SCANNER-A@example.invalid' },
    @{ Id = 2; User = ' scanner-b@example.invalid ' },
    [ordered]@{ Id = 3; User = 'scanner-a@example.invalid' },
    @{ Id = 4; User = 'unrelated@example.invalid' },
    @{ Id = 5; User = 'scanner-a@example.invalid.attacker.invalid' },
    @{ Id = 6; User = @('scanner-a@example.invalid', 'unrelated@example.invalid') },
    @{ Id = 7; UserId = 'scanner-a@example.invalid' },
    @{ Id = 8; User = $null },
    @{ Id = 9; User = 123 },
    [pscustomobject]@{ Id = 10 },
    $null
)
$selected = @(Select-ScannerActivityRecord -Records $records -ServiceAccounts $accounts)
Assert-True (($selected.Id -join ',') -eq '1,2,3') 'Unknown, malformed, or ambiguous user leaked into output.'
$explicit = @(Select-ScannerActivityRecord -Records @(@{ UserId = 'scanner-a@example.invalid' }) -ServiceAccounts $accounts -UserField UserId)
Assert-True ($explicit.Count -eq 1) 'Explicit source schema mapping failed.'
$empty = @(Select-ScannerActivityRecord -Records @() -ServiceAccounts $accounts)
Assert-True ($empty.Count -eq 0) 'Empty source should remain empty.'

# Parse all shipped JSON examples; validates syntax only, not future JSON Schema.
Get-ChildItem (Join-Path $PSScriptRoot '..') -Recurse -Filter '*.json' | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Out-Null
}
'PASS: account scope, consecutive server filters, exact pre-output filtering, malformed identities, and JSON syntax.'
