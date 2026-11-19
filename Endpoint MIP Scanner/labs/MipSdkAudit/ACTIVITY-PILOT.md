# M6 Activity Explorer pilot

Run as the signed-in Windows user. Reuse the working WAM pilot configuration and an unprotected, unlabeled Office document. The command creates one labeled copy under a configured root, notifies the File SDK after verification and publication, then reads its label with discovery enabled. The local JSONL records the observed application ID, application name, user, file path and UTC timestamps. A successful notification call does not confirm ingestion.

```powershell
Set-Location C:\Deploy\LocalMIPScanner
$lab = .\Install-MipSdkAudit.ps1 -Ref feat/localmipscanner-m6-activity-pilot
$pilot = Join-Path $env:LOCALAPPDATA 'LocalMIPScanner\WamPilot-2ed694536c6149cab3044eb4735ce75f'
$policyConfig = Join-Path $pilot 'policy-audit.json'
$root = @( (Get-Content -LiteralPath $policyConfig -Raw | ConvertFrom-Json).roots )[0]
$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$source = Join-Path $root "M6-source-$id.docx"
$output = Join-Path $root "M6-scanner-$id.docx"
$control = Join-Path $root "M6-manual-$id.docx"
Copy-Item -LiteralPath '.\Prueba.docx' -Destination $source -ErrorAction Stop
Copy-Item -LiteralPath $source -Destination $control -ErrorAction Stop
$labelId = Read-Host 'Published label ID (addsProtection=false)'
& $lab.DotNetPath $lab.LabAssembly --office-activity-pilot $policyConfig $source $output $labelId |
    Tee-Object -FilePath (Join-Path $pilot "M6-$id.jsonl")
if ($LASTEXITCODE -ne 0) { throw 'Activity pilot failed. Inspect the JSONL before retrying.' }
$control
```

Open the manual control in Word, apply the same label, and save. Search Activity Explorer for both unique file names and use the timestamps from the JSONL. Compare Label applied, File discovered, and any additional rows returned for the two files. Export or copy the event details. Record the exact field names and values for activity, UTC time, user, application name and ID, process, workload, device, path and label. Mark absent fields as such. Redact user and path consistently before sharing externally.

Evaluate an exact match on the scanner's application ID in the SOC/NOC data source first. Use the manual control to verify that manual activity still follows the normal rule. Keep scanner events searchable and retain detections for unexpected scanner volume. Treat an application display name or process name as descriptive until its availability and uniqueness have been verified in the relevant feed.
