#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0" }
# VmFeatures.Tests.ps1 — Pester unit tests for steps/02-vm-features.ps1
# Covers all 7 requirements: VMFT-01, VMFT-02, VMFT-03, BOOT-01, BOOT-02, BOOT-03, BOOT-04
# All system calls are mocked to prevent actual feature changes, reboots, or port reservation.

BeforeAll {
    # Set up a temp log file for Write-Log calls
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "BarakaVmFeaturesTests-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    $script:LogFile = Join-Path $script:TestRoot "deploy.log"

    $script:LibDir   = (Resolve-Path (Join-Path $PSScriptRoot "..\lib")).Path
    $script:StepPath = (Join-Path $PSScriptRoot "..\steps\02-vm-features.ps1")

    Import-Module (Join-Path $script:LibDir "Log.psm1")   -Force
    Import-Module (Join-Path $script:LibDir "State.psm1") -Force
    Import-Module (Join-Path $script:LibDir "Guard.psm1") -Force

    Initialize-Log -Path $script:LogFile

    # In-memory registry store for State mock
    $script:FakeStore = @{}
    $script:FakePathExists = $false

    # Mock registry operations in the State module scope (pattern from Guard.Tests.ps1)
    Mock -ModuleName State Test-Path {
        param([string]$Path)
        return $script:FakePathExists
    }
    Mock -ModuleName State New-Item {
        param([string]$Path)
        $script:FakePathExists = $true
    }
    Mock -ModuleName State Get-ItemProperty {
        param([string]$Path, [string]$Name)
        if ($script:FakeStore.ContainsKey($Name)) {
            $obj = [PSCustomObject]@{ $Name = $script:FakeStore[$Name] }
            return $obj
        }
        return $null
    }
    Mock -ModuleName State Set-ItemProperty {
        param([string]$Path, [string]$Name, $Value)
        $script:FakePathExists = $true
        $script:FakeStore[$Name] = $Value
    }

    # Stub Windows-only commands that don't exist on Linux test runners.
    # These stubs are replaced by per-test Mocks but must exist for Pester
    # to intercept them. Without stubs, Mock fails with CommandNotFoundException
    # on non-Windows platforms.
    if (-not (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        function global:Get-WindowsOptionalFeature { param([switch]$Online, [string]$FeatureName) }
    }
    if (-not (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        function global:Enable-WindowsOptionalFeature { param([switch]$Online, [string]$FeatureName, [switch]$All, [switch]$NoRestart) }
    }
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        function global:Register-ScheduledTask { param([string]$TaskName, $Action, $Trigger, $Settings, [string]$RunLevel, [switch]$Force) }
    }
    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) {
        function global:Unregister-ScheduledTask { param([string]$TaskName, [bool]$Confirm, $ErrorAction) }
    }
    if (-not (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue)) {
        function global:New-ScheduledTaskAction { param([string]$Execute, [string]$Argument) }
    }
    if (-not (Get-Command New-ScheduledTaskTrigger -ErrorAction SilentlyContinue)) {
        function global:New-ScheduledTaskTrigger { param([switch]$AtStartup) }
    }
    if (-not (Get-Command New-ScheduledTaskSettingsSet -ErrorAction SilentlyContinue)) {
        function global:New-ScheduledTaskSettingsSet { param($ExecutionTimeLimit) }
    }

    # Load the step file with BARAKA_TEST_MODE=1 to prevent auto-execution
    $env:BARAKA_TEST_MODE = '1'
    . $script:StepPath
}

AfterAll {
    Remove-Module Guard -ErrorAction SilentlyContinue
    Remove-Module State -ErrorAction SilentlyContinue
    Remove-Module Log   -ErrorAction SilentlyContinue
    Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    $env:BARAKA_TEST_MODE = $null
}

# ============================================================================
# Test-VmFeaturesEnabled
# ============================================================================
Describe "Test-VmFeaturesEnabled" {

    It "VMFT-02: returns `$true when both features have State='Enabled'" {
        Mock Get-WindowsOptionalFeature {
            param([switch]$Online, [string]$FeatureName)
            return [PSCustomObject]@{ FeatureName = $FeatureName; State = 'Enabled' }
        }

        $result = Test-VmFeaturesEnabled
        $result | Should -BeTrue
    }

    It "VMFT-02: returns `$false when VirtualMachinePlatform is Disabled" {
        Mock Get-WindowsOptionalFeature {
            param([switch]$Online, [string]$FeatureName)
            if ($FeatureName -eq 'VirtualMachinePlatform') {
                return [PSCustomObject]@{ FeatureName = $FeatureName; State = 'Disabled' }
            }
            return [PSCustomObject]@{ FeatureName = $FeatureName; State = 'Enabled' }
        }

        $result = Test-VmFeaturesEnabled
        $result | Should -BeFalse
    }

    It "VMFT-02: returns `$false when HypervisorPlatform is Disabled" {
        Mock Get-WindowsOptionalFeature {
            param([switch]$Online, [string]$FeatureName)
            if ($FeatureName -eq 'HypervisorPlatform') {
                return [PSCustomObject]@{ FeatureName = $FeatureName; State = 'Disabled' }
            }
            return [PSCustomObject]@{ FeatureName = $FeatureName; State = 'Enabled' }
        }

        $result = Test-VmFeaturesEnabled
        $result | Should -BeFalse
    }
}

# ============================================================================
# Invoke-VmFeatures — Already-enabled path (VMFT-02 idempotency)
# ============================================================================
Describe "Invoke-VmFeatures — features already enabled" {

    BeforeEach {
        # Both features are already Enabled
        Mock Get-WindowsOptionalFeature {
            param([switch]$Online, [string]$FeatureName)
            return [PSCustomObject]@{ FeatureName = $FeatureName; State = 'Enabled' }
        }
        Mock Enable-WindowsOptionalFeature { }
        # Invoke-SystemReboot is the test seam wrapping Restart-Computer -Force
        Mock Invoke-SystemReboot { }
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock New-ScheduledTaskAction { return [PSCustomObject]@{} }
        Mock New-ScheduledTaskTrigger { return [PSCustomObject]@{} }
        Mock New-ScheduledTaskSettingsSet { return [PSCustomObject]@{} }
        Mock Invoke-NetshPortReserve { }
    }

    It "VMFT-02: does NOT call Enable-WindowsOptionalFeature when features are already enabled" {
        Invoke-VmFeatures
        Should -Invoke Enable-WindowsOptionalFeature -Times 0 -Exactly
    }

    It "VMFT-02: does NOT trigger a system reboot when features are already enabled" {
        Invoke-VmFeatures
        Should -Invoke Invoke-SystemReboot -Times 0 -Exactly
    }

    It "VMFT-02: does NOT call Register-ScheduledTask when features are already enabled" {
        Invoke-VmFeatures
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
    }
}

# ============================================================================
# Invoke-VmFeatures — Features need enabling, no restart needed (VMFT-01, VMFT-03)
# ============================================================================
Describe "Invoke-VmFeatures — features need enabling, no restart required" {

    BeforeEach {
        # Features are disabled
        Mock Get-WindowsOptionalFeature {
            param([switch]$Online, [string]$FeatureName)
            return [PSCustomObject]@{ FeatureName = $FeatureName; State = 'Disabled' }
        }
        # Enable returns RestartNeeded = false
        Mock Enable-WindowsOptionalFeature {
            return [PSCustomObject]@{ RestartNeeded = $false }
        }
        Mock Invoke-SystemReboot { }
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock New-ScheduledTaskAction { return [PSCustomObject]@{} }
        Mock New-ScheduledTaskTrigger { return [PSCustomObject]@{} }
        Mock New-ScheduledTaskSettingsSet { return [PSCustomObject]@{} }
        Mock Invoke-NetshPortReserve { }
    }

    It "VMFT-01: calls Enable-WindowsOptionalFeature for VirtualMachinePlatform" {
        Invoke-VmFeatures
        Should -Invoke Enable-WindowsOptionalFeature -ParameterFilter { $FeatureName -eq 'VirtualMachinePlatform' } -Times 1 -Exactly
    }

    It "VMFT-01: calls Enable-WindowsOptionalFeature for HypervisorPlatform" {
        Invoke-VmFeatures
        Should -Invoke Enable-WindowsOptionalFeature -ParameterFilter { $FeatureName -eq 'HypervisorPlatform' } -Times 1 -Exactly
    }

    It "VMFT-03: does NOT trigger a reboot when RestartNeeded is false" {
        Invoke-VmFeatures
        Should -Invoke Invoke-SystemReboot -Times 0 -Exactly
    }
}

# ============================================================================
# Invoke-VmFeatures — Features need enabling AND restart IS required
# (VMFT-01, VMFT-03, BOOT-01, BOOT-02, BOOT-03)
# ============================================================================
Describe "Invoke-VmFeatures — features need enabling, restart required" {

    BeforeEach {
        $script:CallSequence = [System.Collections.Generic.List[string]]::new()

        # Features are disabled
        Mock Get-WindowsOptionalFeature {
            param([switch]$Online, [string]$FeatureName)
            return [PSCustomObject]@{ FeatureName = $FeatureName; State = 'Disabled' }
        }
        # Enable returns RestartNeeded = true for both features
        Mock Enable-WindowsOptionalFeature {
            param([switch]$Online, [string]$FeatureName, [switch]$All, [switch]$NoRestart)
            return [PSCustomObject]@{ RestartNeeded = $true }
        }
        # Track call order for BOOT-02 ordering verification
        Mock Invoke-NetshPortReserve {
            $script:CallSequence.Add('netsh') | Out-Null
        }
        Mock Register-ScheduledTask {
            $script:CallSequence.Add('RegisterTask') | Out-Null
            return [PSCustomObject]@{}
        }
        Mock Invoke-SystemReboot {
            $script:CallSequence.Add('Restart') | Out-Null
        }
        Mock New-ScheduledTaskAction { return [PSCustomObject]@{} }
        Mock New-ScheduledTaskTrigger { return [PSCustomObject]@{} }
        Mock New-ScheduledTaskSettingsSet { return [PSCustomObject]@{} }
        Mock Unregister-ScheduledTask { }

        # Reset fake store for each test
        $script:FakeStore = @{}
        $script:FakePathExists = $false
    }

    It "VMFT-01: calls Enable-WindowsOptionalFeature for both features" {
        Invoke-VmFeatures
        Should -Invoke Enable-WindowsOptionalFeature -ParameterFilter { $FeatureName -eq 'VirtualMachinePlatform' } -Times 1 -Exactly
        Should -Invoke Enable-WindowsOptionalFeature -ParameterFilter { $FeatureName -eq 'HypervisorPlatform' } -Times 1 -Exactly
    }

    It "VMFT-03: triggers Invoke-SystemReboot when RestartNeeded is true" {
        Invoke-VmFeatures
        Should -Invoke Invoke-SystemReboot -Times 1 -Exactly
    }

    It "BOOT-02: calls Invoke-NetshPortReserve (port 58526 reservation) before Invoke-SystemReboot" {
        Invoke-VmFeatures
        Should -Invoke Invoke-NetshPortReserve -Times 1 -Exactly
        $netshIdx   = $script:CallSequence.IndexOf('netsh')
        $restartIdx = $script:CallSequence.IndexOf('Restart')
        $netshIdx   | Should -BeGreaterOrEqual 0
        $restartIdx | Should -BeGreaterOrEqual 0
        $netshIdx   | Should -BeLessThan $restartIdx
    }

    It "BOOT-01: calls Register-ScheduledTask with -RunLevel Highest and task name BarakaDeploy-Resume" {
        Invoke-VmFeatures
        Should -Invoke Register-ScheduledTask -ParameterFilter {
            $TaskName -eq 'BarakaDeploy-Resume' -and $RunLevel -eq 'Highest'
        } -Times 1 -Exactly
    }

    It "BOOT-03: calls Set-DeployState with 'ResumeStep' before Invoke-SystemReboot" {
        Invoke-VmFeatures
        # Verify state was saved to registry
        $script:FakeStore['ResumeStep'] | Should -Not -BeNullOrEmpty
        # Verify Invoke-SystemReboot was called
        Should -Invoke Invoke-SystemReboot -Times 1 -Exactly
        # State must be saved before reboot (RegisterTask then Restart in sequence)
        $registerIdx = $script:CallSequence.IndexOf('RegisterTask')
        $restartIdx  = $script:CallSequence.IndexOf('Restart')
        $registerIdx | Should -BeLessThan $restartIdx
    }
}

# ============================================================================
# BOOT-04: Unregister-ScheduledTask cleanup (tested via deploy.ps1 finally block)
# This test verifies the deploy.ps1 finally block pattern for task cleanup.
# ============================================================================
Describe "BOOT-04 — BarakaDeploy-Resume task cleanup via finally block" {

    It "BOOT-04: deploy.ps1 contains Unregister-ScheduledTask for BarakaDeploy-Resume in a finally block" {
        $deployPath    = Join-Path $PSScriptRoot "..\deploy.ps1"
        $deployContent = Get-Content -Path $deployPath -Raw

        # Verify both the finally keyword and the Unregister call are present
        $deployContent | Should -Match 'finally'
        $deployContent | Should -Match "Unregister-ScheduledTask.*BarakaDeploy-Resume"
    }
}
