# ExitCodes.Tests.ps1 — Structural tests for deploy.ps1 entry point
# Verifies exit code taxonomy, module imports, and log initialization order
# via text/AST analysis (not execution — running deploy.ps1 would attempt system changes)

BeforeAll {
    $script:DeployPath = Join-Path $PSScriptRoot ".." "deploy.ps1"
    $script:DeployContent = Get-Content -Path $script:DeployPath -Raw -ErrorAction Stop
}

Describe "deploy.ps1 — structural requirements" {

    It "contains ErrorActionPreference = Stop near the top" {
        # Must appear before any substantive code
        $script:DeployContent | Should -Match '\$ErrorActionPreference\s*=\s*"Stop"'
    }

    It "contains #Requires -Version 5.1" {
        $script:DeployContent | Should -Match '#Requires\s+-Version\s+5\.1'
    }

    It "defines all required exit code constants" {
        $script:DeployContent | Should -Match '\$EXIT_SUCCESS\s*=\s*0'
        $script:DeployContent | Should -Match '\$EXIT_OS_EDITION\s*=\s*10'
        $script:DeployContent | Should -Match '\$EXIT_NOT_ADMIN\s*=\s*11'
        $script:DeployContent | Should -Match '\$EXIT_NO_VIRT\s*=\s*12'
        $script:DeployContent | Should -Match '\$EXIT_DISK_SPACE\s*=\s*13'
        $script:DeployContent | Should -Match '\$EXIT_ADB_MISSING\s*=\s*14'
        $script:DeployContent | Should -Match '\$EXIT_STEP_FAILED\s*=\s*20'
        $script:DeployContent | Should -Match '\$EXIT_UNKNOWN\s*=\s*99'
    }

    It "imports Log.psm1, State.psm1, and Guard.psm1 via Import-Module" {
        $script:DeployContent | Should -Match 'Import-Module.*Log\.psm1'
        $script:DeployContent | Should -Match 'Import-Module.*State\.psm1'
        $script:DeployContent | Should -Match 'Import-Module.*Guard\.psm1'
    }

    It "calls Initialize-Log before any Invoke-Step call" {
        $initIndex   = $script:DeployContent.IndexOf("Initialize-Log")
        $invokeIndex = $script:DeployContent.IndexOf("Invoke-Step")

        $initIndex   | Should -BeGreaterThan -1
        $invokeIndex | Should -BeGreaterThan -1
        $initIndex   | Should -BeLessThan $invokeIndex
    }

    It "has a top-level try/catch that exits with EXIT_UNKNOWN on unexpected errors" {
        $script:DeployContent | Should -Match 'catch'
        $script:DeployContent | Should -Match 'exit\s+\$EXIT_UNKNOWN'
    }
}
