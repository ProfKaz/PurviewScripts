<#PSScriptInfo
.VERSION 1.1.0
.GUID 53e799ae-9259-4aad-b6ec-e6444244efb2
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.PROJECTURI https://github.com/ProfKaz/PurviewScripts
.RELEASENOTES
2026-11-18  1.1.0  Consolidated Endpoint MIP Scanner layout, shared lab and unified setup.
Tracking ID: 53e799ae-9259-4aad-b6ec-e6444244efb2
#>
<#
HISTORY
Script      : LocalMIPScanner.WinPS51/WinPSCompatibility.ps1
Version     : 1.1.0
Tracking ID : 53e799ae-9259-4aad-b6ec-e6444244efb2
2026-11-18  Kaz Demos  First tracked suite release; preserves prior milestone implementation.
#>
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
