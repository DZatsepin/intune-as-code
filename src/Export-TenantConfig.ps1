<#
.SYNOPSIS
    Exports Intune and Entra ID configuration to deterministic JSON files, one file per object.

.DESCRIPTION
    Read-only. Uses Microsoft Graph through Invoke-MgGraphRequest (module Microsoft.Graph.Authentication).
    Every object is written to <OutputPath>/<category>/<display name>__<id>.json with properties sorted
    alphabetically and volatile fields removed, so that two exports of an unchanged tenant are identical
    and `git diff` shows only real changes.

    Categories exported:
      groups                 Entra ID groups (id, name, type, dynamic rule)
      deviceConfigurations   Intune device configuration profiles, incl. Windows update rings
      configurationPolicies  Intune settings catalog policies (with settings)
      groupPolicyConfigs     Intune administrative templates (ADMX)
      compliancePolicies     Intune compliance policies
      scripts                Intune PowerShell scripts (metadata only, not script content)
      mobileApps             Intune apps that have assignments
      conditionalAccess      Entra ID Conditional Access policies

.PARAMETER OutputPath
    Folder to write the export to. Existing JSON files in the category folders are removed first,
    so that deleted objects show up as deletions in Git.

.PARAMETER AccessToken
    Optional. A Graph access token (for example from a CI pipeline using workload identity federation).
    If omitted, the script uses an existing Connect-MgGraph session or starts an interactive sign-in.

.EXAMPLE
    ./src/Export-TenantConfig.ps1 -OutputPath ./export

.NOTES
    Required Microsoft Graph permissions (read-only):
      Group.Read.All, DeviceManagementConfiguration.Read.All, DeviceManagementApps.Read.All,
      DeviceManagementManagedDevices.Read.All, Policy.Read.All
#>
[CmdletBinding()]
param(
    [string] $OutputPath = './export',
    [string] $AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Scopes = @(
    'Group.Read.All',
    'DeviceManagementConfiguration.Read.All',
    'DeviceManagementApps.Read.All',
    'DeviceManagementManagedDevices.Read.All',
    'Policy.Read.All'
)

# Properties that change without a real configuration change; removed to keep diffs meaningful.
$VolatileProperties = @(
    'lastModifiedDateTime', 'modifiedDateTime', 'version', 'createdDateTime', 'renewedDateTime',
    'deletedDateTime', 'expirationDateTime', 'securityIdentifier', 'onPremisesSyncEnabled',
    'roleScopeTagIds', 'supportsScopeTags', 'creationSource', 'settingCount', 'isAssigned',
    'uploadState', 'publishingState', 'size', 'committedContentVersion', 'dependentAppCount',
    'supersedingAppCount', 'supersededAppCount'
)

# Category -> Graph request. {0} placeholders are not used; every URI is complete.
$Sources = [ordered]@{
    groups                = '/v1.0/groups?$select=id,displayName,description,groupTypes,securityEnabled,mailEnabled,membershipRule,membershipRuleProcessingState'
    deviceConfigurations  = '/beta/deviceManagement/deviceConfigurations?$expand=assignments'
    configurationPolicies = '/beta/deviceManagement/configurationPolicies?$expand=assignments,settings'
    groupPolicyConfigs    = '/beta/deviceManagement/groupPolicyConfigurations?$expand=assignments'
    compliancePolicies    = '/beta/deviceManagement/deviceCompliancePolicies?$expand=assignments'
    scripts               = '/beta/deviceManagement/deviceManagementScripts?$expand=assignments&$select=id,displayName,description,fileName,runAsAccount,enforceSignatureCheck,runAs32Bit'
    mobileApps            = '/beta/deviceAppManagement/mobileApps?$filter=isAssigned eq true&$expand=assignments'
    conditionalAccess     = '/v1.0/identity/conditionalAccess/policies'
}

function Connect-Graph {
    if ($AccessToken) {
        $secure = ConvertTo-SecureString $AccessToken -AsPlainText -Force
        Connect-MgGraph -AccessToken $secure -NoWelcome | Out-Null
        return
    }
    if (-not (Get-MgContext)) {
        Connect-MgGraph -Scopes $Scopes -NoWelcome | Out-Null
    }
}

function Get-GraphCollection([string] $Uri) {
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject
        if ($page.PSObject.Properties['value']) { $page.value | ForEach-Object { $items.Add($_) } }
        $next = if ($page.PSObject.Properties['@odata.nextLink']) { $page.'@odata.nextLink' } else { $null }
    }
    return $items
}

# Recursively sorts object properties and drops volatile ones, so JSON output is stable.
function ConvertTo-Normalised($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in ($Value.Keys | Sort-Object)) {
            if ($key -in $VolatileProperties -or $key -like '*@odata.context') { continue }
            $out[$key] = ConvertTo-Normalised $Value[$key]
        }
        return $out
    }
    if ($Value -is [pscustomobject]) {
        $out = [ordered]@{}
        foreach ($prop in ($Value.PSObject.Properties | Sort-Object Name)) {
            if ($prop.Name -in $VolatileProperties -or $prop.Name -like '*@odata.context') { continue }
            $out[$prop.Name] = ConvertTo-Normalised $prop.Value
        }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { ConvertTo-Normalised $_ })
    }
    return $Value
}

function Get-SafeFileName([string] $Name) {
    $clean = ($Name -replace '[^A-Za-z0-9._-]+', '_').Trim('_')
    if ($clean.Length -gt 80) { $clean = $clean.Substring(0, 80) }
    return $clean
}

# Allow dot-sourcing for tests without touching Graph: . ./src/Export-TenantConfig.ps1
if ($MyInvocation.InvocationName -eq '.') { return }

Connect-Graph
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$summary = foreach ($category in $Sources.Keys) {
    $folder = Join-Path $OutputPath $category
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    Get-ChildItem -Path $folder -Filter '*.json' -File | Remove-Item -Force

    $items = Get-GraphCollection $Sources[$category]
    foreach ($item in $items) {
        $name = if ($item.PSObject.Properties['displayName'] -and $item.displayName) { $item.displayName }
                elseif ($item.PSObject.Properties['name'] -and $item.name) { $item.name }
                else { 'unnamed' }
        $file = Join-Path $folder ("{0}__{1}.json" -f (Get-SafeFileName $name), $item.id)
        ConvertTo-Normalised $item | ConvertTo-Json -Depth 50 | Set-Content -Path $file -Encoding utf8NoBOM
    }
    [pscustomobject]@{ Category = $category; Objects = $items.Count }
}

$summary | Format-Table -AutoSize
Write-Host "Export written to $((Resolve-Path $OutputPath).Path)"
