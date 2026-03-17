# steps/04-wsa-configure.ps1 — WSA developer mode configuration and ADB connection
# Enables developer mode via registry, sets VM to Continuous mode, and connects ADB.
# Implements exponential backoff retry with manual fallback on exhausted retries.
# Dot-sourced by deploy.ps1 inside an Invoke-Step body.
#
# Requirements: ADBM-01, ADBM-02, ADBM-03, ADBM-04, ADBM-05
# Requires: Write-Log (Log.psm1) to be imported before dot-sourcing.

# ---------------------------------------------------------------------------
# Invoke-Sleep — Test seam wrapper around Start-Sleep.
# Exists so tests can mock this function without mocking the built-in Start-Sleep.
# ---------------------------------------------------------------------------
function Invoke-Sleep {
    param(
        [int]$Seconds
    )
    Start-Sleep -Seconds $Seconds
}

# ---------------------------------------------------------------------------
# Invoke-AdbCommand — Test seam for ADB binary calls (ADBM-04).
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
# Set-WsaDeveloperMode (ADBM-01, ADBM-02)
# Writes DeveloperMode=1 to WindowsSubsystemForAndroid registry path and
# VMLifeCycleMode="Continuous" to WSA registry path.
# Creates each registry path if it does not exist.
# Calls Invoke-WsaRestart after writing keys to activate ADB daemon.
# ---------------------------------------------------------------------------
function Set-WsaDeveloperMode {
    $wsaPath = "HKCU:\Software\Microsoft\WindowsSubsystemForAndroid"
    $wsaVmPath = "HKCU:\Software\Microsoft\WSA"

    # ADBM-01: Write DeveloperMode=1 (DWord) to WindowsSubsystemForAndroid
    Write-Log -Level "INFO" -Message "Writing DeveloperMode=1 to $wsaPath"
    if (-not (Test-Path $wsaPath)) {
        New-Item -Path $wsaPath -ItemType Directory -Force | Out-Null
    }
    Set-ItemProperty -Path $wsaPath -Name "DeveloperMode" -Value 1

    # ADBM-02: Write VMLifeCycleMode="Continuous" (String) to WSA
    Write-Log -Level "INFO" -Message "Writing VMLifeCycleMode=Continuous to $wsaVmPath"
    if (-not (Test-Path $wsaVmPath)) {
        New-Item -Path $wsaVmPath -ItemType Directory -Force | Out-Null
    }
    Set-ItemProperty -Path $wsaVmPath -Name "VMLifeCycleMode" -Value "Continuous"

    Write-Log -Level "INFO" -Message "WSA registry keys written; restarting WSA to activate ADB daemon"

    # ADBM-01: Restart WSA to activate changes
    Invoke-WsaRestart
}

# ---------------------------------------------------------------------------
# Invoke-WsaRestart
# Kills WSA processes (WsaService, WsaClient, WsaSettings) and relaunches
# via WsaClient.exe /launch wsa://system.
# Waits 10s for ADB listener to start.
# ---------------------------------------------------------------------------
function Invoke-WsaRestart {
    Write-Log -Level "INFO" -Message "Stopping WSA processes..."

    # Kill each process; ignore errors if not running
    Stop-Process -Name "WsaService" -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "WsaClient"  -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "WsaSettings" -Force -ErrorAction SilentlyContinue

    Invoke-Sleep -Seconds 2

    # Find WsaClient.exe via AppxPackage install location
    $wsaPkg = Get-AppxPackage -Name "*WindowsSubsystemForAndroid*" -ErrorAction SilentlyContinue
    $wsaClientExe = "$($wsaPkg.InstallLocation)\WsaClient\WsaClient.exe"

    Write-Log -Level "INFO" -Message "Launching WSA via $wsaClientExe"
    Start-Process -FilePath $wsaClientExe -ArgumentList "/launch wsa://system" -ErrorAction SilentlyContinue

    # Wait for ADB listener to start inside WSA
    Write-Log -Level "INFO" -Message "Waiting 10s for WSA ADB daemon startup..."
    Invoke-Sleep -Seconds 10
}

# ---------------------------------------------------------------------------
# Connect-Adb (ADBM-03, ADBM-04, ADBM-05)
# Connects to WSA ADB endpoint with exponential backoff retry.
# Success is determined by parsing adb devices output — NOT exit codes.
# Returns $true on success, $false when all attempts are exhausted.
#
# Parameters:
#   AdbPath     — Path to adb.exe binary
#   Endpoint    — ADB endpoint (default: 127.0.0.1:58526)
#   MaxAttempts — Number of retry attempts (default: 5)
#   BaseDelaySec — Base delay in seconds for exponential backoff (default: 5)
# ---------------------------------------------------------------------------
function Connect-Adb {
    param(
        [string]$AdbPath,
        [string]$Endpoint = "127.0.0.1:58526",
        [int]$MaxAttempts = 5,
        [int]$BaseDelaySec = 5
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        # ADBM-04: Issue connect then check devices output (not exit codes)
        Invoke-AdbCommand -AdbPath $AdbPath -Arguments "connect $Endpoint" | Out-Null
        $devices = Invoke-AdbCommand -AdbPath $AdbPath -Arguments "devices"

        # ADBM-04: Success only when endpoint appears with 'device' status in output
        if ($devices -match ([regex]::Escape($Endpoint) + '\s+device')) {
            Write-Log -Level "INFO" -Message "ADB connected to $Endpoint (attempt $i/$MaxAttempts)"
            return $true
        }

        # Calculate exponential backoff delay, capped at 60s — only sleep when retries remain
        if ($i -lt $MaxAttempts) {
            $delaySec = [math]::Min($BaseDelaySec * [math]::Pow(2, $i - 1), 60)
            $delaySec = [int]$delaySec
            Write-Log -Level "WARN" -Message "ADB probe $i/$MaxAttempts failed; waiting ${delaySec}s"
            Invoke-Sleep -Seconds $delaySec
        } else {
            Write-Log -Level "WARN" -Message "ADB probe $i/$MaxAttempts failed"
        }
    }

    # ADBM-05: All retries exhausted — emit manual fallback instructions
    Write-Log -Level "WARN" -Message "ADB connection failed after $MaxAttempts attempts."
    Write-Log -Level "WARN" -Message "MANUAL ACTION REQUIRED: Open WSA Settings on this terminal,"
    Write-Log -Level "WARN" -Message "click 'Developer' in the left sidebar, toggle 'Developer mode'"
    Write-Log -Level "WARN" -Message "to ON, then re-run deploy.ps1. All other steps will be skipped."

    return $false
}

# ---------------------------------------------------------------------------
# Invoke-WsaConfigure — Main orchestrator (ADBM-01 through ADBM-05)
# Enables developer mode, sets Continuous VM mode, connects ADB.
# Throws when ADB connection fails — this prevents Guard.psm1 from setting
# the done flag, allowing re-run on next deploy attempt (ADBM-05).
# ---------------------------------------------------------------------------
function Invoke-WsaConfigure {
    param(
        [string]$AdbPath = (Join-Path $PSScriptRoot '..\adb\adb.exe')
    )

    Set-WsaDeveloperMode

    $connected = Connect-Adb -AdbPath $AdbPath
    if (-not $connected) {
        throw "ADB connection failed after all retry attempts. Manual developer mode toggle required."
    }

    Write-Log -Level "INFO" -Message "WSA configured: developer mode ON, ADB connected"
}

# ---------------------------------------------------------------------------
# Entry point: called when dot-sourced by deploy.ps1's Invoke-Step body.
# The guard prevents auto-execution when dot-sourced from unit tests.
# ---------------------------------------------------------------------------
if (-not $env:BARAKA_TEST_MODE) {
    Invoke-WsaConfigure
}
