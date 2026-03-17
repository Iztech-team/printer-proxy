# Architecture Patterns

**Domain:** Windows POS deployment automation (WSA + ADB + Python print server)
**Researched:** 2026-03-17

---

## Recommended Architecture

A single entry-point PowerShell script that delegates to discrete, self-contained step modules.
Each step owns one responsibility, reports a structured result, and is guarded by an idempotency
check so re-running the full script is always safe.

```
deploy.ps1 (entry point)
  │
  ├── lib/
  │   ├── State.psm1          # Registry-backed state machine
  │   ├── Log.psm1            # Structured timestamped logging
  │   └── Guard.psm1          # Idempotency check helpers
  │
  └── steps/
      ├── 01-preflight.ps1    # Privilege, OS, BIOS virt checks
      ├── 02-vm-features.ps1  # Enable VirtualMachinePlatform / HypervisorPlatform
      ├── 03-wsa-install.ps1  # MSIX package registration, no UI popups
      ├── 04-wsa-configure.ps1 # Developer Mode registry + WSA settings
      ├── 05-adb-connect.ps1  # ADB server start, device probe, retry loop
      ├── 06-apk-install.ps1  # adb install idempotent guard
      ├── 07-print-server.ps1 # Python venv, dependency install, scheduled task
      └── 08-verify.ps1       # End-to-end health check, final report
```

---

## Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| `deploy.ps1` | Arg parsing, phase routing, reboot orchestration | All steps via dot-source / call operator |
| `State.psm1` | Read/write current phase to HKLM registry key; detect post-reboot resume | Called by `deploy.ps1` and each step |
| `Log.psm1` | Timestamped, levelled (INFO/WARN/ERROR) append to `%ProgramData%\Baraka\deploy.log` | Called by every step |
| `Guard.psm1` | `Assert-NotAlreadyDone` checks a per-step registry flag before running | Called at the top of each step |
| Preflight step | Admin elevation check, OS version, CPU virtualisation flag in BIOS | State, Log |
| VM features step | `Enable-WindowsOptionalFeature` for `VirtualMachinePlatform` + `HypervisorPlatform`; sets reboot-needed flag | State, Log |
| WSA install step | MSIX package registration via `Add-AppxPackage`; suppresses interactive prompts | State, Log |
| WSA configure step | Registry path `HKCU:\Software\Microsoft\Windows\CurrentVersion\AppModel` developer mode; WSA startup settings | State, Log |
| ADB connect step | `adb start-server`, retry-loop `adb connect 127.0.0.1:58526`, exponential back-off | State, Log |
| APK install step | `adb install -r` with guard checking `adb shell pm list packages` | State, Log, ADB |
| Print server step | Python venv creation, `pip install`, Windows scheduled task registration | State, Log |
| Verify step | Smoke-tests: WSA running, ADB device listed, APK present, print server HTTP `/health` | Log |

---

## Data Flow

```
User runs: deploy.ps1

[deploy.ps1]
  Read State.psm1 → current_phase (registry key HKLM:\SOFTWARE\Baraka\Deploy\Phase)
  If phase == "" → first run; start from step 01
  If phase == "post-reboot-N" → resume from step N

  For each step N:
    Guard.psm1 → check HKLM:\SOFTWARE\Baraka\Deploy\Step-N-Done
    If done → skip (idempotency)
    If not done → execute step
      Step writes to Log.psm1 (append %ProgramData%\Baraka\deploy.log)
      Step sets State.psm1 → "running-N"
      Step completes → sets Guard flag "Step-N-Done" = 1
      If step requires reboot:
        State.psm1 → set Phase = "post-reboot-N+1"
        Register scheduled task: deploy.ps1 -Resume at system startup
        Initiate restart
        [SYSTEM REBOOTS]
        [Scheduled task fires deploy.ps1]
        deploy.ps1 reads Phase → "post-reboot-N+1" → jumps to step N+1
        After successful completion: Unregister scheduled task, clear Phase key

  Step 08-verify.ps1 → write final summary to deploy.log
  Exit 0 (success) or Exit 1 (failure with last error in log)
```

### Reboot-Resume Detail

The pattern (HIGH confidence — verified against official documentation and community implementations):

1. Before triggering a reboot, the script writes the next step index to a registry key.
2. It registers a `AtStartup` scheduled task pointing at `deploy.ps1 -Resume`.
3. On reboot, the task fires, `deploy.ps1` reads the registry key, and jumps to the correct step.
4. After the final step, the script removes the registry key and unregisters the task.
5. If the script is re-run manually on a machine where deployment already completed, every
   step's guard flag is set so execution is a no-op (idempotent).

Registry layout:
```
HKLM:\SOFTWARE\Baraka\Deploy\
  Phase          REG_SZ   "post-reboot-3"   (cleared on completion)
  Step-01-Done   REG_DWORD 1
  Step-02-Done   REG_DWORD 1
  ...
  Step-N-Done    REG_DWORD 1
```

---

## Patterns to Follow

### Pattern 1: Idempotency Guard
**What:** Every step begins by checking a registry flag. If already set, it returns immediately
with a "skipped" log line.
**When:** Always. Supports safe re-runs after partial failures without redoing completed work.
**Example:**
```powershell
function Invoke-Step {
    param([string]$StepName, [scriptblock]$Body)
    $key = "HKLM:\SOFTWARE\Baraka\Deploy\$StepName-Done"
    if (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue) {
        Write-Log "INFO" "$StepName already complete — skipping"
        return
    }
    & $Body
    New-ItemProperty -Path "HKLM:\SOFTWARE\Baraka\Deploy" -Name "$StepName-Done" -Value 1 -Force
}
```

### Pattern 2: Registry State Machine for Reboot Resume
**What:** Phase index written to registry before reboot; task scheduler resumes script post-boot.
**When:** Any step that calls `Enable-WindowsOptionalFeature` and receives `RestartNeeded = True`.
**Example:**
```powershell
function Request-RebootAndResume {
    param([int]$NextStep)
    Set-RegistryValue "Phase" "post-reboot-$NextStep"
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
                   -Argument "-NonInteractive -File `"$PSScriptRoot\deploy.ps1`" -Resume"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName "BarakaDeploy-Resume" -Action $action -Trigger $trigger -Force
    Restart-Computer -Force
}
```

### Pattern 3: ADB Retry Loop with Back-Off
**What:** `adb connect` is attempted in a loop with increasing wait between attempts.
WSA needs several seconds to start its ADB listener after the subsystem boots.
**When:** Step 05 (ADB connect) and any step issuing ADB commands.
**Example:**
```powershell
function Connect-Adb {
    param([string]$Endpoint = "127.0.0.1:58526", [int]$MaxRetries = 10)
    for ($i = 1; $i -le $MaxRetries; $i++) {
        $result = & adb connect $Endpoint 2>&1
        if ($result -match "connected") { return $true }
        Write-Log "WARN" "ADB attempt $i/$MaxRetries failed; waiting $($i * 2)s"
        Start-Sleep -Seconds ($i * 2)
    }
    throw "ADB connection failed after $MaxRetries attempts"
}
```

### Pattern 4: Structured Logging
**What:** All output goes through a single `Write-Log` function that prepends timestamp + level.
**When:** Always. Enables IT to diagnose failures from the log file without re-running.
**Example:**
```powershell
function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path "$env:ProgramData\Baraka\deploy.log" -Value $line
    Write-Host $line
}
```

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Monolithic Script
**What:** One 500-line script that does everything sequentially with no internal structure.
**Why bad:** A failure midway through leaves no clean resume point; re-running restarts everything,
causing double-registration of scheduled tasks and double-installs.
**Instead:** Use the step module pattern with per-step guard flags.

### Anti-Pattern 2: Hardcoded ADB Device Serial
**What:** Scripts that assume `emulator-5554` or a fixed serial for the WSA device.
**Why bad:** WSA assigns a transport ID that changes across reboots and WSA versions.
**Instead:** Detect the WSA ADB endpoint dynamically by reading
`HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\AppModel\StateChange\PackageList\*WSA*`
or by probing `adb devices` output for the known WSA port (58526).

### Anti-Pattern 3: Interactive Prompts During Installation
**What:** Relying on UI pop-ups (WSA installer dialogs, UAC prompts at mid-script).
**Why bad:** Kills zero-intervention requirement; deployments hang on unattended terminals.
**Instead:** Request admin elevation at script entry via `#Requires -RunAsAdministrator`; use
`Add-AppxPackage` flags that suppress UI; pre-accept EULAs via registry where applicable.

### Anti-Pattern 4: Global Variables for State
**What:** Using `$global:Phase` or `$env:DEPLOY_PHASE` to track state.
**Why bad:** State is lost on reboot; environment variables do not survive across scheduled task
invocations reliably.
**Instead:** Registry keys (HKLM) survive reboots, can be inspected externally, and are
accessible to any process running as SYSTEM or administrator.

### Anti-Pattern 5: Fire-and-Forget Scheduled Task Cleanup
**What:** Registering the resume task but never unregistering it.
**Why bad:** Task accumulates across failed runs; on the next boot the task fires unexpectedly.
**Instead:** Unconditionally call `Unregister-ScheduledTask -TaskName "BarakaDeploy-Resume" -Confirm:$false`
in a `finally` block at the end of `deploy.ps1`.

---

## Suggested Build Order

This order is driven by hard dependencies: later steps cannot succeed unless earlier steps are complete.

| Order | Step | Dependency | Notes |
|-------|------|------------|-------|
| 1 | State + Log + Guard libraries | None | Must exist before anything else runs |
| 2 | Preflight checks | Libraries | Fail fast before making system changes |
| 3 | VM feature enablement + reboot-resume | Preflight | VirtualMachinePlatform required by WSA |
| 4 | WSA install | VM features, post-reboot | MSIX package registration |
| 5 | WSA Developer Mode configuration | WSA installed | Registry write; must be before ADB |
| 6 | ADB connection with retry | WSA configured and running | WSA must be started to expose ADB port |
| 7 | APK install | ADB connected | Requires active ADB session |
| 8 | Print server setup | None (independent) | Can run in parallel with steps 4-7 if desired |
| 9 | CORS hardening | Print server running | Edits server config; requires server to exist |
| 10 | End-to-end verification | All above | Smoke test; no system changes |

The critical path is: **Libraries → Preflight → VM Features → [reboot] → WSA Install → WSA Configure → ADB → APK → Verify.**
Print server setup and CORS hardening are independent of the WSA/ADB path and can be tackled
in a separate phase or interleaved after WSA install completes.

---

## Scalability Considerations

This is a sub-10 terminal fleet so scalability is not a primary concern, but the structure
should not create future friction.

| Concern | At current scale (<10 terminals) | If fleet grows |
|---------|----------------------------------|----------------|
| Script distribution | Copy to USB / network share | Wrap as self-extracting exe or Chocolatey package |
| State visibility | Log file on local disk | Redirect log to UNC share for centralised review |
| Parallel deployment | Sequential (one IT person, one terminal) | PSADT / Intune for parallel push |
| Secrets / config | None needed for this project | Inject via environment or encrypted .psd1 |

---

## Sources

- [Continuing PowerShell Scripts After Reboot (Advanced Installer)](https://www.advancedinstaller.com/continue-powershell-script-after-reboot.html) — HIGH confidence, detailed pattern walkthrough
- [PSAppDeployToolkit Deployment Structure](https://psappdeploytoolkit.com/docs/deployment-concepts/deployment-structure) — HIGH confidence, official docs, Pre/Main/Post phase model
- [Desired State Configuration Overview (Microsoft Learn)](https://learn.microsoft.com/en-us/powershell/dsc/overview/DscForEngineers?view=dsc-1.1) — HIGH confidence, idempotency definition
- [Enable-WindowsOptionalFeature / DISM for VirtualMachinePlatform (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/install-hyper-v) — HIGH confidence, official cmdlet reference
- [Crafting an Opinionated Logging and Error Handling Framework (Microsoft ISE Dev Blog)](https://devblogs.microsoft.com/ise/empowering-powershell-with-opinionated-best-practices-for-logging-and-error-handling/) — MEDIUM confidence, community best-practices article from Microsoft devs
- [ADB Wi-Fi Reconnect Guide (Android Developers)](https://developer.android.com/tools/adb) — HIGH confidence, official ADB documentation
- [MagiskOnWSALocal (GitHub)](https://github.com/LSPosed/MagiskOnWSALocal) — MEDIUM confidence, community reference for WSA package structure
