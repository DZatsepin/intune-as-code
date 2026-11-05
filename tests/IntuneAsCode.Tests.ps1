#Requires -Modules Pester
# Run: Invoke-Pester ./tests

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src/Export-TenantConfig.ps1')
    $out = Join-Path ([IO.Path]::GetTempPath()) ("iac-tests-" + [guid]::NewGuid())
    & (Join-Path $root 'src/Get-GroupUsage.ps1') -ExportPath (Join-Path $root 'samples/export') -OutputPath $out | Out-Null
    $report = Get-Content -Raw (Join-Path $out 'group-usage.json') | ConvertFrom-Json
    function Get-G($name) { $report.groups | Where-Object displayName -eq $name }
}

Describe 'ConvertTo-Normalised' {
    It 'sorts properties and removes volatile fields' {
        $a = [pscustomobject]@{ zeta = 1; id = 'x'; lastModifiedDateTime = '2026-01-01'; alpha = @('b', 'a') }
        $b = [pscustomobject]@{ alpha = @('b', 'a'); id = 'x'; zeta = 1; version = 7 }
        (ConvertTo-Normalised $a | ConvertTo-Json -Compress) | Should -Be (ConvertTo-Normalised $b | ConvertTo-Json -Compress)
        (ConvertTo-Normalised $a | ConvertTo-Json -Compress) | Should -Be '{"alpha":["b","a"],"id":"x","zeta":1}'
    }
    It 'keeps single-element arrays as arrays' {
        ConvertTo-Normalised ([pscustomobject]@{ one = @('x') }) | ConvertTo-Json -Compress | Should -Be '{"one":["x"]}'
    }
}

Describe 'Get-SafeFileName' {
    It 'replaces unsafe characters' {
        Get-SafeFileName 'Update ring - Pilot / Wave#1' | Should -Be 'Update_ring_-_Pilot_Wave_1'
    }
}

Describe 'Get-GroupUsage on the sample export' {
    It 'finds the three unused groups' {
        ($report.groups | Where-Object status -eq 'unused').displayName | Sort-Object |
            Should -Be @('SG-Intune-Test-2023', 'SG-Win11-Wave1', 'SG-Win11-Wave3')
    }
    It 'detects an Intune exclusion' {
        (Get-G 'SG-Win11-Pilot').usage | Where-Object { $_.mode -eq 'exclude' -and $_.objectName -eq 'Update ring - Broad' } |
            Should -Not -BeNullOrEmpty
    }
    It 'detects a Conditional Access exclusion and warns' {
        $g = Get-G 'SG-MFA-Exclusion-Temp'
        $g.status | Should -Be 'in-use'
        $g.warning | Should -Match 'Conditional Access'
    }
    It 'keeps a group used only by a script' {
        (Get-G 'SG-Win11-Wave2').usage.label | Should -Be 'Script'
    }
    It 'counts groups consistently' {
        $report.summary.groups | Should -Be ($report.summary.inUse + $report.summary.unused)
    }
}
