#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0" }
# WsaConfigure.Tests.ps1 — Pester unit tests for steps/04-wsa-configure.ps1
# Covers all 5 requirements: ADBM-01, ADBM-02, ADBM-03, ADBM-04, ADBM-05
# All system calls are mocked to prevent actual registry writes, ADB calls, or process kills.

BeforeAll {
    # Set up a temp log file for Write-Log calls
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "BarakaWsaConfigureTests-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    $script:LogFile = Join-Path $script:TestRoot "deploy.log"

    $script:LibDir   = (Resolve-Path (Join-Path $PSScriptRoot "..\lib")).Path
    $script:StepPath = (Join-Path $PSScriptRoot "..\steps\04-wsa-configure.ps1")

    Import-Module (Join-Path $script:LibDir "Log.psm1")   -Force
    Import-Module (Join-Path $script:LibDir "State.psm1") -Force
    Import-Module (Join-Path $script:LibDir "Guard.psm1") -Force

    Initialize-Log -Path $script:LogFile

    # In-memory registry store for State mock (Baraka's own HKLM path)
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

    # Stub Windows-only cmdlets that don't exist on Linux test runners.
    # These stubs are replaced by per-test Mocks but must exist for Pester
    # to intercept them. Without stubs, Mock fails with CommandNotFoundException
    # on non-Windows platforms.
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        function global:Get-AppxPackage { param([string]$Name, $ErrorAction) }
    }
    if (-not (Get-Command Get-Process -ErrorAction SilentlyContinue)) {
        function global:Get-Process { param([string]$Name, $ErrorAction) }
    }
    if (-not (Get-Command Stop-Process -ErrorAction SilentlyContinue)) {
        function global:Stop-Process { param([switch]$Force, $ErrorAction) }
    }
    if (-not (Get-Command Start-Process -ErrorAction SilentlyContinue)) {
        function global:Start-Process { param([string]$FilePath, [string]$ArgumentList, $ErrorAction) }
    }
    # Stub WSA-specific registry cmdlets at script scope (NOT in State module mock).
    # The step writes to HKCU:\Software\Microsoft\WindowsSubsystemForAndroid and
    # HKCU:\Software\Microsoft\WSA — these are not Baraka deploy state paths.
    if (-not (Get-Command New-Item -ErrorAction SilentlyContinue)) {
        # New-Item already exists as a built-in; this branch won't fire but keeps the pattern
        function global:New-Item { param([string]$Path, [string]$ItemType, [switch]$Force) }
    }

    # Load the step file with BARAKA_TEST_MODE=1 to prevent auto-execution.
    # The step file does not exist yet (RED phase) — the dot-source will fail,
    # but tests will still be collected and fail as expected.
    $env:BARAKA_TEST_MODE = '1'
    try {
        . $script:StepPath
    } catch {
        # Expected in RED phase — step file does not exist yet
    }
}

AfterAll {
    Remove-Module Guard -ErrorAction SilentlyContinue
    Remove-Module State -ErrorAction SilentlyContinue
    Remove-Module Log   -ErrorAction SilentlyContinue
    Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    $env:BARAKA_TEST_MODE = $null
}

# ============================================================================
# Set-WsaDeveloperMode (ADBM-01, ADBM-02)
# ============================================================================
Describe "Set-WsaDeveloperMode" {

    BeforeEach {
        $script:RegWrites = [System.Collections.Generic.List[hashtable]]::new()
        $script:NewItemCalls = [System.Collections.Generic.List[string]]::new()
        $script:WsaRestartCalled = $false

        # Track Set-ItemProperty calls at script scope (WSA registry paths)
        Mock Set-ItemProperty {
            param([string]$Path, [string]$Name, $Value, $PropertyType)
            $script:RegWrites.Add(@{ Path = $Path; Name = $Name; Value = $Value; PropertyType = $PropertyType }) | Out-Null
        }

        # Track New-Item calls for registry path creation
        Mock New-Item {
            param([string]$Path, [string]$ItemType, [switch]$Force)
            $script:NewItemCalls.Add($Path) | Out-Null
        }

        # Test-Path returns false so New-Item is called for path creation
        Mock Test-Path { return $false }

        # Mock Invoke-WsaRestart to track that it's called
        Mock Invoke-WsaRestart { $script:WsaRestartCalled = $true }
    }

    It "ADBM-01: writes DeveloperMode=1 (DWord) to HKCU:\Software\Microsoft\WindowsSubsystemForAndroid" {
        Set-WsaDeveloperMode

        $devModeWrite = $script:RegWrites | Where-Object {
            $_.Path -like "*WindowsSubsystemForAndroid*" -and $_.Name -eq "DeveloperMode"
        }
        $devModeWrite | Should -Not -BeNullOrEmpty
        $devModeWrite.Value | Should -Be 1
    }

    It "ADBM-02: writes VMLifeCycleMode='Continuous' (String) to HKCU:\Software\Microsoft\WSA" {
        Set-WsaDeveloperMode

        $vmLifeWrite = $script:RegWrites | Where-Object {
            $_.Path -like "*\WSA*" -and $_.Name -eq "VMLifeCycleMode"
        }
        $vmLifeWrite | Should -Not -BeNullOrEmpty
        $vmLifeWrite.Value | Should -Be "Continuous"
    }

    It "ADBM-01/ADBM-02: creates registry paths when they don't exist (New-Item called)" {
        Set-WsaDeveloperMode

        Should -Invoke New-Item -Times 2 -Exactly
    }

    It "ADBM-01: calls Invoke-WsaRestart after writing registry keys" {
        Set-WsaDeveloperMode

        $script:WsaRestartCalled | Should -BeTrue
        Should -Invoke Invoke-WsaRestart -Times 1 -Exactly
    }
}

# ============================================================================
# Invoke-WsaRestart
# ============================================================================
Describe "Invoke-WsaRestart" {

    BeforeEach {
        $script:SleepCalls = [System.Collections.Generic.List[int]]::new()

        Mock Get-AppxPackage {
            param([string]$Name, $ErrorAction)
            return [PSCustomObject]@{
                InstallLocation = "/mock/wsa"
            }
        }
        Mock Get-Process {
            param([string]$Name, $ErrorAction)
            return $null
        }
        Mock Stop-Process { }
        Mock Start-Process { }
        Mock Invoke-Sleep {
            param([int]$Seconds)
            $script:SleepCalls.Add($Seconds) | Out-Null
        }
    }

    It "stops WsaService, WsaClient, and WsaSettings processes" {
        Invoke-WsaRestart

        Should -Invoke Stop-Process -Times 3 -Exactly
    }

    It "relaunches WsaClient.exe via Start-Process with /launch wsa://system" {
        Invoke-WsaRestart

        Should -Invoke Start-Process -ParameterFilter {
            $FilePath -like "*WsaClient*" -and $ArgumentList -like "*wsa://system*"
        } -Times 1 -Exactly
    }

    It "waits 10 seconds after relaunch via Invoke-Sleep" {
        Invoke-WsaRestart

        $script:SleepCalls | Should -Contain 10
    }
}

# ============================================================================
# Connect-Adb — successful connection (ADBM-04)
# ============================================================================
Describe "Connect-Adb — successful connection" {

    BeforeEach {
        $script:SleepCalls = [System.Collections.Generic.List[int]]::new()

        Mock Invoke-AdbCommand {
            param([string]$AdbPath, [string]$Arguments)
            if ($Arguments -like "devices*") {
                return "List of devices attached`r`n127.0.0.1:58526`tdevice`r`n"
            }
            return "connected to 127.0.0.1:58526"
        }
        Mock Invoke-Sleep {
            param([int]$Seconds)
            $script:SleepCalls.Add($Seconds) | Out-Null
        }
    }

    It "ADBM-04: returns `$true when adb devices output contains endpoint + 'device'" {
        $result = Connect-Adb -AdbPath "fake-adb.exe"

        $result | Should -BeTrue
    }

    It "ADBM-04: succeeds on first attempt without calling Invoke-Sleep" {
        Connect-Adb -AdbPath "fake-adb.exe"

        $script:SleepCalls.Count | Should -Be 0
    }
}

# ============================================================================
# Connect-Adb — eventual success (ADBM-03)
# ============================================================================
Describe "Connect-Adb — eventual success after retries" {

    BeforeEach {
        $script:AdbDevicesCallCount = 0
        $script:SleepCalls = [System.Collections.Generic.List[int]]::new()

        Mock Invoke-AdbCommand {
            param([string]$AdbPath, [string]$Arguments)
            if ($Arguments -like "devices*") {
                $script:AdbDevicesCallCount++
                if ($script:AdbDevicesCallCount -ge 3) {
                    return "List of devices attached`r`n127.0.0.1:58526`tdevice`r`n"
                }
                return "List of devices attached`r`n"
            }
            return "connecting to 127.0.0.1:58526"
        }
        Mock Invoke-Sleep {
            param([int]$Seconds)
            $script:SleepCalls.Add($Seconds) | Out-Null
        }
    }

    It "ADBM-03: returns `$true after 3 attempts when 3rd attempt succeeds" {
        $result = Connect-Adb -AdbPath "fake-adb.exe"

        $result | Should -BeTrue
    }

    It "ADBM-03: calls Invoke-Sleep twice before the successful 3rd attempt" {
        Connect-Adb -AdbPath "fake-adb.exe"

        # 2 failed attempts = 2 sleep calls before the 3rd succeeds
        $script:SleepCalls.Count | Should -Be 2
    }
}

# ============================================================================
# Connect-Adb — all retries exhausted (ADBM-03, ADBM-05)
# ============================================================================
Describe "Connect-Adb — all retries exhausted" {

    BeforeEach {
        $script:AdbAttempts = 0
        $script:SleepCalls = [System.Collections.Generic.List[int]]::new()

        Mock Invoke-AdbCommand {
            param([string]$AdbPath, [string]$Arguments)
            if ($Arguments -like "devices*") {
                $script:AdbAttempts++
            }
            # Never return a connected device
            return "List of devices attached`r`n"
        }
        Mock Invoke-Sleep {
            param([int]$Seconds)
            $script:SleepCalls.Add($Seconds) | Out-Null
        }
    }

    It "ADBM-03: makes exactly MaxAttempts (3) attempts when all fail" {
        Connect-Adb -AdbPath "fake-adb.exe" -MaxAttempts 3 -BaseDelaySec 1

        $script:AdbAttempts | Should -Be 3
    }

    It "ADBM-03: delay increases exponentially (1, 2 seconds for MaxAttempts=3, BaseDelaySec=1)" {
        Connect-Adb -AdbPath "fake-adb.exe" -MaxAttempts 3 -BaseDelaySec 1

        # With BaseDelaySec=1: attempt 1 delay=1, attempt 2 delay=2; no delay after last attempt
        $script:SleepCalls.Count | Should -Be 2
        $script:SleepCalls[0] | Should -Be 1
        $script:SleepCalls[1] | Should -Be 2
    }

    It "ADBM-05: returns `$false when all retries are exhausted" {
        $result = Connect-Adb -AdbPath "fake-adb.exe" -MaxAttempts 3 -BaseDelaySec 1

        $result | Should -BeFalse
    }

    It "ADBM-05: WARN log lines contain 'MANUAL ACTION REQUIRED' when all retries fail" {
        Connect-Adb -AdbPath "fake-adb.exe" -MaxAttempts 3 -BaseDelaySec 1

        $logContent = Get-Content -Path $script:LogFile -Raw
        $logContent | Should -Match "MANUAL ACTION REQUIRED"
    }
}

# ============================================================================
# Invoke-WsaConfigure — ADB failure throws (ADBM-05)
# ============================================================================
Describe "Invoke-WsaConfigure — ADB failure throws" {

    BeforeEach {
        Mock Set-WsaDeveloperMode { }
        Mock Connect-Adb { return $false }
    }

    It "ADBM-05: throws when Connect-Adb returns `$false to prevent Guard from setting done flag" {
        { Invoke-WsaConfigure -AdbPath "fake-adb.exe" } | Should -Throw
    }
}
