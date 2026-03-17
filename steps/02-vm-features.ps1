# steps/02-vm-features.ps1 — VM feature enablement with reboot orchestration
# Enables VirtualMachinePlatform and HypervisorPlatform on store terminals.
# Reserves port 58526 from Hyper-V before the mandatory reboot.
# Implements reboot-resume via scheduled task with HIGHEST run level.
# Dot-sourced by deploy.ps1 inside an Invoke-Step body.
#
# Requires: Write-Log (Log.psm1) and Set-DeployState (State.psm1) to be imported.

# ---------------------------------------------------------------------------
# Test-VmFeaturesEnabled (VMFT-02)
# Returns $true if both VM features are already enabled — triggers idempotency
# skip in Invoke-VmFeatures.
# ---------------------------------------------------------------------------
function Test-VmFeaturesEnabled {
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'
    $hvp = Get-WindowsOptionalFeature -Online -FeatureName 'HypervisorPlatform'
    return ($vmp.State -eq 'Enabled' -and $hvp.State -eq 'Enabled')
}

# ---------------------------------------------------------------------------
# Invoke-SystemReboot — Test seam wrapper around Restart-Computer.
# Exists so tests can mock this function without needing to mock the Restart-Computer
# cmdlet directly (which has cross-platform parameter-binding issues in Pester on Linux).
# ---------------------------------------------------------------------------
function Invoke-SystemReboot {
    Restart-Computer -Force
}

# ---------------------------------------------------------------------------
# Invoke-NetshPortReserve (BOOT-02)
# Wrapper around netsh port reservation — exists as a test seam so Pester can
# mock this function instead of the raw external process call.
# Reserves port 58526 from the Hyper-V dynamic port range.
# Must be called BEFORE the reboot that activates Hyper-V.
# ---------------------------------------------------------------------------
function Invoke-NetshPortReserve {
    $null = netsh int ipv4 add excludedportrange protocol=tcp startport=58526 numberofports=1
    Write-Log -Level "INFO" -Message "Port 58526 reserved from Hyper-V dynamic range"

    # Verify the reservation is visible in the exclusion list (WARN not ERROR per RESEARCH.md)
    $verify = netsh int ipv4 show excludedportrange protocol=tcp
    if ($verify -notmatch '58526') {
        Write-Log -Level "WARN" -Message "Port 58526 not confirmed in exclusion list -- possible system restriction or pre-existing exclusion"
    }
}

# ---------------------------------------------------------------------------
# Register-ResumeTask (BOOT-01)
# Registers a one-shot AtStartup scheduled task that re-invokes deploy.ps1
# with -ResumeAfterReboot at HIGHEST run level.
# Task name: BarakaDeploy-Resume
# ---------------------------------------------------------------------------
function Register-ResumeTask {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath
    )

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -ResumeAfterReboot"
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask -TaskName 'BarakaDeploy-Resume' `
        -Action $action -Trigger $trigger -Settings $settings `
        -RunLevel Highest -Force | Out-Null

    Write-Log -Level "INFO" -Message "Resume task registered (BarakaDeploy-Resume) at HIGHEST run level"
}

# ---------------------------------------------------------------------------
# Invoke-VmFeatures — Main orchestrator
# Checks idempotency first (VMFT-02), then:
#   1. Reserves port 58526 (BOOT-02)
#   2. Enables VirtualMachinePlatform and HypervisorPlatform (VMFT-01)
#   3. Conditionally reboots if RestartNeeded (VMFT-03)
#      - Registers resume task (BOOT-01)
#      - Saves checkpoint state (BOOT-03)
#      - Triggers Restart-Computer
# ---------------------------------------------------------------------------
function Invoke-VmFeatures {
    if (Test-VmFeaturesEnabled) {
        Write-Log -Level "INFO" -Message "VM features already enabled -- skipping enablement"
        return
    }

    # BOOT-02: Reserve port 58526 before Hyper-V activation
    Invoke-NetshPortReserve

    # VMFT-01: Enable both VM features silently (no auto-reboot)
    Write-Log -Level "INFO" -Message "Enabling VirtualMachinePlatform..."
    $vmpResult = Enable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -All -NoRestart

    Write-Log -Level "INFO" -Message "Enabling HypervisorPlatform..."
    $hvpResult = Enable-WindowsOptionalFeature -Online -FeatureName 'HypervisorPlatform' -All -NoRestart

    $restartNeeded = $vmpResult.RestartNeeded -or $hvpResult.RestartNeeded
    Write-Log -Level "INFO" -Message "VirtualMachinePlatform RestartNeeded: $($vmpResult.RestartNeeded)"
    Write-Log -Level "INFO" -Message "HypervisorPlatform RestartNeeded: $($hvpResult.RestartNeeded)"

    # VMFT-03: Only reboot when the OS indicates restart is required
    if ($restartNeeded) {
        # Determine the deploy.ps1 path from the step file's own location
        $deployScriptPath = Join-Path $PSScriptRoot '..' 'deploy.ps1'
        $deployScriptPath = [System.IO.Path]::GetFullPath($deployScriptPath)

        # BOOT-01: Register resume task with HIGHEST elevation
        Register-ResumeTask -ScriptPath $deployScriptPath

        # BOOT-03: Save checkpoint state to registry before reboot
        Set-DeployState -Name "ResumeStep" -Value "PostVmFeatures"
        Write-Log -Level "INFO" -Message "Checkpoint saved: will resume at PostVmFeatures after reboot"

        Write-Log -Level "INFO" -Message "Triggering system reboot to complete VM feature activation..."
        Invoke-SystemReboot
        # Script stops here; resumed by BarakaDeploy-Resume scheduled task after reboot
        return
    }

    Write-Log -Level "INFO" -Message "VM features enabled -- no restart required"
}

# ---------------------------------------------------------------------------
# Entry point: called when dot-sourced by deploy.ps1's Invoke-Step body.
# The guard prevents auto-execution when dot-sourced from unit tests.
# ---------------------------------------------------------------------------
if (-not $env:BARAKA_TEST_MODE) {
    Invoke-VmFeatures
}
