# steps/01-preflight.ps1 — Pre-flight validation checks for Baraka deployment
# Validates five prerequisites before any system mutation occurs.
# Dot-sourced by deploy.ps1 inside an Invoke-Step body.
#
# Requires: $EXIT_OS_EDITION, $EXIT_NOT_ADMIN, $EXIT_NO_VIRT,
#           $EXIT_DISK_SPACE, $EXIT_ADB_MISSING to be defined in caller scope.
# Requires: Write-Log (Log.psm1) to be imported.

# ---------------------------------------------------------------------------
# Check 1: OS edition (Pro or Enterprise only)
# Belt-and-suspenders: Caption-based check AND SKU check
# (RESEARCH.md open question 1 — handles Win10 and Win11 variants)
# ---------------------------------------------------------------------------
function Test-OsEdition {
    param(
        # Test seam: pass a non-null value to bypass WMI calls
        [int]$MockSkuOverride = -1,
        [string]$MockCaptionOverride = ""
    )

    if ($MockSkuOverride -ge 0) {
        $sku     = $MockSkuOverride
        $caption = $MockCaptionOverride
    } else {
        $os      = Get-WmiObject -Class Win32_OperatingSystem
        $sku     = $os.OperatingSystemSKU
        $caption = $os.Caption
    }

    # Caption-based check: reject anything with "Home" in the name
    if ($caption -match "Home") {
        Write-Log -Level "ERROR" -Message "Pre-flight FAILED: OS edition is not Pro/Enterprise. Caption: $caption"
        exit $EXIT_OS_EDITION
    }

    # SKU-based check: allow known Pro/Enterprise SKUs
    $allowedSkus = @(
        48,  # Windows 10 Pro
        49,  # Windows 10 Pro N
        4,   # Windows Enterprise
        27,  # Windows Enterprise N
        70,  # Windows Enterprise E
        125, # Windows 10 Pro
        126  # Windows 10 Pro N (Education)
    )

    if ($sku -notin $allowedSkus) {
        Write-Log -Level "ERROR" -Message "Pre-flight FAILED: OS SKU $sku is not a Pro/Enterprise variant. Caption: $caption"
        exit $EXIT_OS_EDITION
    }

    Write-Log -Level "INFO" -Message "Pre-flight OK: OS edition is compatible. Caption: $caption, SKU: $sku"
}

# ---------------------------------------------------------------------------
# Check 2: Administrator privilege
# ---------------------------------------------------------------------------
function Test-AdminPrivilege {
    param(
        # Test seam: pass $true/$false to bypass Windows identity check
        [object]$MockIsAdmin = $null
    )

    if ($null -ne $MockIsAdmin) {
        $isAdmin = [bool]$MockIsAdmin
    } else {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $isAdmin   = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    if (-not $isAdmin) {
        Write-Log -Level "ERROR" -Message "Pre-flight FAILED: Script is not running as Administrator. Re-run as Administrator."
        exit $EXIT_NOT_ADMIN
    }

    Write-Log -Level "INFO" -Message "Pre-flight OK: Running as Administrator."
}

# ---------------------------------------------------------------------------
# Check 3: BIOS virtualization
# WARN-only on Get-ComputerInfo failures (RESEARCH.md Pitfall 2 — false negatives)
# ---------------------------------------------------------------------------
function Test-VirtualizationCapability {
    param(
        # Test seams
        [object]$MockVirtEnabled = $null,
        [bool]$MockVirtThrow     = $false
    )

    if ($MockVirtThrow) {
        # Simulate Get-ComputerInfo throwing
        Write-Log -Level "WARN" -Message "Pre-flight WARNING: Could not query virtualization status (Get-ComputerInfo unavailable). Proceeding with caution."
        return
    }

    if ($null -ne $MockVirtEnabled) {
        $virtEnabled = [bool]$MockVirtEnabled
    } else {
        try {
            $info        = Get-ComputerInfo -Property HyperVRequirementVirtualizationFirmwareEnabled
            $virtEnabled = $info.HyperVRequirementVirtualizationFirmwareEnabled
        } catch {
            Write-Log -Level "WARN" -Message "Pre-flight WARNING: Could not query virtualization status: $($_.Exception.Message). Proceeding with caution."
            return
        }
    }

    if ($virtEnabled -eq $false) {
        Write-Log -Level "ERROR" -Message "Pre-flight FAILED: BIOS virtualization (VT-x/AMD-V) is disabled. Enable it in BIOS/UEFI firmware settings."
        exit $EXIT_NO_VIRT
    }

    Write-Log -Level "INFO" -Message "Pre-flight OK: BIOS virtualization is enabled."
}

# ---------------------------------------------------------------------------
# Check 4: Disk space (minimum 12 GB free on C:)
# ---------------------------------------------------------------------------
function Test-DiskSpace {
    param(
        # Test seam: supply free GB directly
        [int]$MockFreeGB = -1
    )

    if ($MockFreeGB -ge 0) {
        $freeGB = $MockFreeGB
    } else {
        $drive  = Get-PSDrive -Name C
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
    }

    $thresholdGB = 12

    if ($freeGB -lt $thresholdGB) {
        Write-Log -Level "ERROR" -Message "Pre-flight FAILED: Insufficient free disk space. Required: ${thresholdGB} GB, Available: ${freeGB} GB."
        exit $EXIT_DISK_SPACE
    }

    Write-Log -Level "INFO" -Message "Pre-flight OK: Disk space is sufficient. Free: ${freeGB} GB."
}

# ---------------------------------------------------------------------------
# Check 5: ADB binary present in bundle
# Uses GetFullPath to resolve relative paths correctly (RESEARCH.md Pitfall 3)
# ---------------------------------------------------------------------------
function Test-AdbBinary {
    param(
        # Test seam: supply existence result directly
        [object]$MockAdbExists = $null
    )

    if ($null -ne $MockAdbExists) {
        $exists = [bool]$MockAdbExists
        $adbPath = "<mocked>"
    } else {
        $rawPath = Join-Path $PSScriptRoot "..\adb\adb.exe"
        $adbPath = [System.IO.Path]::GetFullPath($rawPath)
        $exists  = Test-Path $adbPath
    }

    if (-not $exists) {
        Write-Log -Level "ERROR" -Message "Pre-flight FAILED: ADB binary not found in bundle. Expected path: $adbPath"
        exit $EXIT_ADB_MISSING
    }

    Write-Log -Level "INFO" -Message "Pre-flight OK: ADB binary found at: $adbPath"
}

# ---------------------------------------------------------------------------
# Invoke-Preflight — calls all five checks in sequence
# ---------------------------------------------------------------------------
function Invoke-Preflight {
    param(
        # Pass-through test seams for each check
        [int]$MockSkuOverride        = -1,
        [string]$MockCaptionOverride = "",
        [object]$MockIsAdmin         = $null,
        [object]$MockVirtEnabled     = $null,
        [bool]$MockVirtThrow         = $false,
        [int]$MockFreeGB             = -1,
        [object]$MockAdbExists       = $null
    )

    Test-OsEdition          -MockSkuOverride $MockSkuOverride -MockCaptionOverride $MockCaptionOverride
    Test-AdminPrivilege     -MockIsAdmin $MockIsAdmin
    Test-VirtualizationCapability -MockVirtEnabled $MockVirtEnabled -MockVirtThrow $MockVirtThrow
    Test-DiskSpace          -MockFreeGB $MockFreeGB
    Test-AdbBinary          -MockAdbExists $MockAdbExists
}

# ---------------------------------------------------------------------------
# Entry point: called when dot-sourced by deploy.ps1's Invoke-Step body.
# The guard prevents auto-execution when dot-sourced from unit tests.
# ---------------------------------------------------------------------------
if (-not $env:BARAKA_TEST_MODE) {
    Invoke-Preflight
}
