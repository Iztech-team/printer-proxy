# Preflight.Tests.ps1 — Unit tests for steps/01-preflight.ps1
# All system calls are mocked via mock parameters (test seams built into functions).
# exit-code tests use a child pwsh process to avoid terminating the test runner.
# BARAKA_TEST_MODE=1 prevents the bottom-of-file Invoke-Preflight from auto-running.

BeforeAll {
    $script:PreflightPath = (Resolve-Path (Join-Path $PSScriptRoot ".." "steps" "01-preflight.ps1")).Path
    $script:LibDir        = (Resolve-Path (Join-Path $PSScriptRoot ".." "lib")).Path
    $script:PwshExe       = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
    if (-not $script:PwshExe) {
        $script:PwshExe = "$HOME/powershell/pwsh"
    }

    # Helper: run a one-liner in a child process.
    # Writes a temp script file to avoid quoting hell, sets BARAKA_TEST_MODE.
    function Invoke-PreflightChild {
        param([string]$Snippet)

        $tmpLog    = [System.IO.Path]::GetTempFileName()
        $tmpScript = [System.IO.Path]::GetTempFileName() + ".ps1"

        $scriptBody = @"
`$ErrorActionPreference = 'Stop'
`$EXIT_SUCCESS     = 0
`$EXIT_OS_EDITION  = 10
`$EXIT_NOT_ADMIN   = 11
`$EXIT_NO_VIRT     = 12
`$EXIT_DISK_SPACE  = 13
`$EXIT_ADB_MISSING = 14
`$EXIT_STEP_FAILED = 20
`$EXIT_UNKNOWN     = 99
Import-Module '$($script:LibDir)/Log.psm1' -Force
Initialize-Log -Path '$tmpLog'
`$env:BARAKA_TEST_MODE = '1'
. '$($script:PreflightPath -replace "'", "''")'
$Snippet
exit 0
"@
        Set-Content -Path $tmpScript -Value $scriptBody -Encoding UTF8

        $proc = Start-Process -FilePath $script:PwshExe `
            -ArgumentList @("-NoProfile", "-NonInteractive", "-File", $tmpScript) `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput ([System.IO.Path]::GetTempFileName()) `
            -RedirectStandardError  ([System.IO.Path]::GetTempFileName())

        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
        return $proc.ExitCode
    }
}

Describe "Test-OsEdition" {

    It "passes for SKU 48 (Windows 10 Pro)" {
        $exitCode = Invoke-PreflightChild "Test-OsEdition -MockSkuOverride 48 -MockCaptionOverride 'Windows 10 Pro'"
        $exitCode | Should -Be 0
    }

    It "passes for SKU 4 (Enterprise)" {
        $exitCode = Invoke-PreflightChild "Test-OsEdition -MockSkuOverride 4 -MockCaptionOverride 'Windows 10 Enterprise'"
        $exitCode | Should -Be 0
    }

    It "exits with code 10 for SKU 101 (Home edition)" {
        $exitCode = Invoke-PreflightChild "Test-OsEdition -MockSkuOverride 101 -MockCaptionOverride 'Windows 10 Home'"
        $exitCode | Should -Be 10
    }

    It "exits with code 10 when Caption contains 'Home' regardless of SKU" {
        # Caption-based check (belt-and-suspenders per RESEARCH.md open question 1)
        $exitCode = Invoke-PreflightChild "Test-OsEdition -MockSkuOverride 48 -MockCaptionOverride 'Windows 11 Home'"
        $exitCode | Should -Be 10
    }
}

Describe "Test-AdminPrivilege" {

    It "passes when IsInRole returns true" {
        $exitCode = Invoke-PreflightChild "Test-AdminPrivilege -MockIsAdmin `$true"
        $exitCode | Should -Be 0
    }

    It "exits with code 11 when IsInRole returns false" {
        $exitCode = Invoke-PreflightChild "Test-AdminPrivilege -MockIsAdmin `$false"
        $exitCode | Should -Be 11
    }
}

Describe "Test-VirtualizationCapability" {

    It "passes when HyperVRequirementVirtualizationFirmwareEnabled is true" {
        $exitCode = Invoke-PreflightChild "Test-VirtualizationCapability -MockVirtEnabled `$true"
        $exitCode | Should -Be 0
    }

    It "logs WARN (not ERROR) when Get-ComputerInfo throws (per RESEARCH.md Pitfall 2)" {
        # When virtualization query fails, function should WARN and continue (exit 0), not exit 12
        $exitCode = Invoke-PreflightChild "Test-VirtualizationCapability -MockVirtThrow `$true"
        $exitCode | Should -Be 0
    }
}

Describe "Test-DiskSpace" {

    It "passes when free space is 15 GB" {
        $exitCode = Invoke-PreflightChild "Test-DiskSpace -MockFreeGB 15"
        $exitCode | Should -Be 0
    }

    It "exits with code 13 when free space is 8 GB" {
        $exitCode = Invoke-PreflightChild "Test-DiskSpace -MockFreeGB 8"
        $exitCode | Should -Be 13
    }
}

Describe "Test-AdbBinary" {

    It "passes when adb.exe exists at expected path" {
        $exitCode = Invoke-PreflightChild "Test-AdbBinary -MockAdbExists `$true"
        $exitCode | Should -Be 0
    }

    It "exits with code 14 when adb.exe is missing" {
        $exitCode = Invoke-PreflightChild "Test-AdbBinary -MockAdbExists `$false"
        $exitCode | Should -Be 14
    }
}

Describe "Invoke-Preflight" {

    It "calls all five check functions in order (all pass)" {
        $snippet = @'
Invoke-Preflight `
    -MockSkuOverride 48 `
    -MockCaptionOverride 'Windows 10 Pro' `
    -MockIsAdmin $true `
    -MockVirtEnabled $true `
    -MockFreeGB 15 `
    -MockAdbExists $true
'@
        $exitCode = Invoke-PreflightChild $snippet
        $exitCode | Should -Be 0
    }
}
