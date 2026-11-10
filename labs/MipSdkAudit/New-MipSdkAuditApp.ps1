#Requires -Version 7.2
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid] $TenantId,
    [ValidateNotNullOrEmpty()][string] $DisplayName = 'LocalMIPScanner MIP SDK Lab',
    [switch] $IncludeRightsManagement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($TenantId -eq [guid]::Empty) { throw 'Specify the GUID of the lab tenant.' }
if ($WhatIfPreference) {
    [void] $PSCmdlet.ShouldProcess($TenantId, "Create or reuse the public client '$DisplayName'")
    return
}

# Reuse the Graph bootstrap pattern from Create-MSLearnPeopleConnectorApp.ps1.
# This interactive public client uses delegated scopes and has no client secret.
foreach ($module in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications') {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Install-Module -Name $module -Repository PSGallery -Scope CurrentUser -Force
    }
}
Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications

$tag = 'LocalMIPScanner.MipSdkAudit'
$resources = [ordered] @{
    '870c4f2e-85b6-4d43-bdda-6ed9a579b725' = 'UnifiedPolicy.User.Read'
}
if ($IncludeRightsManagement) {
    $resources['00000012-0000-0000-c000-000000000000'] = 'user_impersonation'
}

$connected = $false
try {
    Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All' -ContextScope Process -NoWelcome | Out-Null
    $connected = $true
    if ([guid](Get-MgContext).TenantId -ne $TenantId) { throw 'Microsoft Graph connected to a different tenant.' }

    $requiredAccess = @(foreach ($resource in $resources.GetEnumerator()) {
        $service = @(Get-MgServicePrincipal -Filter "appId eq '$($resource.Key)'" -Property 'appId,oauth2PermissionScopes')
        if ($service.Count -ne 1) {
            throw "The first-party API $($resource.Key) is unavailable in the lab tenant. Review its API registration in Entra."
        }
        $scope = @($service[0].Oauth2PermissionScopes | Where-Object { $_.IsEnabled -and $_.Value -ceq $resource.Value })
        if ($scope.Count -ne 1) { throw "Delegated scope $($resource.Value) is unavailable in the lab tenant." }
        @{
            ResourceAppId = $resource.Key
            ResourceAccess = @(@{ Id = $scope[0].Id; Type = 'Scope' })
        }
    })

    $escapedName = $DisplayName.Replace("'", "''")
    $properties = 'id,appId,displayName,tags,signInAudience,publicClient,isFallbackPublicClient,requiredResourceAccess'
    $matches = @(Get-MgApplication -Filter "displayName eq '$escapedName'" -Property $properties -All)
    $created = $false
    if ($matches.Count -eq 0) {
        if (-not $PSCmdlet.ShouldProcess($TenantId, "Register '$DisplayName'")) { return }
        $app = New-MgApplication -BodyParameter @{
            DisplayName = $DisplayName
            SignInAudience = 'AzureADMyOrg'
            PublicClient = @{ RedirectUris = @('http://localhost') }
            IsFallbackPublicClient = $true
            RequiredResourceAccess = $requiredAccess
            Tags = @($tag)
        }
        $created = $true
    } else {
        if ($matches.Count -ne 1 -or $tag -notin $matches[0].Tags) {
            throw "The name '$DisplayName' is already in use. Specify a distinct -DisplayName for this lab."
        }
        $app = $matches[0]
        $expected = @(foreach ($resource in $requiredAccess) {
            "$($resource.ResourceAppId)/$($resource.ResourceAccess[0].Id)/Scope"
        }) | Sort-Object
        $actual = @(foreach ($resource in $app.RequiredResourceAccess) {
            foreach ($scope in $resource.ResourceAccess) {
                "$($resource.ResourceAppId)/$($scope.Id)/$($scope.Type)"
            }
        }) | Sort-Object
        if ($app.SignInAudience -ne 'AzureADMyOrg' -or -not $app.IsFallbackPublicClient -or
            $null -eq $app.PublicClient -or
            ($actual -join ',') -ine ($expected -join ',')) {
            throw 'The existing lab registration has different settings or permissions. Review it in Entra or use a distinct -DisplayName.'
        }
    }

    $brokerUri = "ms-appx-web://Microsoft.AAD.BrokerPlugin/$($app.AppId)"
    $redirects = if ($created) { @('http://localhost') } else { @($app.PublicClient.RedirectUris) }
    if (@($redirects | Where-Object { $_.TrimEnd('/') -ceq 'http://localhost' }).Count -ne 1 -or
        @($redirects | Where-Object { $_.TrimEnd('/') -cne 'http://localhost' -and $_ -ine $brokerUri }).Count -gt 0) {
        throw 'The existing lab registration has unexpected redirect URIs. Review it in Entra.'
    }
    if ($brokerUri -notin $redirects) {
        if (-not $PSCmdlet.ShouldProcess($app.AppId, 'Enable Windows broker sign-in')) { return }
        Update-MgApplication -ApplicationId $app.Id -BodyParameter @{
            PublicClient = @{ RedirectUris = @(@($redirects) + $brokerUri) }
        }
    }

    $enterprise = @(Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -Property 'id,appId')
    if ($enterprise.Count -eq 0) {
        if (-not $PSCmdlet.ShouldProcess($app.AppId, 'Create the enterprise application')) { return }
        # An app created through Graph can take a few seconds to become visible to the service principal API.
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $enterprise = @(New-MgServicePrincipal -BodyParameter @{ AppId = $app.AppId })
                break
            } catch {
                $status = $_.Exception.PSObject.Properties['ResponseStatusCode']
                if ($attempt -eq 5 -or $null -eq $status -or [int]$status.Value -notin 400,404,409) { throw }
                Start-Sleep -Seconds $attempt
                $enterprise = @(Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -Property 'id,appId')
                if ($enterprise.Count -gt 0) { break }
            }
        }
    }
    if ($enterprise.Count -ne 1) { throw 'Could not identify a single enterprise application for the lab.' }

    [pscustomobject] @{
        TenantId = $TenantId.ToString()
        ClientId = $app.AppId
        AppObjectId = $app.Id
        ServicePrincipalId = $enterprise[0].Id
        Created = $created
        BrokerRedirectUri = $brokerUri
        DelegatedPermissions = @($resources.Values)
        PortalUrl = "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$($app.AppId)"
    }
} finally {
    if ($connected) { Disconnect-MgGraph | Out-Null }
}
