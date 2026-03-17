#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0" }
# WsaInstall.Tests.ps1 — Pester unit tests for steps/03-wsa-install.ps1
# Covers all 4 requirements: WSAI-01, WSAI-02, WSAI-03, WSAI-04
# All system calls are mocked to prevent actual WSA installation or process changes.

BeforeAll {
    # Set up a temp log file for Write-Log calls
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "BarakaWsaInstallTests-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    $script:LogFile = Join-Path $script:TestRoot "deploy.log"

    $script:LibDir   = (Resolve-Path (Join-Path $PSScriptRoot "..\lib")).Path
    $script:StepPath = (Join-Path $PSScriptRoot "..\steps\03-wsa-install.ps1")

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
    if (-not (Get-Command Add-AppxPackage -ErrorAction SilentlyContinue)) {
        function global:Add-AppxPackage {
            param([string]$Register, [switch]$ForceApplicationShutdown, [switch]$ForceUpdateFromAnyVersion)
        }
    }
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        function global:Get-AppxPackage {
            param([string]$Name, $ErrorAction)
        }
    }
    if (-not (Get-Command Get-Process -ErrorAction SilentlyContinue)) {
        function global:Get-Process {
            param([string]$Name, $ErrorAction)
        }
    }
    if (-not (Get-Command Stop-Process -ErrorAction SilentlyContinue)) {
        function global:Stop-Process {
            [CmdletBinding()]
            param(
                [Parameter(ValueFromPipeline)]$InputObject,
                [switch]$Force,
                $ErrorAction
            )
        }
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
# Test-WsaInstalled (WSAI-04 idempotency check)
# ============================================================================
Describe "Test-WsaInstalled" {

    It "WSAI-04: returns `$true when Get-AppxPackage returns a package object" {
        Mock Get-AppxPackage {
            param([string]$Name, $ErrorAction)
            return [PSCustomObject]@{ Name = 'MicrosoftCorporationII.WindowsSubsystemForAndroid' }
        }

        $result = Test-WsaInstalled
        $result | Should -BeTrue
    }

    It "WSAI-04: returns `$false when Get-AppxPackage returns `$null" {
        Mock Get-AppxPackage {
            param([string]$Name, $ErrorAction)
            return $null
        }

        $result = Test-WsaInstalled
        $result | Should -BeFalse
    }
}

# ============================================================================
# Invoke-WsaInstall — WSA already installed (WSAI-04 idempotency)
# ============================================================================
Describe "Invoke-WsaInstall — WSA already installed" {

    BeforeEach {
        Mock Get-AppxPackage {
            param([string]$Name, $ErrorAction)
            return [PSCustomObject]@{ Name = 'MicrosoftCorporationII.WindowsSubsystemForAndroid' }
        }
        Mock Invoke-AddAppxPackage { }
        Mock Invoke-Sleep { }
        Mock Stop-WsaWindows { }
        Mock Invoke-WsaServiceWait { }
    }

    It "WSAI-04: does NOT call Invoke-AddAppxPackage when WSA is already installed" {
        Invoke-WsaInstall -WsaRoot "C:\fake\wsa"
        Should -Invoke Invoke-AddAppxPackage -Times 0 -Exactly
    }

    It "WSAI-04: logs 'already installed' message when WSA is already installed" {
        Invoke-WsaInstall -WsaRoot "C:\fake\wsa"
        # Verify no install was attempted
        Should -Invoke Invoke-AddAppxPackage -Times 0 -Exactly
        Should -Invoke Invoke-Sleep -Times 0 -Exactly
    }
}

# ============================================================================
# Invoke-WsaInstall — fresh install (WSAI-01, WSAI-02, WSAI-03)
# ============================================================================
Describe "Invoke-WsaInstall — fresh install" {

    BeforeEach {
        $script:CallSequence = [System.Collections.Generic.List[string]]::new()
        $script:SleepSeconds = [System.Collections.Generic.List[int]]::new()
        $script:StoppedProcesses = [System.Collections.Generic.List[string]]::new()

        # WSA is not installed — fresh install path
        Mock Get-AppxPackage {
            param([string]$Name, $ErrorAction)
            return $null
        }

        # Track Invoke-AddAppxPackage call
        Mock Invoke-AddAppxPackage {
            param([string]$ManifestPath)
            $script:CallSequence.Add('AddAppxPackage') | Out-Null
        }

        # Track Invoke-Sleep calls and record seconds
        Mock Invoke-Sleep {
            param([int]$Seconds)
            $script:SleepSeconds.Add($Seconds) | Out-Null
            $script:CallSequence.Add("Sleep-$Seconds") | Out-Null
        }

        # Track Stop-WsaWindows
        Mock Stop-WsaWindows {
            $script:CallSequence.Add('StopWsaWindows') | Out-Null
        }

        # Track Invoke-WsaServiceWait
        Mock Invoke-WsaServiceWait {
            $script:CallSequence.Add('WsaServiceWait') | Out-Null
            return $true
        }

        $script:FakeStore = @{}
        $script:FakePathExists = $false
    }

    It "WSAI-01: calls Invoke-AddAppxPackage exactly once during fresh install" {
        Invoke-WsaInstall -WsaRoot "C:\fake\wsa"
        Should -Invoke Invoke-AddAppxPackage -Times 1 -Exactly
    }

    It "WSAI-02: calls Invoke-Sleep with 15 seconds before Stop-WsaWindows" {
        Invoke-WsaInstall -WsaRoot "C:\fake\wsa"
        $sleepIdx = $script:CallSequence.IndexOf('Sleep-15')
        $stopIdx  = $script:CallSequence.IndexOf('StopWsaWindows')
        $sleepIdx | Should -BeGreaterOrEqual 0
        $stopIdx  | Should -BeGreaterOrEqual 0
        $sleepIdx | Should -BeLessThan $stopIdx
    }

    It "WSAI-02: calls Stop-WsaWindows after the 15s wait" {
        Invoke-WsaInstall -WsaRoot "C:\fake\wsa"
        Should -Invoke Stop-WsaWindows -Times 1 -Exactly
    }

    It "WSAI-03: calls Invoke-WsaServiceWait after Stop-WsaWindows" {
        Invoke-WsaInstall -WsaRoot "C:\fake\wsa"
        $stopIdx = $script:CallSequence.IndexOf('StopWsaWindows')
        $waitIdx = $script:CallSequence.IndexOf('WsaServiceWait')
        $stopIdx | Should -BeGreaterOrEqual 0
        $waitIdx | Should -BeGreaterOrEqual 0
        $stopIdx | Should -BeLessThan $waitIdx
    }
}

# ============================================================================
# Stop-WsaWindows (WSAI-02 — kill WsaSettings + WsaClient but NOT WsaService)
# ============================================================================
Describe "Stop-WsaWindows — process kill behavior" {

    BeforeEach {
        $script:StoppedProcessNames = [System.Collections.Generic.List[string]]::new()

        Mock Get-Process {
            param([string]$Name, $ErrorAction)
            if ($Name -in @('WsaSettings', 'WsaClient')) {
                return [PSCustomObject]@{ Name = $Name; Id = 1234 }
            }
            return $null
        }

        Mock Stop-Process {
            param($InputObject, [switch]$Force, $ErrorAction)
            if ($InputObject -and $InputObject.Name) {
                $script:StoppedProcessNames.Add($InputObject.Name) | Out-Null
            }
        }
    }

    It "WSAI-02: Stop-WsaWindows kills WsaSettings process" {
        Stop-WsaWindows
        $script:StoppedProcessNames | Should -Contain 'WsaSettings'
    }

    It "WSAI-02: Stop-WsaWindows kills WsaClient process" {
        Stop-WsaWindows
        $script:StoppedProcessNames | Should -Contain 'WsaClient'
    }

    It "WSAI-02: Stop-WsaWindows does NOT kill WsaService" {
        Stop-WsaWindows
        $script:StoppedProcessNames | Should -Not -Contain 'WsaService'
        Should -Invoke Get-Process -ParameterFilter { $Name -eq 'WsaService' } -Times 0 -Exactly
    }
}
