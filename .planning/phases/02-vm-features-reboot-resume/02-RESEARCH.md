# Phase 2: VM Features + Reboot Resume - Research

**Researched:** 2026-03-17
**Domain:** Windows Optional Feature management (DISM), Hyper-V port reservation (netsh), and scheduled-task reboot-resume for PowerShell deployment scripts
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| BOOT-01 | Reboot-resume uses a scheduled task at HIGHEST run level (not RunOnce) | Documented in project PITFALLS.md (Pitfall 6); official PowerShell Task Scheduler cmdlets confirmed; `-RunLevel Highest` is a named parameter on `Register-ScheduledTask`. HIGH confidence. |
| BOOT-02 | Port 58526 is reserved via `netsh` before the Hyper-V reboot | Documented in project PITFALLS.md (Pitfall 2) and STACK.md. `netsh int ipv4 add excludedportrange protocol=tcp startport=58526 numberofports=1` is the exact command. Must run before `Restart-Computer`. HIGH confidence. |
| BOOT-03 | Checkpoint state is saved to JSON before reboot for clean resume | `Set-DeployState` (State.psm1) can persist the next-step token to HKLM. The existing registry state machine is the correct mechanism — no separate JSON file is needed. HIGH confidence. |
| BOOT-04 | Scheduled task self-deletes after successful resume | `Unregister-ScheduledTask -TaskName 'BarakaDeploy-Resume' -Confirm:$false` in a `finally` block at the deploy.ps1 level. Pattern confirmed in ARCHITECTURE.md Anti-Pattern 5. HIGH confidence. |
| VMFT-01 | Script enables VirtualMachinePlatform and HypervisorPlatform silently | `Enable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -All -NoRestart` and same for `HypervisorPlatform`. `-NoRestart` suppresses automatic reboot so the script controls timing. HIGH confidence. |
| VMFT-02 | Script detects if features are already enabled and skips if so | `(Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform').State -eq 'Enabled'` returns the current state without enabling anything. If both features are already `Enabled`, skip enablement entirely and do not register the resume task or reboot. HIGH confidence. |
| VMFT-03 | Script triggers reboot only when `RestartNeeded` is true | `Enable-WindowsOptionalFeature` returns an object with a `.RestartNeeded` boolean property. Only call `Request-RebootAndResume` when at least one feature returned `RestartNeeded = $true`. HIGH confidence. |
</phase_requirements>

---

## Summary

Phase 2 is the deployment blocker: VirtualMachinePlatform must be enabled and a reboot completed before WSA can be installed or even started in later phases. The good news is this is the most thoroughly documented part of the entire project — DISM cmdlets, `netsh` port reservation, and PowerShell scheduled-task APIs are all officially documented and HIGH confidence. No experimental patterns are required.

The phase has a conditional execution path that makes idempotency non-trivial. If both features are already enabled (a re-run on a terminal that previously completed Phase 2), the step must skip enablement, skip port reservation, skip resume-task registration, and skip the reboot entirely — without blocking subsequent steps. If features need enabling, the sequence is: reserve port 58526, enable features with `-NoRestart`, check `.RestartNeeded`, register the resume task, save state, then reboot. After the reboot, the scheduled task fires deploy.ps1 with `-ResumeAfterReboot`, the resume task self-deletes, and the next step runs.

Two critical pitfalls dominate this phase. First, reboot-resume via RunOnce loses elevation (Pitfall 6 from project research) — a scheduled task with `-RunLevel Highest` is the correct mechanism and must be used instead. Second, port 58526 must be explicitly reserved via `netsh` before Hyper-V activates (Pitfall 2 from project research) — if this step is omitted, Hyper-V may claim the port on every subsequent boot, causing ADB failures that are very hard to diagnose.

The existing Phase 1 deliverables (State.psm1, Guard.psm1, Log.psm1, deploy.ps1) provide everything this phase needs. Phase 2 adds one step file (`steps/02-vm-features.ps1`) and extends `deploy.ps1` with `-ResumeAfterReboot` parameter handling and scheduled-task lifecycle management.

**Primary recommendation:** Implement `steps/02-vm-features.ps1` with a `Test-VmFeaturesEnabled` check first — skip the entire body if both features are `Enabled`. When enablement is needed, reserve the port, enable features, conditionally reboot via a registered scheduled task. All resume-task cleanup belongs in `deploy.ps1`'s `finally` block, not inside the step file.

---

## Standard Stack

### Core

| Technology | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| `Enable-WindowsOptionalFeature` | DISM module (built-in PS 5.1) | Enable VirtualMachinePlatform and HypervisorPlatform | Official Microsoft cmdlet; returns structured object with `.RestartNeeded`; `-NoRestart` flag suppresses automatic reboot so script controls timing |
| `Get-WindowsOptionalFeature` | DISM module (built-in PS 5.1) | Check current feature state before enabling | Returns `.State` property (`Enabled`, `Disabled`, `DisablePending`); used for VMFT-02 skip logic |
| `Register-ScheduledTask` | ScheduledTasks module (built-in PS 5.1) | Register reboot-resume task with HIGHEST run level | PowerShell-native API; `-RunLevel Highest` guarantees elevation post-reboot; `-Trigger AtStartup` fires before logon |
| `Unregister-ScheduledTask` | ScheduledTasks module (built-in PS 5.1) | Self-delete resume task after successful resume | Called in `finally` block; `-Confirm:$false` suppresses interactive prompt |
| `netsh int ipv4 add excludedportrange` | netsh (built-in Windows) | Reserve port 58526 before Hyper-V claims it | Only mechanism to pre-reserve ports from Hyper-V dynamic range; must run before reboot |
| `Restart-Computer -Force` | Built-in PS cmdlet | Trigger reboot after state is saved | `-Force` dismisses any open-dialog warnings; no interactive prompt |
| `Set-DeployState` / `Get-DeployState` | State.psm1 (Phase 1) | Persist resume step token to registry | Survives reboot; HKLM persists across sessions; existing Phase 1 module handles this |

### Supporting

| Technology | Purpose | When to Use |
|-----------|---------|-------------|
| `New-ScheduledTaskAction` | Build the action object for `Register-ScheduledTask` | Always — required parameter |
| `New-ScheduledTaskTrigger -AtStartup` | Fire task at system startup (before logon) | Always — ensures resume fires even on auto-logon terminals |
| `New-ScheduledTaskSettingsSet` | Set execution time limit | Set to 30 minutes to prevent orphaned tasks if deploy hangs |
| `netsh int ipv4 show excludedportrange` | Verify port 58526 is reserved post-reboot | In the step's post-reboot verification path (success criterion 3) |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Scheduled task (HIGHEST) | `HKCU:\...\RunOnce` | RunOnce loses elevation on standard-user auto-logon terminals — this is the documented cause of the existing `windows_setup.ps1` failure (Pitfall 6). Never use RunOnce. |
| `Enable-WindowsOptionalFeature` | `dism.exe /online /enable-feature` CLI | CLI returns a string that requires parsing to detect restart need; PowerShell cmdlet returns typed object with `.RestartNeeded` boolean |
| Registry state (State.psm1) | Flat checkpoint file (e.g., state.json) | Registry survives reboots more reliably than files on some configurations; State.psm1 already exists and is tested |

**Installation:** No new packages. All cmdlets are built-in to Windows PowerShell 5.1.

---

## Architecture Patterns

### Step File Structure

```
steps/
  01-preflight.ps1    # Phase 1 (exists)
  02-vm-features.ps1  # Phase 2 (this phase)
```

`deploy.ps1` gains:
- `-ResumeAfterReboot` switch parameter
- Resume-task registration helper function
- `finally` block unconditionally calling `Unregister-ScheduledTask`

### Pattern 1: Feature-State-Then-Act (VMFT-02)

**What:** Check current feature state before attempting enablement. If both features are already `Enabled`, log "already enabled — skipping" and return without touching port reservation, task registration, or the reboot path.

**When to use:** Always at the top of the vm-features step body — this is what makes the step correctly idempotent for re-runs on already-configured machines.

**Example:**
```powershell
# Source: Get-WindowsOptionalFeature - Microsoft Docs
function Test-VmFeaturesEnabled {
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'
    $hvp = Get-WindowsOptionalFeature -Online -FeatureName 'HypervisorPlatform'
    return ($vmp.State -eq 'Enabled' -and $hvp.State -eq 'Enabled')
}
```

### Pattern 2: Port Reservation Before Reboot (BOOT-02 / Pitfall 2)

**What:** Run `netsh int ipv4 add excludedportrange` before calling `Restart-Computer`. This is a one-time operation — if the exclusion already exists, `netsh` exits cleanly (exit code 0).

**When to use:** In the vm-features step, immediately after determining that features need enabling and before `Restart-Computer`.

**Example:**
```powershell
# Source: netsh documentation + PITFALLS.md Pitfall 2
# Must run BEFORE the reboot that activates Hyper-V
$netshResult = netsh int ipv4 add excludedportrange protocol=tcp startport=58526 numberofports=1
Write-Log -Level "INFO" -Message "Port 58526 reserved: $netshResult"
# Verify
$verify = netsh int ipv4 show excludedportrange protocol=tcp
if ($verify -notmatch '58526') {
    Write-Log -Level "WARN" -Message "Port 58526 not confirmed in exclusion list — possible system restriction"
}
```

### Pattern 3: Reboot-Resume via Scheduled Task (BOOT-01, BOOT-04)

**What:** Before calling `Restart-Computer`, register a one-shot `AtStartup` scheduled task that re-invokes `deploy.ps1 -ResumeAfterReboot` at HIGHEST run level. After successful resume, the task self-deletes from a `finally` block in `deploy.ps1`.

**When to use:** Only when `Enable-WindowsOptionalFeature` returns `.RestartNeeded = $true`.

**Example:**
```powershell
# Source: Register-ScheduledTask - Microsoft Docs + ARCHITECTURE.md Pattern 2
function Register-ResumeTask {
    param([string]$ScriptPath)
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -ResumeAfterReboot"
    $trigger  = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName 'BarakaDeploy-Resume' `
        -Action $action -Trigger $trigger -Settings $settings `
        -RunLevel Highest -Force | Out-Null
    Write-Log -Level "INFO" -Message "Resume task registered (BarakaDeploy-Resume)"
}
```

In `deploy.ps1`'s finally block:
```powershell
finally {
    # BOOT-04: always attempt task cleanup regardless of success/failure
    Unregister-ScheduledTask -TaskName 'BarakaDeploy-Resume' -Confirm:$false -ErrorAction SilentlyContinue
}
```

### Pattern 4: State Checkpoint Before Reboot (BOOT-03)

**What:** Before calling `Restart-Computer`, write the resume step token to the registry via `Set-DeployState`. On next run, `deploy.ps1` reads this token and jumps to the correct step.

**When to use:** Immediately after `Register-ResumeTask` and before `Restart-Computer`.

**Example:**
```powershell
# Source: State.psm1 (Phase 1) + ARCHITECTURE.md Pattern 2
Set-DeployState -Name "ResumeStep" -Value "VmFeatures-PostReboot"
Write-Log -Level "INFO" -Message "Checkpoint saved: will resume at VmFeatures-PostReboot after reboot"
Restart-Computer -Force
```

### Pattern 5: Full Conditional Execution Flow

```
Invoke-Step "VmFeatures" {
    if (Test-VmFeaturesEnabled) {
        Write-Log "INFO" "VM features already enabled -- skipping reboot"
        # Reserve port anyway if not already reserved (idempotent)
        return
    }

    Reserve-Port58526           # netsh add excludedportrange (BOOT-02)
    Enable-VmFeatures           # Enable-WindowsOptionalFeature x2 (VMFT-01)

    if ($restartNeeded) {       # VMFT-03: only reboot when needed
        Register-ResumeTask     # BOOT-01: scheduled task at HIGHEST
        Set-DeployState "ResumeStep" "VmFeatures-PostReboot"  # BOOT-03
        Restart-Computer -Force
        # Script stops here; resumed by scheduled task after reboot
    }
}

# Post-reboot path (deploy.ps1 -ResumeAfterReboot):
# finally block runs Unregister-ScheduledTask (BOOT-04)
# State.psm1 reads ResumeStep = "VmFeatures-PostReboot" and continues from here
```

### Recommended Project Structure After Phase 2

```
deploy.ps1              # Extended with -ResumeAfterReboot, finally cleanup
lib/
  Log.psm1              # Phase 1 (unchanged)
  State.psm1            # Phase 1 (unchanged)
  Guard.psm1            # Phase 1 (unchanged)
steps/
  01-preflight.ps1      # Phase 1 (unchanged)
  02-vm-features.ps1    # Phase 2 (new)
tests/
  Guard.Tests.ps1       # Phase 1
  Log.Tests.ps1         # Phase 1
  State.Tests.ps1       # Phase 1
  Preflight.Tests.ps1   # Phase 1
  VmFeatures.Tests.ps1  # Phase 2 (new)
```

### Anti-Patterns to Avoid

- **RunOnce for resume:** Loses elevation on standard-user auto-logon terminals. Never use `HKCU:\...\RunOnce` for this. The existing `windows_setup.ps1` makes this mistake.
- **Reboot without task registration:** Never call `Restart-Computer` before `Register-ResumeTask`. A reboot without a registered task leaves the deployment permanently halted.
- **Task registration in the step file:** The resume task self-delete belongs in `deploy.ps1`'s `finally` block, not in the step file. This ensures cleanup fires on success, on failure, and after any subsequent re-run.
- **Hardcoded script path in task action:** Use `$PSCommandPath` (the running script's own path) to set the task's `-File` argument, not a hardcoded path. Terminals may have the deployment bundle in different locations.
- **Calling Restart-Computer inside Invoke-Step body:** `Invoke-Step` sets the guard flag only after the body returns. If `Restart-Computer` is inside the body, the flag is never set and the step will re-run on resume. Solution: set the guard flag for the pre-reboot portion explicitly before calling `Restart-Computer`, or split into two named sub-steps.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Feature state detection | Custom registry parse of DISM output | `Get-WindowsOptionalFeature -Online` | Returns typed `.State` property; DISM registry layout is internal and undocumented |
| Port reservation | Custom socket binding or firewall rule | `netsh int ipv4 add excludedportrange` | Only supported mechanism for pre-reserving ports from Hyper-V dynamic range |
| Reboot with resume | RunOnce entry, env var, temp file | `Register-ScheduledTask -RunLevel Highest` | Only mechanism that preserves elevation across reboots reliably |
| Task self-delete | Separate cleanup script | `Unregister-ScheduledTask` in `finally` block | `finally` runs on all exit paths including exceptions; separate script adds complexity and another failure surface |

**Key insight:** The Windows scheduled task API with `-RunLevel Highest` is the only supported mechanism for resuming a script post-reboot with administrator privileges intact. Everything else (RunOnce, RunOnce with self-elevate, environment variables, temp files) has documented failure modes in the Baraka project research.

---

## Common Pitfalls

### Pitfall 1: Reboot Without Registered Resume Task (Critical)

**What goes wrong:** `Restart-Computer` fires, machine reboots, deployment stops permanently. No task is registered to resume it.

**Why it happens:** Exception thrown between `Register-ResumeTask` and `Restart-Computer`; or developer writes reboot logic in the wrong order.

**How to avoid:** Order is strictly: (1) reserve port, (2) enable features, (3) register task, (4) save state, (5) reboot. Never re-order steps 3-5. If any step before (3) fails, the exception propagates up and `Restart-Computer` is never reached — safe.

**Warning signs:** Machine reboots and no BarakaDeploy-Resume task is present in Task Scheduler.

### Pitfall 2: RunOnce Loses Elevation (Critical — Pitfall 6 from project research)

**What goes wrong:** The resumed script runs without admin rights on standard-user auto-logon terminals. All subsequent steps silently fail or get access-denied errors.

**Why it happens:** RunOnce starts in the user's session context, not an elevated context. The original script ran elevated, but RunOnce does not preserve that.

**How to avoid:** Use `Register-ScheduledTask` with `-RunLevel Highest`. Do not use RunOnce. Do not use the registry `Run` key either — same problem.

**Warning signs:** Script after resume writes "Admin check passed" but registry writes and feature queries fail with access denied.

### Pitfall 3: Hyper-V Claims Port 58526 (Critical — Pitfall 2 from project research)

**What goes wrong:** After the VirtualMachinePlatform reboot, Hyper-V dynamically reserves a port range that includes 58526. ADB connection in Phase 3 fails with "connection actively refused" even with developer mode correctly configured.

**Why it happens:** Hyper-V reserves port ranges at boot. The exclusion list is dynamic and changes between reboots. Port 58526 falls inside a Hyper-V range frequently enough to cause intermittent production failures.

**How to avoid:** Run `netsh int ipv4 add excludedportrange protocol=tcp startport=58526 numberofports=1` BEFORE the reboot. This is idempotent — running it again on a machine where the exclusion already exists exits with code 0 and does nothing.

**Warning signs:** `netsh int ipv4 show excludedportrange protocol=tcp` shows a system-reserved range containing 58526. ADB fails on this terminal after every reboot.

### Pitfall 4: Invoke-Step Guard Set Too Late (Moderate)

**What goes wrong:** If `Restart-Computer` is called inside an `Invoke-Step` body, the body never returns, so `Invoke-Step` never sets the `VmFeatures-Done` guard flag. On the post-reboot resume run, `Invoke-Step` re-executes the body. If features are already enabled, `Enable-WindowsOptionalFeature` is a no-op (safe), but `netsh` and task registration run again unnecessarily. More dangerously, if the "already enabled" check passes but the code still reaches `Restart-Computer`, the machine reboots in a loop.

**How to avoid:** The step's `Test-VmFeaturesEnabled` check at the top of the body must short-circuit correctly for the post-reboot case. After a successful reboot and resume, both features will report `Enabled` — so the body returns immediately without reaching the reboot path. Verify this logic path explicitly with a test.

**Warning signs:** Machine reboots twice during deployment.

### Pitfall 5: Task Action Path Quoting

**What goes wrong:** The `-Argument` string passed to `New-ScheduledTaskAction` uses backtick-escaped quotes around `$ScriptPath`. If `$ScriptPath` contains spaces (e.g., `C:\Users\IT Admin\baraka-deploy\deploy.ps1`), the task action fails to parse the argument string.

**How to avoid:** Always wrap the script path in escaped double-quotes in the argument string: `` -Argument "-NonInteractive -File `"$ScriptPath`"" ``. Test with a path containing spaces in the test suite.

---

## Code Examples

Verified patterns from official sources and project research:

### Feature State Check (VMFT-02)
```powershell
# Source: Get-WindowsOptionalFeature - Microsoft Docs (DISM module)
function Test-VmFeaturesEnabled {
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform'
    $hvp = Get-WindowsOptionalFeature -Online -FeatureName 'HypervisorPlatform'
    return ($vmp.State -eq 'Enabled' -and $hvp.State -eq 'Enabled')
}
```

### Silent Feature Enable with RestartNeeded Detection (VMFT-01, VMFT-03)
```powershell
# Source: Enable-WindowsOptionalFeature - Microsoft Docs + STACK.md
$vmpResult = Enable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -All -NoRestart
$hvpResult = Enable-WindowsOptionalFeature -Online -FeatureName 'HypervisorPlatform'      -All -NoRestart
$restartNeeded = $vmpResult.RestartNeeded -or $hvpResult.RestartNeeded
Write-Log -Level "INFO" -Message "VirtualMachinePlatform enabled. RestartNeeded: $($vmpResult.RestartNeeded)"
Write-Log -Level "INFO" -Message "HypervisorPlatform enabled.      RestartNeeded: $($hvpResult.RestartNeeded)"
```

### Port Reservation (BOOT-02)
```powershell
# Source: netsh documentation + PITFALLS.md Pitfall 2
# This is idempotent — safe to run even if the exclusion already exists
$null = netsh int ipv4 add excludedportrange protocol=tcp startport=58526 numberofports=1
Write-Log -Level "INFO" -Message "Port 58526 reserved from Hyper-V dynamic range"
```

### Resume Task Registration (BOOT-01)
```powershell
# Source: Register-ScheduledTask - Microsoft Docs + ARCHITECTURE.md
# $PSCommandPath is the path to the currently executing deploy.ps1
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ResumeAfterReboot"
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'BarakaDeploy-Resume' `
    -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest -Force | Out-Null
```

### Task Self-Delete (BOOT-04) in deploy.ps1 finally block
```powershell
# Source: Unregister-ScheduledTask - Microsoft Docs + ARCHITECTURE.md Anti-Pattern 5
# -ErrorAction SilentlyContinue: safe to call even if task was never registered
finally {
    Unregister-ScheduledTask -TaskName 'BarakaDeploy-Resume' `
        -Confirm:$false -ErrorAction SilentlyContinue
}
```

### deploy.ps1 -ResumeAfterReboot parameter handling
```powershell
# New parameter for deploy.ps1 (Phase 2 extension)
param(
    [switch]$ResumeAfterReboot
)
# ...
if ($ResumeAfterReboot) {
    $resumeStep = Get-DeployState -Name "ResumeStep"
    Write-Log -Level "INFO" -Message "Resuming after reboot at step: $resumeStep"
    # Route to correct step based on $resumeStep value
}
```

---

## State of the Art

| Old Approach (windows_setup.ps1) | Current Approach (Phase 2) | Impact |
|----------------------------------|---------------------------|--------|
| `HKCU:\...\RunOnce` for resume | `Register-ScheduledTask -RunLevel Highest` | Preserves elevation on auto-logon terminals |
| No port reservation | `netsh int ipv4 add excludedportrange` before reboot | Prevents Hyper-V from claiming port 58526 |
| No idempotency check | `Test-VmFeaturesEnabled` skips if already `Enabled` | Safe re-runs on partially configured terminals |
| Automatic reboot from DISM | `-NoRestart` flag + controlled `Restart-Computer` | Script controls reboot timing and state saving |

**Deprecated/outdated:**
- RunOnce: Never use for elevated resume — loses admin context
- `dism.exe /enable-feature` CLI: Use PowerShell cmdlet for structured return object

---

## Open Questions

1. **`-AtStartup` trigger fires before or after auto-logon?**
   - What we know: `AtStartup` triggers fire at system startup, before user logon. This is the correct behavior for an unattended terminal — the task runs elevated regardless of whether a user is logged in.
   - What's unclear: On terminals with auto-logon configured, does the task fire before or after the user session is established? `Add-AppxPackage` (Phase 3) requires a user session — but that is Phase 3's problem, not Phase 2's.
   - Recommendation: Proceed with `-AtStartup`. Phase 3 research should investigate whether WSA install needs `-AtLogon` instead of `-AtStartup`.

2. **`HypervisorPlatform` always required alongside `VirtualMachinePlatform`?**
   - What we know: Project STACK.md states both are needed "if VirtualMachinePlatform alone is insufficient on some hardware." On Windows 11 with modern CPUs, VirtualMachinePlatform alone is sufficient for WSA. On some Windows 10 builds with older firmware, HypervisorPlatform is required as a companion.
   - What's unclear: The exact hardware matrix.
   - Recommendation: Enable both unconditionally. `Enable-WindowsOptionalFeature` on an already-enabled feature is a no-op. Enabling both is always safe and avoids hardware-specific branching.

3. **netsh exit code when exclusion already exists?**
   - What we know: `netsh` exits with code 0 on success. When the exclusion already exists, informal testing (community reports) indicates it exits with 0 and prints a message indicating no change was made.
   - What's unclear: Whether it exits non-zero on "already exists" on all Windows builds.
   - Recommendation: Do not check `$LASTEXITCODE` for the `netsh add` call. Instead, verify by querying `netsh int ipv4 show excludedportrange` and checking for 58526 in the output. Log a WARN (not ERROR) if it doesn't appear — some environments restrict port reservation.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Pester 5.x |
| Config file | None — tests use `#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.0" }` |
| Quick run command | `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal` |
| Full suite command | `Invoke-Pester tests/ -Output Normal` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| VMFT-02 | When both features are already `Enabled`, step body returns without calling `Enable-WindowsOptionalFeature` | unit | `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal` | Wave 0 |
| VMFT-01 | `Enable-WindowsOptionalFeature` called for both feature names when not enabled | unit | `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal` | Wave 0 |
| VMFT-03 | Reboot path entered only when `.RestartNeeded` is true; skipped when false | unit | `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal` | Wave 0 |
| BOOT-01 | `Register-ScheduledTask` called with `-RunLevel Highest` | unit | `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal` | Wave 0 |
| BOOT-02 | `netsh int ipv4 add excludedportrange` called with startport=58526 before `Restart-Computer` | unit | `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal` | Wave 0 |
| BOOT-03 | `Set-DeployState "ResumeStep" ...` called before `Restart-Computer` | unit | `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal` | Wave 0 |
| BOOT-04 | `Unregister-ScheduledTask` called in `finally` block regardless of success/failure | unit | `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal` | Wave 0 |

**Notes on test approach:**

- `Enable-WindowsOptionalFeature` and `Get-WindowsOptionalFeature` require admin and a real Windows environment. Use Pester mocks (`Mock -ModuleName ...`) following the same pattern established in `Guard.Tests.ps1`.
- `Restart-Computer` must be mocked to prevent actual reboots during tests — this is non-negotiable.
- `netsh` is an external process called via `&` or direct invocation. Mock by wrapping it in a helper function (e.g., `Invoke-NetshPortReserve`) that tests can mock via Pester, similar to the test-seam pattern used in `01-preflight.ps1`.
- `Register-ScheduledTask` / `Unregister-ScheduledTask` should also be mocked; they require admin rights in production but not in unit tests when mocked at module scope.
- The reboot path cannot be tested end-to-end without a real reboot. Tests should verify that (a) state is saved, (b) task is registered, (c) `Restart-Computer` is called — stopping there. Integration validation on real hardware is the only way to verify the full resume flow.

### Sampling Rate

- **Per task commit:** `Invoke-Pester tests/VmFeatures.Tests.ps1 -Output Minimal`
- **Per wave merge:** `Invoke-Pester tests/ -Output Normal`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `tests/VmFeatures.Tests.ps1` — covers VMFT-01, VMFT-02, VMFT-03, BOOT-01, BOOT-02, BOOT-03, BOOT-04

*(Existing test infrastructure — Pester 5.x, lib mocking pattern — covers all other gaps. Only the new test file needs to be created.)*

---

## Sources

### Primary (HIGH confidence)

- [Enable-WindowsOptionalFeature — Microsoft Docs](https://learn.microsoft.com/en-us/powershell/module/dism/enable-windowsoptionalfeature) — RestartNeeded property, -NoRestart flag, -All flag
- [Get-WindowsOptionalFeature — Microsoft Docs](https://learn.microsoft.com/en-us/powershell/module/dism/get-windowsoptionalfeature) — .State property values
- [Register-ScheduledTask — Microsoft Docs](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask) — -RunLevel Highest parameter
- [Unregister-ScheduledTask — Microsoft Docs](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/unregister-scheduledtask) — -Confirm:$false pattern
- [Hyper-V Port Exclusion Ranges — microsoft/WSL Issue #5514](https://github.com/microsoft/WSL/issues/5514) — port 58526 Hyper-V steal behavior
- Project `.planning/research/PITFALLS.md` — Pitfall 2 (port theft), Pitfall 6 (RunOnce elevation loss)
- Project `.planning/research/STACK.md` — reboot-resume scheduled task pattern
- Project `.planning/research/ARCHITECTURE.md` — Pattern 2 (registry state machine), Anti-Pattern 5 (task cleanup)
- Phase 1 deliverables (State.psm1, Guard.psm1, Log.psm1) — direct code inspection confirming available APIs

### Secondary (MEDIUM confidence)

- [Continuing PowerShell Scripts After Reboot — Advanced Installer](https://www.advancedinstaller.com/continue-powershell-script-after-reboot.html) — checkpoint + scheduled task pattern walkthrough
- [Microsoft Intune PowerShell Best Practices](https://headsinthecloud.blog/2026/02/24/from-packaging-to-logic-powershell-as-the-new-win32-installer-in-intune/) — state check before transition pattern

### Tertiary (LOW confidence)

- Community reports on netsh exit code behavior when exclusion already exists — use output parsing instead of exit code checking

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — All cmdlets are official Microsoft PowerShell modules with current documentation
- Architecture: HIGH — Reboot-resume pattern confirmed in multiple independent sources; aligns with existing project architecture
- Pitfalls: HIGH — Pitfalls 2 and 6 from project research are directly applicable and well-evidenced; the two new pitfalls (guard timing, task argument quoting) are mechanically derived from the implementation approach
- Test approach: HIGH — Follows established Pester 5 patterns from Phase 1 test suite

**Research date:** 2026-03-17
**Valid until:** 2026-09-17 (stable Microsoft APIs; 6-month estimate)
