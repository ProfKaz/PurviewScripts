#Requires -Version 7.4
<#
.SYNOPSIS
Plans or creates a dedicated SharePoint communication site for Scanner Portal testing.
.DESCRIPTION
Default mode is offline Plan. Apply authenticates interactively with a tenant-owned
Entra application. No passwords, tokens, certificates or app secrets are accepted.
Optionally deploys an empty native SharePoint foundation after owner-only access checks.
Does not deploy SPFx, profiles, agents or modify an existing site's permissions.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][uri]$AdminUrl,
    [Parameter(Mandatory)][uri]$SiteUrl,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Owner,
    [ValidateNotNullOrEmpty()][string]$Title = 'Scanner Portal - Piloto',
    [ValidateSet('Plan', 'Apply')][string]$Mode = 'Plan',
    [guid]$ClientId = [guid]::Empty,
    [string]$Tenant,
    [ValidateSet('Interactive', 'DeviceLogin')][string]$LoginMethod = 'Interactive',
    [switch]$DeployFoundation,
    [ValidateSet(1033, 3082)][int]$Lcid = 3082
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($AdminUrl.Scheme -ne 'https' -or $AdminUrl.Host -notmatch '^([a-z0-9-]+)-admin\.sharepoint\.com$' -or
    $AdminUrl.AbsolutePath -ne '/' -or $AdminUrl.Query -or $AdminUrl.Fragment -or
    $AdminUrl.UserInfo -or -not $AdminUrl.IsDefaultPort) {
    throw 'AdminUrl must be https://<tenant>-admin.sharepoint.com (commercial cloud).'
}
$expectedHost = $Matches[1] + '.sharepoint.com'
if ($SiteUrl.Scheme -ne 'https' -or $SiteUrl.Host -ne $expectedHost -or
    $SiteUrl.AbsolutePath -notmatch '^/sites/[a-zA-Z0-9][a-zA-Z0-9_-]{2,63}$' -or
    $SiteUrl.Query -or $SiteUrl.Fragment -or $SiteUrl.UserInfo -or -not $SiteUrl.IsDefaultPort) {
    throw 'SiteUrl must be a dedicated /sites/<alias> URL in the same tenant as AdminUrl.'
}
if ($Owner -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw 'Owner must be a user UPN.' }
$siteAddress = $SiteUrl.AbsoluteUri.TrimEnd('/')
$plan = [pscustomobject]@{
    Stage = if ($DeployFoundation) { 'SiteAndFoundation' } else { 'SiteOnly' }
    AdminUrl = $AdminUrl.AbsoluteUri.TrimEnd('/')
    SiteUrl = $siteAddress
    Title = $Title
    Owner = $Owner
    Lcid = $Lcid
    Type = 'CommunicationSite'
    ExternalSharing = 'Disabled'
    ExistingSitePolicy = 'Read status only; never adopt or change automatically'
    DeploysSPFx = $false
    DeploysProfiles = $false
}
if ($Mode -eq 'Plan' -or $WhatIfPreference) {
    $plan
    return
}
if ($ClientId -eq [guid]::Empty -or [string]::IsNullOrWhiteSpace($Tenant)) {
    throw 'Apply requires the public ClientId of an approved interactive Entra app and Tenant (ID or verified domain).'
}
Import-Module PnP.PowerShell -MinimumVersion 3.2.0 -ErrorAction Stop
if (-not $PSCmdlet.ShouldProcess($siteAddress, 'Create dedicated communication site and disable external sharing')) {
    return
}
$login = @{ ClientId = $ClientId.ToString(); Tenant = $Tenant; ReturnConnection = $true; ErrorAction = 'Stop' }
$login[$LoginMethod] = $true
$adminConnection = $null
$siteConnection = $null
try {
    $adminConnection = Connect-PnPOnline -Url $plan.AdminUrl @login
    # A failed tenant query is fatal; never interpret a permission/network error as site absence.
    $existing = @(Get-PnPTenantSite -Filter "Url -eq '$siteAddress'" -Connection $adminConnection |
        Where-Object { $_.Url.TrimEnd('/') -eq $siteAddress })
    if ($existing.Count -gt 0) {
        [pscustomobject]@{
            Status = 'AlreadyExistsNeedsReview'
            SiteUrl = $siteAddress
            Modified = $false
            Message = 'Site exists. Review ownership, permissions and sharing before provisioning any resources.'
        }
        return
    }
    New-PnPSite -Type CommunicationSite -Title $Title -Url $siteAddress -Owner $Owner -Lcid $Lcid `
        -Wait -Connection $adminConnection | Out-Null
    Write-Host "Site created: $siteAddress. Verifying sharing and permissions."
    # No content is uploaded. If this fails, stop and report the created site for recovery.
    Set-PnPTenantSite -Identity $siteAddress -SharingCapability Disabled -Connection $adminConnection
    $created = Get-PnPTenantSite -Identity $siteAddress -Detailed -Connection $adminConnection
    if ([string]$created.SharingCapability -ne 'Disabled') {
        throw "Site created at $siteAddress, but disabling external sharing could not be verified. Do not upload data."
    }
    $siteConnection = Connect-PnPOnline -Url $siteAddress -Connection $adminConnection @login
    $web = Get-PnPWeb -Includes RoleAssignments,AssociatedOwnerGroup,AssociatedMemberGroup,AssociatedVisitorGroup `
        -Connection $siteConnection
    $groups = foreach ($group in @($web.AssociatedOwnerGroup, $web.AssociatedMemberGroup, $web.AssociatedVisitorGroup)) {
        if ($null -eq $group) { continue }
        $members = @(Get-PnPGroupMember -Group $group.Id -Connection $siteConnection)
        [pscustomobject]@{
            GroupId = $group.Id
            GroupTitle = $group.Title
            Members = @($members | Select-Object -ExpandProperty LoginName)
        }
    }
    $assignments = foreach ($assignment in $web.RoleAssignments) {
        $null = Get-PnPProperty -ClientObject $assignment -Property Member,RoleDefinitionBindings -Connection $siteConnection
        [pscustomobject]@{
            Principal = $assignment.Member.LoginName
            PrincipalType = [string]$assignment.Member.PrincipalType
            Roles = @($assignment.RoleDefinitionBindings | Select-Object -ExpandProperty Name)
        }
    }
    [pscustomobject]@{
        Status = 'SiteCreatedPermissionsReviewRequired'
        SiteUrl = $siteAddress
        SharingCapability = [string]$created.SharingCapability
        Groups = @($groups)
        RoleAssignments = @($assignments)
        NextStep = 'Review site permissions, then provision restricted libraries/lists. SPFx is not deployed.'
    }
    if ($DeployFoundation) {
        & (Join-Path $PSScriptRoot 'Install-ScannerPortalFoundation.ps1') -SiteUrl $siteAddress -Owner $Owner `
            -Mode Apply -AdminConnection $adminConnection -SiteConnection $siteConnection
    }
}
finally {
    # PnP 3.2 Disconnect-PnPOnline disconnects the active connection; it has no -Connection parameter.
    if ($null -ne $adminConnection -or $null -ne $siteConnection) {
        Disconnect-PnPOnline -ErrorAction SilentlyContinue
    }
}
