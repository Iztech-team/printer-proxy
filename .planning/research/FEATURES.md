# Feature Landscape

**Domain:** Windows unattended POS deployment automation (WSA + ADB + print server)
**Project:** Baraka deployment hardening
**Researched:** 2026-03-17
**Overall confidence:** HIGH (cross-referenced Microsoft Learn, PSAppDeployToolkit docs, community patterns)

---

## Table Stakes

Features that must be present for the deployment to be considered reliable. Absence of any of these means
the script is not fit for production IT use on real terminals.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Idempotent execution** | Running the script twice must not break a working terminal | Medium | Check current state before acting. Use Set-* semantics, not Add-*. Skip steps already satisfied. |
| **Structured logging with timestamps** | Unattended failures must be diagnosable after the fact | Low | Write to `C:\ProgramData\Baraka\Logs\deploy-<date>.log`. Include level, timestamp, step name, message. Use `Start-Transcript` as a safety net. |
| **Explicit exit codes** | Calling IT tooling (scheduled task, RMM agent) needs to detect success vs failure | Low | `exit 0` on full success, unique non-zero codes per failure category. Do not rely on implicit exit 0. |
| **Pre-flight prerequisite checks** | Fail fast before touching anything if the environment cannot support the deployment | Low | Check: OS edition (Pro/Enterprise), admin privilege, Hyper-V/VMP availability, disk space, ADB binary present. Print a clear diagnostic and exit early. |
| **Admin privilege self-detection** | Script must behave correctly whether launched by admin or standard user | Low | Use `[Security.Principal.WindowsIdentity]::GetCurrent()` check. Either auto-elevate via `Start-Process -Verb RunAs` or print a clear error and exit. |
| **Global error action enforcement** | A silent failure mid-script must not be treated as success | Low | Set `$ErrorActionPreference = "Stop"` at the top. Wrap all risky calls in try/catch. Never assume success from absence of output. |
| **Step-level error messages** | When a step fails, IT must know exactly which step and why | Low | Each catch block emits the step name, the exception message, and a remediation hint. No generic "deployment failed" messages. |
| **WSA installation state detection** | Avoid re-installing WSA if already installed and healthy | Medium | Check for existing MSIX package registration via `Get-AppxPackage`. Detect version mismatch. Skip or re-register only when needed. |
| **Windows Optional Features enablement** | VirtualMachinePlatform and other VM features must be enabled before WSA can start | Low | Use `Get-WindowsOptionalFeature` to check state before calling `Enable-WindowsOptionalFeature`. Both need admin. |
| **Reboot-resume after feature enablement** | Enabling VM features requires a reboot; deployment must continue after that reboot automatically | High | Registry-key checkpoint pattern: write current phase to `HKLM:\SOFTWARE\Baraka\DeployPhase` before scheduling reboot. On next boot, a scheduled task re-invokes the script; it reads the key and jumps to the post-reboot phase. Remove the key on clean completion. |
| **ADB connection with retry** | WSA's ADB endpoint is not instantly available after WSA starts; connection attempts will initially fail | Medium | Poll `adb connect 127.0.0.1:58526` with exponential backoff (e.g., 5 attempts, 2s / 4s / 8s / 16s / 32s waits). Log each attempt. Fail definitively after exhausting retries. |
| **ADB Developer Mode enablement** | WSA Developer Mode must be on for ADB to accept connections; currently requires manual UI toggle | High | Automate via registry write to WSA settings store (per-package `LocalState\settings.json`) then probe ADB to confirm. Do not require a human to click. |
| **APK installation idempotency** | If the correct APK version is already installed, do not reinstall | Medium | Use `adb shell pm list packages -f` or `adb shell dumpsys package <pkg>` to compare installed version before invoking `adb install`. |
| **Print server service registration** | The FastAPI print server must be registered as a Windows service or scheduled task that survives reboots | Low | Already exists per PROJECT.md; deployment must verify the task/service is present and in the correct state, not just assume it is. |
| **Post-deployment health verification** | After all steps complete, confirm the system is actually working | Medium | Test: WSA running, ADB connected, APK responding (package listed), print server HTTP endpoint reachable on localhost. Exit non-zero if any check fails even if install appeared to succeed. |

---

## Differentiators

Features that elevate the deployment from "functional" to "enterprise-grade." These are not required to unblock
the current deployment crisis but should be planned for the next hardening pass.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Dry-run / -WhatIf mode** | IT can validate what the script will do on a terminal without making changes | Medium | Pass `-WhatIf` flag; all mutating operations print "WOULD: ..." and skip. Useful for pre-deployment audits on unfamiliar hardware. PowerShell natively supports `$PSCmdlet.ShouldProcess()` for this. |
| **Rollback phase** | If health checks fail post-install, restore the previous working state | High | Before mutating WSA state, snapshot relevant config (WSA package state, service registrations, registry keys written). On failure, invoke a `Restore-PreviousState` function. True rollback requires knowing what "before" looked like; must capture it explicitly. |
| **Machine-readable deployment report** | Enables RMM or IT dashboard to ingest deployment results without log parsing | Low | Write a `deploy-result.json` to `C:\ProgramData\Baraka\` on completion with: timestamp, phases_completed[], phases_failed[], exit_code, adb_connected (bool), apk_version. |
| **Verbose / debug mode flag** | Easier troubleshooting when diagnosing a specific terminal | Low | `-Verbose` flag increases log verbosity; emits intermediate values, raw command output, registry reads. Separate from normal run so production logs stay clean. |
| **Configurable parameters via file or CLI** | Different terminals may need different APK paths or service ports without script edits | Low | Accept a `config.json` sidecar or named parameters for: APK path, ADB port, print server port, WSA package path. Fall back to embedded defaults. |
| **Deployment phase progress indicator** | IT running the script interactively can see where it is without reading log lines | Low | Write a `[Phase X/N] Description...` line to console at each phase boundary (distinct from log file output). |
| **Network printer discovery health check** | Confirm at least one printer is discoverable on the LAN before declaring deployment complete | Medium | Call the print server's `/printers` endpoint and verify non-empty response. Flag as warning (not fatal) if no printers found — printers may be offline. |
| **CORS configuration verification** | Confirm print server is not running with wildcard CORS before handing off | Low | Parse the print server config file or query its `/health` endpoint; assert `allow_origins` does not contain `*`. Exit with a warning if it does. |
| **Transcript archival to network share** | Central log collection for fleet-wide deployment audit | Medium | If a UNC path is available, copy the log file to `\\<share>\baraka-logs\<hostname>\<date>.log` after completion. Fail silently if share is unreachable. |

---

## Anti-Features

Things to deliberately not build. Each has a reason.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Interactive prompts during deployment** | Breaks unattended execution; IT cannot babysit each terminal | All input must be parameters or config file. Use `$env:` variables as fallback. Never `Read-Host`. |
| **Silent swallowing of errors** | `try { ... } catch {}` with no action creates phantom success | Every catch must log and either re-throw or set a failure flag. `$ErrorActionPreference = "Stop"` enforces this. |
| **Hardcoded absolute paths to moving targets** | APK path, WSA package path change between builds | Accept via parameter with a sensible default. Document expected layout in a `deploy.config.json`. |
| **GUI-dependent automation steps** | UI automation (clicking checkboxes, reading dialogs) is fragile across OS versions and screen resolutions | Use registry writes, AppX cmdlets, and PowerShell APIs instead. If a UI step is unavoidable, document it explicitly and fail-fast with a clear message rather than attempting unreliable click automation. |
| **Reboot without resume logic** | A blind `Restart-Computer` mid-script leaves the terminal half-deployed with no way to continue | Always set a checkpoint in the registry before any reboot and register a scheduled task to continue. Never reboot without a resume path. |
| **WSA UI window suppression hacks** | Attempting to `taskkill` or `Hide-Window` WSA popups is fragile and version-sensitive | Use AppX package install flags (`-ForceApplicationShutdown`) and installation sequencing to avoid windows appearing. Accept brief popups if unavoidable rather than fighting them. |
| **Version pinning to specific WSA build in script** | WSA build paths and internal structure vary; hardcoding breaks on different package versions | Pass WSA package path as a parameter. Script should work with any valid MagiskOnWSALocal build. |
| **Full CI/CD pipeline infrastructure** | This is a sub-10 terminal fleet deployed by IT on-site, not a cloud deployment | A single well-written PowerShell script is the right scope. No Jenkins, no Octopus Deploy, no agents to install. |
| **Canary / blue-green deployment** | Inapplicable to single Windows terminals; no traffic-shifting concept applies | A pre-deploy snapshot + rollback capability is the correct analogue for this use case. |

---

## Feature Dependencies

```
Pre-flight checks
    --> Admin privilege detection
    --> Windows edition check
    --> VM platform feature check

Windows Optional Features enablement
    --> Reboot-resume logic  (enablement requires reboot before WSA can be installed)

Reboot-resume logic
    --> Registry checkpoint write
    --> Scheduled task self-registration
    --> Checkpoint read on resume
    --> Scheduled task cleanup on completion

WSA installation (idempotent)
    --> WSA state detection  (skip if already healthy)

WSA Developer Mode enablement
    --> WSA installation  (must be installed before settings can be written)

ADB connection with retry
    --> WSA Developer Mode enabled
    --> WSA running (may need to start WSA process)

APK installation (idempotent)
    --> ADB connection established
    --> APK version detection  (skip if already at correct version)

Print server health check
    --> Print server service registered  (already exists)

Post-deployment health verification
    --> ADB connection
    --> APK installation
    --> Print server reachable

Rollback (differentiator)
    --> Pre-deployment state snapshot  (must be captured before any mutation)
    --> Post-deployment health check failing  (trigger condition)

Dry-run mode (differentiator)
    --> All table stakes features  (must shadow every mutating step)
```

---

## MVP Recommendation

For the current deployment crisis (unblocking this week), prioritize in order:

1. **Pre-flight checks** — fail fast and clearly; protects IT from partial-deploy confusion
2. **Windows Optional Features + reboot-resume** — this is the primary blocker
3. **WSA Developer Mode via registry** — eliminates the last manual UI step
4. **ADB connection with retry + exponential backoff** — eliminates the flaky reconnection issue
5. **Idempotent WSA install and APK install** — safe to re-run after any failure
6. **Structured logging + exit codes** — must have for unattended operation
7. **Post-deployment health verification** — confirms the terminal actually works before IT leaves

Defer to next hardening pass:
- **Rollback** — high complexity, not needed to unblock; a re-run of the idempotent script is the pragmatic substitute
- **Dry-run mode** — useful but not urgent
- **Machine-readable report / transcript archival** — useful for fleet management but not for sub-10 terminals this week
- **CORS verification** — important for security hardening but not a deployment blocker

---

## Sources

- [PSAppDeployToolkit Features](https://psappdeploytoolkit.com/features) — enterprise deployment lifecycle patterns (HIGH confidence)
- [Microsoft Learn: PowerShell DSC Idempotence](https://learn.microsoft.com/en-us/powershell/dsc/overview/DscForEngineers?view=dsc-1.1) — idempotency definition and patterns (HIGH confidence)
- [Microsoft Learn: Adding Checkpoints to Script Workflows](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/jj574114(v=ws.11)) — reboot-resume checkpoint pattern (HIGH confidence)
- [Microsoft Intune PowerShell Deployment Best Practices](https://headsinthecloud.blog/2026/02/24/from-packaging-to-logic-powershell-as-the-new-win32-installer-in-intune/) — check state, perform transition, verify target state pattern (MEDIUM confidence)
- [Crafting an Opinionated Logging Framework for PowerShell](https://devblogs.microsoft.com/ise/empowering-powershell-with-opinionated-best-practices-for-logging-and-error-handling/) — Microsoft ISE team logging patterns (HIGH confidence)
- [PowerShell -WhatIf Parameter](https://adamtheautomator.com/powershell-whatif/) — dry-run pattern implementation (HIGH confidence)
- [ADB Auto-Reconnect Script Pattern](https://github.com/StareInTheAir/shell-scripts/blob/master/adb-auto-reconnect) — retry loop reference (MEDIUM confidence)
- [AdvancedInstaller: Continuing PowerShell Scripts After Reboot](https://www.advancedinstaller.com/continue-powershell-script-after-reboot.html) — registry key checkpoint pattern for reboot-resume (MEDIUM confidence)
- [Fortra: PowerShell Best Practices Error Handling](https://automate.fortra.com/blog/powershell-error-handling) — $ErrorActionPreference Stop pattern (HIGH confidence)
