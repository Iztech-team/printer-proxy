# steps/03-wsa-install.ps1 — WSA installation step with idempotency and window suppression
# Installs Windows Subsystem for Android from local MagiskOnWSALocal bundle.
# Suppresses auto-launched windows after install, then polls for WsaService init.
# Dot-sourced by deploy.ps1 inside an Invoke-Step body.
#
# Requirements implemented:
#   WSAI-01: Silent install via Add-AppxPackage -Register with ForceApplicationShutdown
#   WSAI-02: Kill WsaSettings and WsaClient windows 15s post-install (not WsaService)
#   WSAI-03: Poll for WsaService process up to 45s to confirm initialization
#   WSAI-04: Skip install when WSA package already present (idempotent)
#
# Requires: Write-Log (Log.psm1) to be imported in caller session.

# ---------------------------------------------------------------------------
# Test-WsaInstalled (WSAI-04)
# Returns $true if WSA package is already registered — triggers idempotency
# skip in Invoke-WsaInstall.
# ---------------------------------------------------------------------------
function Test-WsaInstalled {
    return ($null -ne (Get-AppxPackage -Name "*WindowsSubsystemForAndroid*" -ErrorAction SilentlyContinue))
}

# ---------------------------------------------------------------------------
# Invoke-AddAppxPackage — Test seam (WSAI-01)
# Wraps Add-AppxPackage -Register so Pester can mock this function instead of
# the raw cmdlet, avoiding cross-platform parameter-binding issues on Linux.
# ---------------------------------------------------------------------------
function Invoke-AddAppxPackage {
    param([Parameter(Mandatory)][string]$ManifestPath)
    Add-AppxPackage -Register $ManifestPath -ForceApplicationShutdown -ForceUpdateFromAnyVersion
}

# ---------------------------------------------------------------------------
# Stop-WsaWindows (WSAI-02)
# Kills WsaSettings and WsaClient UI processes that auto-launch after install.
# CRITICAL: WsaService is NOT stopped — that is the VM itself and must stay up.
# ---------------------------------------------------------------------------
function Stop-WsaWindows {
    @("WsaSettings", "WsaClient") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Invoke-Sleep — Test seam wrapping Start-Sleep
# Exists so Pester can mock sleep calls without actually waiting.
# ---------------------------------------------------------------------------
function Invoke-Sleep {
    param([int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

# ---------------------------------------------------------------------------
# Invoke-WsaServiceWait — Test seam for poll-based init wait (WSAI-03)
# Polls for WsaService process up to TimeoutSeconds with IntervalSeconds intervals.
# Emits WARN (not exception) if service does not appear — WSA may still initialize.
# ---------------------------------------------------------------------------
function Invoke-WsaServiceWait {
    param(
        [int]$TimeoutSeconds  = 45,
        [int]$IntervalSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name "WsaService" -ErrorAction SilentlyContinue) {
            Write-Log -Level "INFO" -Message "WsaService detected -- WSA initialization complete"
            return $true
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    Write-Log -Level "WARN" -Message "WsaService not detected within ${TimeoutSeconds}s -- WSA may still initialize"
    return $false
}

# ---------------------------------------------------------------------------
# Invoke-WsaInstall — Main orchestrator
# Checks idempotency first (WSAI-04), then:
#   1. Silent install via Add-AppxPackage -Register (WSAI-01)
#   2. Waits 15s then kills auto-launched windows (WSAI-02)
#   3. Polls for WsaService to confirm initialization (WSAI-03)
# ---------------------------------------------------------------------------
function Invoke-WsaInstall {
    param(
        [string]$WsaRoot = (Join-Path $PSScriptRoot '..\WSA_2311.40000.4.0_x64_Release-Nightly-MindTheGapps-13.0\WSA_2311.40000.4.0_x64')
    )

    # WSAI-04: Skip if already installed
    if (Test-WsaInstalled) {
        Write-Log -Level "INFO" -Message "WSA already installed -- skipping"
        return
    }

    $manifestPath = Join-Path ([System.IO.Path]::GetFullPath($WsaRoot)) "AppxManifest.xml"
    Write-Log -Level "INFO" -Message "Installing WSA from $manifestPath"

    # WSAI-01: Silent install via register
    Invoke-AddAppxPackage -ManifestPath $manifestPath

    # WSAI-02: Wait 15s for first-boot initialization before killing windows
    Invoke-Sleep -Seconds 15
    Stop-WsaWindows

    # WSAI-03: Poll for WsaService to confirm initialization
    Invoke-WsaServiceWait
}

# ---------------------------------------------------------------------------
# Entry point: called when dot-sourced by deploy.ps1's Invoke-Step body.
# The guard prevents auto-execution when dot-sourced from unit tests.
# ---------------------------------------------------------------------------
if (-not $env:BARAKA_TEST_MODE) {
    Invoke-WsaInstall
}
