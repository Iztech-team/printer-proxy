#Requires -Version 5.1
# deploy.ps1 — Baraka Store Terminal Deployment Entry Point
# Run as: powershell.exe -ExecutionPolicy Bypass -File deploy.ps1
# Must be run as Administrator on the target terminal.

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Exit code taxonomy (CORE-04 / RESEARCH.md Pattern 4)
# ---------------------------------------------------------------------------
$EXIT_SUCCESS     = 0   # All steps completed successfully
$EXIT_OS_EDITION  = 10  # OS is not Pro or Enterprise
$EXIT_NOT_ADMIN   = 11  # Not running as Administrator
$EXIT_NO_VIRT     = 12  # BIOS virtualization disabled
$EXIT_DISK_SPACE  = 13  # Insufficient free disk space (< 12 GB)
$EXIT_ADB_MISSING = 14  # ADB binary not found in bundle
$EXIT_STEP_FAILED = 20  # A deployment step threw an unhandled exception
$EXIT_UNKNOWN     = 99  # Unexpected error outside of step handling

# ---------------------------------------------------------------------------
# Module import
# ---------------------------------------------------------------------------
$LibDir = Join-Path $PSScriptRoot "lib"
Import-Module (Join-Path $LibDir "Log.psm1")   -Force
Import-Module (Join-Path $LibDir "State.psm1") -Force
Import-Module (Join-Path $LibDir "Guard.psm1") -Force

# ---------------------------------------------------------------------------
# Log initialisation
# ---------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Path "$env:ProgramData\Baraka" -Force
Initialize-Log -Path "$env:ProgramData\Baraka\deploy.log"

# ---------------------------------------------------------------------------
# Step dispatch
# ---------------------------------------------------------------------------
try {
    Invoke-Step -StepName "Preflight" -Body {
        . (Join-Path $PSScriptRoot "steps\01-preflight.ps1")
    }

    # Future steps added here by later phases

    Write-Log -Level "INFO" -Message "Deployment complete"
    exit $EXIT_SUCCESS
} catch {
    Write-Log -Level "ERROR" -Message "Step failure: $($_.Exception.Message)"
    exit $EXIT_STEP_FAILED
}
