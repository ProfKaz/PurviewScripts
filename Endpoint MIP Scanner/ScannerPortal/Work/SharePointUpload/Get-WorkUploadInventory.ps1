<#PSScriptInfo
.VERSION 0.1.0
.GUID f5c2c163-91ab-4533-b08e-54ad82746fc5
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 Work W01: read-only local inventory before any upload authentication changes.
#>
<#
.DESCRIPTION
Standalone Windows PowerShell 5.1 local diagnostic. No network, certificate enrollment, task or portal installation.
.NOTES
Version     : 0.1.0
Tracking ID : f5c2c163-91ab-4533-b08e-54ad82746fc5
#>
#Requires -Version 5.1
#Requires -PSEdition Desktop
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallationDirectory,
    [uri]$SiteUrl='https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot',
    [string[]]$OutboxDirectory=@(
        (Join-Path $env:LOCALAPPDATA 'LocalMIPScanner.WinPS51/Outbox/Pending'),
        (Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner/ManagedEndpoint/outbox/Pending')
    )
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Get-WorkField($Object,[string]$Name) {
    if($null -eq $Object){return $null}
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $null
}
function Get-WorkGuid($Value) {
    $parsed=[guid]::Empty
    if([guid]::TryParse([string]$Value,[ref]$parsed) -and $parsed -ne [guid]::Empty){return $parsed.ToString()}
    return $null
}
function Read-WorkJson([string]$Path) {
    $file=Get-Item -LiteralPath $Path
    if($file.Length -gt 1MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Expected ordinary JSON file up to 1 MiB.'}
    Get-Content -LiteralPath $Path -Raw -Encoding utf8|ConvertFrom-Json
}
$root=[IO.Path]::GetFullPath($InstallationDirectory)
if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'InstallationDirectory does not exist.'}
if($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[A-Za-z0-9_-]+/?$' -or $SiteUrl.UserInfo -or $SiteUrl.Query -or $SiteUrl.Fragment -or -not $SiteUrl.IsDefaultPort){throw 'Expected a commercial SharePoint site URL.'}
$issues=[Collections.Generic.List[object]]::new()
$apps=@(foreach($spec in @(
    @{path='.endpoint-install/mip-app.json';role='MipDelegatedApp'},
    @{path='.endpoint-install/portal-app.json';role='PortalAdministrativeApp'},
    @{path='.endpoint-install/controlplane/controlplane.json';role='SharedUploadApp'}
)) {
    $path=Join-Path $root $spec.path
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){
        [pscustomobject]@{Role=$spec.role;LocalState='Missing';TenantId=$null;ClientId=$null;PermissionValidation='NotPerformed'};continue
    }
    try {
        $state=Read-WorkJson $path
        $tenant=Get-WorkField $state 'tenantId';$client=Get-WorkField $state 'clientId'
        if(-not $tenant){$tenant=Get-WorkField (Get-WorkField $state 'bootstrap') 'tenantId'}
        if(-not $client){$client=Get-WorkField (Get-WorkField $state 'bootstrap') 'clientId'}
        # Only explicitly allowlisted public identity fields enter the shareable result.
        [pscustomobject]@{Role=$spec.role;LocalState='Read';TenantId=(Get-WorkGuid $tenant);ClientId=(Get-WorkGuid $client);PermissionValidation='NotPerformed'}
    } catch {$issues.Add([pscustomobject]@{Area=$spec.role;ErrorType=$_.Exception.GetType().Name})}
})
$certificates=@(Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object {$_.Subject -like 'CN=EndpointMIPScanner*'} | ForEach-Object {
    [pscustomobject]@{Subject=$_.Subject;Thumbprint=$_.Thumbprint;NotAfterUtc=$_.NotAfter.ToUniversalTime().ToString('o')
        HasPrivateKey=$_.HasPrivateKey;ValidNow=($_.NotBefore -le (Get-Date) -and $_.NotAfter -gt (Get-Date));Store='CurrentUser/My'
        EntraAssociation='NotValidated';SharedCredential='NotDetermined'}
})
$outboxes=@(foreach($outbox in $OutboxDirectory) {
    $absolute=[IO.Path]::GetFullPath($outbox)
    $exists=Test-Path -LiteralPath $absolute -PathType Container
    $batches=@(if($exists){foreach($directory in @(Get-ChildItem -LiteralPath $absolute -Directory|Where-Object {$_.Name -match '^(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{64})$'})) {
        $manifestPath=Join-Path $directory.FullName 'manifest.json'
        if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){continue}
        try {
            $manifest=Read-WorkJson $manifestPath
            $batchId=[string](Get-WorkField $manifest 'batchId')
            if($batchId -cne $directory.Name){throw 'Batch ID does not match directory.'}
            $contract=Get-WorkField $manifest 'contract'
            if(-not $contract){$contract=if((Get-WorkField $manifest 'state') -eq 'Sealed'){'LocalMIPReportBatch/Sealed'}else{'Unknown'}}
            [pscustomobject]@{BatchId=$batchId;Directory=$directory.FullName;Contract=$contract
                ManifestSha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
                PayloadHashesVerified=$false;Uploaded=$false}
        } catch {$issues.Add([pscustomobject]@{Area='PendingManifest';BatchDirectory=$directory.FullName;ErrorType=$_.Exception.GetType().Name})}
    }})
    [pscustomobject]@{Directory=$absolute;Exists=$exists;PendingCount=$batches.Count;Batches=$batches}
})
$result=[pscustomobject][ordered]@{
    Test='W01-LocalInventory';Version='0.1.0';ReadOnly=$true;NetworkRequests=0
    PowerShell=$PSVersionTable.PSVersion.ToString();Is64Bit=[Environment]::Is64BitProcess
    Elevated=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    DeviceName=$env:COMPUTERNAME;TargetSite=$SiteUrl.AbsoluteUri.TrimEnd('/')
    Applications=$apps;ExistingScannerCertificates=$certificates;Outboxes=$outboxes;Issues=$issues.ToArray()
    CertificatesCreated=0;PrivateKeysExported=$false;TasksChanged=$false;SharePointChanged=$false
    NextStep='Review identity choice; then W02 authentication only. Do not rerun ControlPlane.'
}
Write-Host '=== WORK W01 PARA COMPARTIR ===' -ForegroundColor Magenta
Write-Host ($result|ConvertTo-Json -Depth 9) -ForegroundColor Magenta
$result
