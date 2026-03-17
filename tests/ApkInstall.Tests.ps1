#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0" }
# ApkInstall.Tests.ps1 — Pester unit tests for steps/05-apk-install.ps1
# Covers requirements: APKS-01, APKS-02, APKS-03
# All ADB calls are mocked via test seams to prevent real device interaction.

BeforeAll {
    # Set up a temp directory and log file for Write-Log calls
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "BarakaApkInstallTests-$([System.Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    $script:LogFile = Join-Path $script:TestRoot "deploy.log"

    # Create a fake APK file in the temp dir for auto-detection tests
    New-Item -Path (Join-Path $script:TestRoot "test-app.apk") -ItemType File -Force | Out-Null

    $script:LibDir   = (Resolve-Path (Join-Path $PSScriptRoot "..\lib")).Path
    $script:StepPath = (Join-Path $PSScriptRoot "..\steps\05-apk-install.ps1")

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
# Find-ApkFile (APKS-02)
# ============================================================================
Describe "Find-ApkFile" {

    It "APKS-02: returns APK path when *.apk file exists in bundle directory" {
        $result = Find-ApkFile -BundleRoot $script:TestRoot
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match "\.apk$"
    }

    It "APKS-02: throws when no APK file found in directory" {
        $emptyDir = Join-Path $script:TestRoot "empty-subdir"
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        { Find-ApkFile -BundleRoot $emptyDir } | Should -Throw
    }
}

# ============================================================================
# Get-InstalledApkVersionCode (APKS-01)
# ============================================================================
Describe "Get-InstalledApkVersionCode" {

    It "APKS-01: returns -1 when package is not found in pm list output" {
        Mock Invoke-AdbCommand { return "package:com.other.app`npackage:com.example.foo" }
        $result = Get-InstalledApkVersionCode -AdbPath "adb" -PackageName "com.baraka.pos"
        $result | Should -Be -1
    }

    It "APKS-01: returns 1 when package is found in pm list output" {
        Mock Invoke-AdbCommand { return "package:com.other.app`npackage:com.baraka.pos`npackage:com.example.foo" }
        $result = Get-InstalledApkVersionCode -AdbPath "adb" -PackageName "com.baraka.pos"
        $result | Should -Be 1
    }
}

# ============================================================================
# Invoke-ApkInstall — package already installed (APKS-01)
# ============================================================================
Describe "Invoke-ApkInstall — package already installed" {

    BeforeEach {
        Mock Get-InstalledApkVersionCode { return 1 }
        Mock Invoke-ApkInstallCommand { return "Success" }
    }

    It "APKS-01: does NOT call Invoke-ApkInstallCommand when package already present" {
        Invoke-ApkInstall -AdbPath "adb" -BundleRoot $script:TestRoot -PackageName "com.baraka.pos"
        Should -Invoke Invoke-ApkInstallCommand -Times 0 -Exactly
    }

    It "APKS-01: logs 'already installed' message when package already present" {
        Invoke-ApkInstall -AdbPath "adb" -BundleRoot $script:TestRoot -PackageName "com.baraka.pos"
        $logContent = Get-Content -Path $script:LogFile -Raw -ErrorAction SilentlyContinue
        $logContent | Should -Match "already installed"
    }
}

# ============================================================================
# Invoke-ApkInstall — fresh install success (APKS-03)
# ============================================================================
Describe "Invoke-ApkInstall — fresh install success" {

    BeforeEach {
        $script:VersionCallCount = 0
        Mock Get-InstalledApkVersionCode {
            $script:VersionCallCount++
            if ($script:VersionCallCount -eq 1) { return -1 }
            return 1
        }
        Mock Invoke-ApkInstallCommand { return "Success" }
    }

    It "APKS-03: calls Invoke-ApkInstallCommand once for fresh install" {
        Invoke-ApkInstall -AdbPath "adb" -BundleRoot $script:TestRoot -PackageName "com.baraka.pos"
        Should -Invoke Invoke-ApkInstallCommand -Times 1 -Exactly
    }

    It "APKS-03: logs success message after successful install" {
        Invoke-ApkInstall -AdbPath "adb" -BundleRoot $script:TestRoot -PackageName "com.baraka.pos"
        $logContent = Get-Content -Path $script:LogFile -Raw -ErrorAction SilentlyContinue
        $logContent | Should -Match "(?i)success|installed successfully"
    }
}

# ============================================================================
# Invoke-ApkInstall — install failure (APKS-03)
# ============================================================================
Describe "Invoke-ApkInstall — install failure" {

    BeforeEach {
        Mock Get-InstalledApkVersionCode { return -1 }
        Mock Invoke-ApkInstallCommand { return "Failure [INSTALL_FAILED_ALREADY_EXISTS]" }
    }

    It "APKS-03: throws when adb install output does not contain 'Success'" {
        { Invoke-ApkInstall -AdbPath "adb" -BundleRoot $script:TestRoot -PackageName "com.baraka.pos" } | Should -Throw
    }
}
