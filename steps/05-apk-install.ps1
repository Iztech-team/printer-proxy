# steps/05-apk-install.ps1 — APK auto-detection, version check, and installation
# Auto-detects the APK from the bundle directory, skips if already installed,
# and installs via adb install -r with success verification.
# Dot-sourced by deploy.ps1 inside an Invoke-Step body.
#
# Requirements: APKS-01, APKS-02, APKS-03
# Requires: Write-Log (Log.psm1) to be imported before dot-sourcing.

# ---------------------------------------------------------------------------
# Invoke-AdbCommand — Test seam for ADB binary calls (APKS-03).
# Returns combined stdout+stderr as a string.
# Exists so tests can mock ADB output without a real ADB binary.
# ---------------------------------------------------------------------------
function Invoke-AdbCommand {
    param(
        [string]$AdbPath,
        [string]$Arguments
    )
    $result = & $AdbPath $Arguments.Split(' ') 2>&1 | Out-String
    return $result
}

# ---------------------------------------------------------------------------
# Find-ApkFile (APKS-02)
# Searches BundleRoot for *.apk files using Get-ChildItem.
# Returns the full path of the first APK found.
# Throws with a clear message if no APK found in bundle directory.
# ---------------------------------------------------------------------------
function Find-ApkFile {
    param(
        [string]$BundleRoot
    )
    $apk = Get-ChildItem -Path $BundleRoot -Filter "*.apk" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $apk) {
        throw "No APK file found in bundle directory: $BundleRoot"
    }
    Write-Log -Level "INFO" -Message "Found APK: $($apk.FullName)"
    return $apk.FullName
}

# ---------------------------------------------------------------------------
# Get-InstalledApkVersionCode (APKS-01)
# Queries adb shell pm list packages for the package name.
# Returns 1 if the package is present (treat any installed version as current
# since aapt is unavailable for precise version comparison).
# Returns -1 if the package is not found (triggers install).
# ---------------------------------------------------------------------------
function Get-InstalledApkVersionCode {
    param(
        [string]$AdbPath,
        [string]$PackageName
    )
    $pkgList = Invoke-AdbCommand -AdbPath $AdbPath -Arguments "shell pm list packages"
    if ($pkgList -match "package:$([regex]::Escape($PackageName))") {
        return 1  # Package present (without aapt, treat any version as current)
    }
    return -1  # Not installed
}

# ---------------------------------------------------------------------------
# Invoke-ApkInstallCommand — Test seam for adb install call (APKS-03).
# Executes adb install -r and returns output as a trimmed string.
# Exists so tests can mock the install output without a real device.
# ---------------------------------------------------------------------------
function Invoke-ApkInstallCommand {
    param(
        [string]$AdbPath,
        [string]$ApkPath
    )
    $result = & $AdbPath install -r $ApkPath 2>&1 | Out-String
    return $result.Trim()
}

# ---------------------------------------------------------------------------
# Invoke-ApkInstall — Main orchestrator (APKS-01, APKS-02, APKS-03)
# 1. Auto-detects APK from bundle directory (APKS-02)
# 2. Skips install if package already present (APKS-01)
# 3. Installs via adb install -r and verifies success string (APKS-03)
#
# Parameters:
#   AdbPath     — Path to adb.exe binary
#   BundleRoot  — Directory to search for *.apk files
#   PackageName — Android package name to check/install
# ---------------------------------------------------------------------------
function Invoke-ApkInstall {
    param(
        [string]$AdbPath = (Join-Path $PSScriptRoot '..\adb\adb.exe'),
        [string]$BundleRoot = (Join-Path $PSScriptRoot '..'),
        [string]$PackageName = "com.baraka.pos"
    )

    $apkPath = Find-ApkFile -BundleRoot $BundleRoot

    # APKS-01: Check if already installed — skip if package present
    $installedVersion = Get-InstalledApkVersionCode -AdbPath $AdbPath -PackageName $PackageName
    if ($installedVersion -ge 0) {
        Write-Log -Level "INFO" -Message "APK $PackageName already installed -- skipping"
        return
    }

    # APKS-03: Install via adb install -r
    Write-Log -Level "INFO" -Message "Installing APK: $apkPath"
    $result = Invoke-ApkInstallCommand -AdbPath $AdbPath -ApkPath $apkPath
    if ($result -notmatch "Success") {
        throw "APK install failed: $result"
    }
    Write-Log -Level "INFO" -Message "APK installed successfully"
}

# ---------------------------------------------------------------------------
# Entry point: called when dot-sourced by deploy.ps1's Invoke-Step body.
# The guard prevents auto-execution when dot-sourced from unit tests.
# ---------------------------------------------------------------------------
if (-not $env:BARAKA_TEST_MODE) {
    Invoke-ApkInstall
}
