#Requires -Version 5.1
#Requires -PSEdition Desktop

Add-Type -AssemblyName System.Web.Extensions
$script:WinPSJson = New-Object System.Web.Script.Serialization.JavaScriptSerializer

function Convert-WinPSJsonValue {
    param($Value)
    if ($Value -is [Collections.IDictionary]) {
        $map = @{}
        foreach ($key in $Value.Keys) {
            if ($map.ContainsKey($key)) { throw 'Ambiguous JSON key.' }
            $map[$key] = Convert-WinPSJsonValue $Value[$key]
        }
        return $map
    }
    if ($Value -is [array]) {
        return ,@(foreach ($item in $Value) { Convert-WinPSJsonValue $item })
    }
    if ($Value -is [int]) { return [long]$Value }
    return $Value
}

function ConvertFrom-WinPSJson {
    param([Parameter(ValueFromPipeline=$true)][string] $InputObject)
    process {
        $value = Convert-WinPSJsonValue ($script:WinPSJson.DeserializeObject($InputObject))
        return ,$value
    }
}

function Get-WinPSFullPath {
    param([string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\')
}

function ConvertTo-WinPSHex {
    param([byte[]] $Bytes)
    return [BitConverter]::ToString($Bytes).Replace('-', '')
}

function Get-WinPSSha256 {
    param([byte[]] $Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { ConvertTo-WinPSHex ($hash.ComputeHash($Bytes)) }
    finally { $hash.Dispose() }
}

function Publish-WinPSFile {
    param([string] $Source, [string] $Destination)
    if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($Source, $Destination, [NullString]::Value) }
    else { [IO.File]::Move($Source, $Destination) }
}

function Join-WinPSNativeArguments {
    param([string[]] $Values)
    ($Values | ForEach-Object {
        '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }) -join ' '
}
