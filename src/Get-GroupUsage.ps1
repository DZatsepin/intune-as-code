<#
.SYNOPSIS
    Shows where every Entra ID group is used, from an export folder. Works offline.

.DESCRIPTION
    Reads the JSON export produced by Export-TenantConfig.ps1 (or the sample in ./samples/export)
    and builds a group-usage index:

      - Intune assignments (include and exclude) on profiles, settings catalog, ADMX,
        compliance policies, scripts and apps
      - Conditional Access include and exclude groups
      - Any other place where a group's object ID appears in the export ("other reference")

    Writes:
      group-usage.json   full index, used by report/index.html
      unused-groups.csv  groups with no references, for review before deletion

    Nothing is changed in the tenant. The script never deletes anything.

.PARAMETER ExportPath
    Folder with the export (default: ./samples/export).

.PARAMETER OutputPath
    Folder for the results (default: ./out).

.PARAMETER Group
    Optional display name or object ID. Prints where that one group is used.

.EXAMPLE
    ./src/Get-GroupUsage.ps1
    ./src/Get-GroupUsage.ps1 -Group SG-Win11-Pilot
    ./src/Get-GroupUsage.ps1 -ExportPath ../tenant-config/export -OutputPath ./out
#>
[CmdletBinding()]
param(
    [string] $ExportPath = (Join-Path $PSScriptRoot '../samples/export'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../out'),
    [string] $Group
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CategoryLabels = [ordered]@{
    deviceConfigurations  = 'Configuration profile'
    configurationPolicies = 'Settings catalog'
    groupPolicyConfigs    = 'Administrative template'
    compliancePolicies    = 'Compliance policy'
    scripts               = 'Script'
    mobileApps            = 'App'
    conditionalAccess     = 'Conditional Access'
}

function Read-Json([string] $Path) { Get-Content -Raw -Path $Path | ConvertFrom-Json }

function Get-Prop($Object, [string] $Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

if (-not (Test-Path $ExportPath)) { throw "Export folder not found: $ExportPath" }

# 1. Groups
$groupFiles = Get-ChildItem -Path (Join-Path $ExportPath 'groups') -Filter '*.json' -File -ErrorAction SilentlyContinue
if (-not $groupFiles) { throw "No groups found in $ExportPath/groups. Run Export-TenantConfig.ps1 first." }

$groups = [ordered]@{}
foreach ($f in $groupFiles) {
    $g = Read-Json $f.FullName
    $groups[$g.id] = [ordered]@{
        id          = $g.id
        displayName = $g.displayName
        description = Get-Prop $g 'description'
        dynamic     = [bool](Get-Prop $g 'membershipRule')
        usage       = [System.Collections.Generic.List[object]]::new()
    }
}

# 2. Objects that can reference groups
$objects = [System.Collections.Generic.List[object]]::new()
foreach ($category in $CategoryLabels.Keys) {
    $folder = Join-Path $ExportPath $category
    if (-not (Test-Path $folder)) { continue }
    foreach ($f in Get-ChildItem -Path $folder -Filter '*.json' -File) {
        $o    = Read-Json $f.FullName
        $raw  = Get-Content -Raw -Path $f.FullName
        $name = if (Get-Prop $o 'displayName') { $o.displayName } elseif (Get-Prop $o 'name') { $o.name } else { $f.BaseName }
        $refs = [System.Collections.Generic.List[object]]::new()

        # Intune-style assignments
        foreach ($a in @(Get-Prop $o 'assignments')) {
            if ($null -eq $a) { continue }
            $t = Get-Prop $a 'target'
            $gid = Get-Prop $t 'groupId'
            if (-not $gid) { continue }
            $mode = if ((Get-Prop $t '@odata.type') -like '*exclusion*') { 'exclude' } else { 'include' }
            $intent = Get-Prop $a 'intent'
            $refs.Add([ordered]@{ groupId = $gid; mode = $mode; detail = $intent })
        }

        # Conditional Access users/groups
        $users = Get-Prop (Get-Prop $o 'conditions') 'users'
        foreach ($gid in @(Get-Prop $users 'includeGroups')) { if ($gid) { $refs.Add([ordered]@{ groupId = $gid; mode = 'include'; detail = $null }) } }
        foreach ($gid in @(Get-Prop $users 'excludeGroups')) { if ($gid) { $refs.Add([ordered]@{ groupId = $gid; mode = 'exclude'; detail = $null }) } }

        # Catch-all: a group ID mentioned anywhere else in the object (filters, settings, nested rules)
        $known = @($refs | ForEach-Object { $_.groupId })
        foreach ($gid in $groups.Keys) {
            if ($gid -notin $known -and $raw.Contains($gid)) {
                $refs.Add([ordered]@{ groupId = $gid; mode = 'other'; detail = 'ID found in object' })
            }
        }

        $objects.Add([ordered]@{
            id = Get-Prop $o 'id'; displayName = $name; category = $category
            label = $CategoryLabels[$category]; state = Get-Prop $o 'state'
        })
        foreach ($r in $refs) {
            if ($groups.Contains($r.groupId)) {
                $groups[$r.groupId].usage.Add([ordered]@{
                    objectId = Get-Prop $o 'id'; objectName = $name; category = $category
                    label = $CategoryLabels[$category]; mode = $r.mode; detail = $r.detail
                })
            }
        }
    }
}

# 3. Verdicts
$result = foreach ($g in $groups.Values) {
    $caExclusion = @($g.usage | Where-Object { $_.category -eq 'conditionalAccess' -and $_.mode -eq 'exclude' }).Count -gt 0
    $g['status']  = if ($g.usage.Count -eq 0) { 'unused' } else { 'in-use' }
    $g['warning'] = if ($caExclusion) { 'Excluded from Conditional Access: deleting it changes who the policy applies to.' } else { $null }
    [pscustomobject]$g
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$report = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    source      = (Resolve-Path $ExportPath).Path | Split-Path -Leaf
    summary     = [ordered]@{
        groups  = @($result).Count
        inUse   = @($result | Where-Object status -eq 'in-use').Count
        unused  = @($result | Where-Object status -eq 'unused').Count
        objects = $objects.Count
        caExclusions = @($result | Where-Object warning).Count
    }
    groups      = @($result | Sort-Object displayName)
    objects     = @($objects | Sort-Object category, displayName)
}
$report | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $OutputPath 'group-usage.json') -Encoding utf8NoBOM
$result | Where-Object status -eq 'unused' | Sort-Object displayName |
    Select-Object displayName, id, description, dynamic |
    Export-Csv -Path (Join-Path $OutputPath 'unused-groups.csv') -NoTypeInformation -Encoding utf8NoBOM

# 4. Console output
if ($Group) {
    $g = $result | Where-Object { $_.displayName -eq $Group -or $_.id -eq $Group } | Select-Object -First 1
    if (-not $g) { throw "Group not found in export: $Group" }
    Write-Host ""
    Write-Host $g.displayName
    if ($g.status -eq 'unused') {
        Write-Host '  Used nowhere in the export. Safe to delete after an owner check.' -ForegroundColor Green
    } else {
        Write-Host "  Still in use ($($g.usage.Count) references). Don't delete." -ForegroundColor Red
        $g.usage | ForEach-Object { [pscustomobject]@{ Mode = $_.mode; Type = $_.label; Object = $_.objectName } } |
            Format-Table -AutoSize | Out-String -Width 160 | Write-Host
        if ($g.warning) { Write-Host "  $($g.warning)" -ForegroundColor Yellow }
    }
} else {
    $s = $report.summary
    Write-Host ""
    Write-Host ("{0} groups · {1} in use · {2} unused · {3} excluded from Conditional Access" -f $s.groups, $s.inUse, $s.unused, $s.caExclusions)
    $result | Sort-Object status, displayName |
        Select-Object @{ n = 'Group'; e = { $_.displayName } }, @{ n = 'Status'; e = { $_.status } },
                      @{ n = 'Refs'; e = { $_.usage.Count } }, @{ n = 'Note'; e = { if ($_.warning) { 'CA exclusion' } } } |
        Format-Table -AutoSize | Out-String -Width 160 | Write-Host
    Write-Host "Written: $(Join-Path $OutputPath 'group-usage.json'), $(Join-Path $OutputPath 'unused-groups.csv')"
}
