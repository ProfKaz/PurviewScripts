#Requires -Version 7.2
Set-StrictMode -Version Latest

function Get-ScannerAccountSet {
    param([AllowNull()][AllowEmptyCollection()][string[]]$ServiceAccounts)
    if (-not $ServiceAccounts -or $ServiceAccounts.Count -eq 0) {
        throw 'At least one explicit scanner service account is required.'
    }
    $accounts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($account in $ServiceAccounts) {
        if ([string]::IsNullOrWhiteSpace($account) -or $account -match '[*?\[\]]') {
            throw 'Scanner accounts must be nonempty exact identities, without wildcards.'
        }
        [void]$accounts.Add($account.Trim().ToLowerInvariant())
    }
    # Prevent PowerShell from enumerating the set on return.
    return ,$accounts
}

function New-ScannerActivityQuery {
    <# .SYNOPSIS
    Builds server-side filter parameters; does not connect to Purview.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$ServiceAccounts,
        [string[]]$Activities = @(),
        [string[]]$Workloads = @()
    )
    $accounts = Get-ScannerAccountSet $ServiceAccounts
    $query = @{ Filter1 = @('User') + @($accounts | Sort-Object) }
    $next = 2
    foreach ($selection in @(
        @{ Name = 'Activity'; Values = $Activities },
        @{ Name = 'Workload'; Values = $Workloads }
    )) {
        if ($null -eq $selection.Values -or $selection.Values.Count -eq 0) { continue }
        foreach ($value in $selection.Values) {
            if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[*?\[\]]') {
                throw 'Activity and workload selections must contain exact nonempty values.'
            }
        }
        $query["Filter$next"] = @($selection.Name) + @($selection.Values | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
        $next++
    }
    return $query
}

function Select-ScannerActivityRecord {
    <# .SYNOPSIS
    Filters before any output destination. Unknown or malformed identity is rejected.
    .DESCRIPTION
    UserField must be approved against the source schema. No fallback identity inference.
    Caller must separately detect schema drift and prevent checkpoint confirmation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Records,
        [AllowNull()][AllowEmptyCollection()][string[]]$ServiceAccounts,
        [ValidateNotNullOrEmpty()][string]$UserField = 'User'
    )
    $accounts = Get-ScannerAccountSet $ServiceAccounts
    foreach ($record in $Records) {
        if ($null -eq $record) { continue }
        $identity = $null
        if ($record -is [Collections.IDictionary]) {
            if ($record.Contains($UserField)) { $identity = $record[$UserField] }
        } else {
            $property = $record.PSObject.Properties[$UserField]
            if ($null -ne $property) { $identity = $property.Value }
        }
        if ($identity -is [string] -and $accounts.Contains($identity.Trim())) {
            Write-Output $record
        }
    }
}

Export-ModuleMember -Function New-ScannerActivityQuery, Select-ScannerActivityRecord
