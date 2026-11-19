<#PSScriptInfo
.VERSION 1.1.0
.GUID 3832d82b-5823-4ecd-b062-801856020826
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.PROJECTURI https://github.com/ProfKaz/PurviewScripts
.RELEASENOTES
2026-11-18  1.1.0  Validate suite layout and PS5.1 syntax after consolidation.
#>
<#
HISTORY
Script      : tests/Test-SuiteLayout.ps1
Version     : 1.1.0
Tracking ID : 3832d82b-5823-4ecd-b062-801856020826
2026-11-18  Kaz Demos  Initial regression check for relocated scripts.
#>
#Requires -Version 5.1
param([string]$Root)
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference='Stop'
$manifest=Get-Content -LiteralPath (Join-Path $Root 'suite-manifest.json') -Raw | ConvertFrom-Json
$ids=@{}
foreach($script in $manifest.Scripts){
 $path=Join-Path $Root $script.Path
 if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing script: $path"}
 $text=[IO.File]::ReadAllText($path)
 if($text -notmatch ("(?m)^\.GUID "+[regex]::Escape($script.TrackingId)+"\r?$")){throw "Tracking mismatch: $path"}
 if($ids.ContainsKey($script.TrackingId)){throw 'Duplicate tracking ID'}
 $ids[$script.TrackingId]=$true
 if($script.Path -notmatch 'ScannerPortal/|WinPS7\[Pending\]|Invoke-PortalSetup'){
  $tokens=$null;$errors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
  if($errors){$errors | Format-List;throw "Parse failed: $path"}
 }
}
"PASS: $($ids.Count) tracked scripts and PS5.1 entry point syntax"
