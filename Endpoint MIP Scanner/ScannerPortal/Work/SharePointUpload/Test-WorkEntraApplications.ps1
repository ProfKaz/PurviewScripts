<#PSScriptInfo
.VERSION 0.1.0
.GUID 982e1cb5-74b5-4ae0-b619-6dba8f13bc2b
.AUTHOR Kaz Demos / ProfKaz
.COMPANYNAME Kaz Demos
.RELEASENOTES
2026-11-20 0.1.0 W02A GET-only inventory, grant resolution and output minimization tests.
#>
<#
.DESCRIPTION
Offline mocked Graph test. No actual sign-in or tenant requests.
.NOTES
Version     : 0.1.0
Tracking ID : 982e1cb5-74b5-4ae0-b619-6dba8f13bc2b
#>
#Requires -Version 7.4
$ErrorActionPreference='Stop'
$global:WorkDirectoryFixture=@{Tenant=[guid]::NewGuid().ToString();Client=[guid]::NewGuid().ToString()
    App=[guid]::NewGuid().ToString();Principal=[guid]::NewGuid().ToString();Resource=[guid]::NewGuid().ToString()
    ResourceApp=[guid]::NewGuid().ToString();Role=[guid]::NewGuid().ToString();Scope=[guid]::NewGuid().ToString();Calls=0}
function Get-Module{param($Name,[switch]$ListAvailable) [pscustomobject]@{Name='Microsoft.Graph.Authentication'}}
function Import-Module{param($Name)}
function Connect-MgGraph{param($TenantId,$Scopes,$ContextScope,[switch]$NoWelcome)
    if($Scopes -ne 'Application.Read.All' -or $ContextScope -ne 'Process'){throw 'Unexpected authentication scope.'}
}
function Get-MgContext{[pscustomobject]@{TenantId=$global:WorkDirectoryFixture.Tenant}}
function Disconnect-MgGraph{param($ErrorAction)}
function Invoke-MgGraphRequest{param($Uri,$Method,$OutputType)
    $f=$global:WorkDirectoryFixture;$f.Calls++
    if($Method -ne 'GET'){throw 'Write attempted.'}
    if($Uri.Contains('/applications?')){
        return @{value=@(@{id=$f.App;appId=$f.Client;displayName='Kaz Demos ScannerPortal Test'})}
    }
    if($Uri -like ("*/applications/"+$f.App+'?*')){
        return @{id=$f.App;appId=$f.Client;displayName='Kaz Demos ScannerPortal Test';passwordCredentials=@{secretText='DO-NOT-SHARE'}
            keyCredentials=@(@{keyId='public-key-id';type='AsymmetricX509Cert';usage='Verify';endDateTime='2027-01-01T00:00:00Z';key='DO-NOT-SHARE-CERTIFICATE-BLOB'})
            requiredResourceAccess=@(@{resourceAppId=$f.ResourceApp;resourceAccess=@(@{id=$f.Role;type='Role'},@{id=$f.Scope;type='Scope'})})}
    }
    if($Uri -match '/appRoleAssignments'){
        return @{value=@(@{resourceId=$f.Resource;appRoleId=$f.Role})}
    }
    if($Uri.Contains($f.Resource) -or $Uri.Contains($f.ResourceApp)){
        $resource=@{id=$f.Resource;appId=$f.ResourceApp;displayName='Microsoft Graph';appRoles=@(@{id=$f.Role;value='Lists.SelectedOperations.Selected'})
            oauth2PermissionScopes=@(@{id=$f.Scope;value='User.Read'})}
        if($Uri -like '*/servicePrincipals?*'){return @{value=@($resource)}}
        return $resource
    }
    if($Uri -like '*/servicePrincipals?*'){return @{value=@(@{id=$f.Principal;appId=$f.Client;displayName='fixture'})}}
    throw "Unexpected request $Uri"
}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
try{
    $missing=[guid]::NewGuid()
    $result=& (Join-Path $PSScriptRoot 'Get-WorkEntraApplications.ps1') -TenantId $global:WorkDirectoryFixture.Tenant -KnownClientId $missing
    Assert ($result.Complete -and $result.Applications.Count -eq 1) 'Inventory incomplete.'
    $app=$result.Applications[0]
    Assert ($app.DeclaredApiPermissions.Count -eq 2) 'Delegated and application declarations not distinguished.'
    Assert ($app.EffectiveApplicationPermissions.Count -eq 1 -and $app.EffectiveApplicationPermissions[0].Permission -eq 'Lists.SelectedOperations.Selected') 'Effective consent was not resolved.'
    Assert (-not $result.EndpointAuthenticationTested -and -not $result.SharePointAccessTested) 'Inventory falsely claimed runtime access.'
    Assert ($result.KnownClientIdsWithoutLocalAppRegistration -contains $missing.ToString()) 'Missing local app registration not reported.'
    Assert (-not (($result|ConvertTo-Json -Depth 12).Contains('DO-NOT-SHARE'))) 'Non-allowlisted fields leaked.'
    'PASS: W02A administrative read scope, GET-only calls, declared/effective permission distinction and minimized output (mock Graph)'
}finally{Remove-Variable WorkDirectoryFixture -Scope Global}
