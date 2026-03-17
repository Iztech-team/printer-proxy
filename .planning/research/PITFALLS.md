# Domain Pitfalls: WSA/ADB Deployment Automation

**Domain:** Windows POS deployment — WSA + ADB bridge automation
**Researched:** 2026-03-17
**Project:** Baraka POS Deployment Hardening

---

## Critical Pitfalls

These mistakes cause deployment failures, require manual intervention, or break silently in production.

---

### Pitfall 1: Developer Mode Registry Write Does Not Actually Enable ADB

**What goes wrong:**
Writing `HKCU:\Software\Microsoft\WindowsSubsystemForAndroid\DeveloperMode = 1` does not reliably activate WSA's ADB daemon. The registry key is read by the WSA Settings UI but the daemon is only guaranteed to start when Developer Mode is toggled through the UI. On a fresh WSA install, the key may not exist and the path varies by WSA version. Post-write, the ADB port (58526) remains closed until WSA restarts and reads the key.

**Why it happens:**
WSA's ADB daemon startup is driven by the WSA service reading its configuration, not by a registry watcher. The registry write is advisory — it only takes effect when WSA reads it, which requires either a WSA restart or a UI interaction that triggers the settings reload.

**Consequences:**
The setup script writes the registry key, then immediately attempts `adb connect 127.0.0.1:58526` and gets a refused connection. The script falls back to opening WSA Settings and prompting for manual UI intervention — defeating zero-intervention deployment.

**Warning signs:**
- Script output shows "Developer Mode enabled via registry" immediately followed by "Waiting for WSA ADB... (attempt 1/6)"
- `adb connect` returns "Connection refused" within 2 seconds of the registry write
- The `DeveloperMode` key exists in the registry but port 58526 is not listening

**Prevention:**
After writing the registry key, restart WSA (kill WsaService + WsaClient, then re-launch via `WsaClient /launch wsa://system`) before attempting ADB connection. This forces WSA to re-read configuration. Allow 10–15 seconds for the daemon to come up. Verify with `netstat -an | findstr 58526` before attempting `adb connect`, not after.

**Phase:** WSA Developer Mode enablement hardening (Phase 1 of hardening roadmap)

---

### Pitfall 2: Hyper-V Steals Port 58526

**What goes wrong:**
When Hyper-V (or Virtual Machine Platform) is enabled, Windows dynamically reserves port ranges for the hypervisor. Port 58526 — WSA's fixed ADB port — frequently lands inside one of these reserved ranges. `adb connect 127.0.0.1:58526` fails with "actively refused" (error 10061) even when Developer Mode is correctly enabled and WSA is running.

**Why it happens:**
Hyper-V's dynamic port exclusion list is assigned at boot and changes between reboots. The exclusion ranges can be seen with `netsh int ipv4 show excludedportrange protocol=tcp`. When 58526 is excluded, nothing can listen on it — not even WSA's ADB daemon.

**Consequences:**
ADB connection fails consistently on that terminal despite all settings being correct. The problem appears intermittently (only on reboots where Hyper-V happens to claim that range), making it very hard to reproduce and diagnose. IT staff see a working terminal become broken after a reboot with no changes made.

**Warning signs:**
- `adb connect 127.0.0.1:58526` refuses connection but port is not shown in `netstat -an` at all
- `netsh int ipv4 show excludedportrange protocol=tcp` output includes range containing 58526
- Problem appeared after a Windows Update that refreshed Hyper-V configuration

**Prevention:**
Reserve port 58526 before Hyper-V takes it. Add this to the setup script's Windows features enablement phase, executed before rebooting to activate VirtualMachinePlatform:
```
netsh int ipv4 add excludedportrange protocol=tcp startport=58526 numberofports=1
```
This must run before the reboot that activates Hyper-V, otherwise Hyper-V claims the port first. Verify by running `netsh int ipv4 show excludedportrange protocol=tcp` post-reboot and checking 58526 appears as user-reserved, not system-reserved.

**Phase:** VM features enablement (must execute before the VirtualMachinePlatform reboot)

---

### Pitfall 3: WSA Auto-Terminates When No Android App Is in Foreground

**What goes wrong:**
WSA operates in "As needed" resource mode by default — the Android VM suspends or fully terminates when no Android app window is visible. This causes `adb reverse` tunnels to silently drop. The print server's `wsa_bridge.py` monitor runs every 30 seconds; if WSA terminated and restarted between checks, the port 58526 connection is severed and the tunnel is gone. The next print attempt from the POS app fails with a network error.

**Why it happens:**
WSA's default Subsystem Resources setting is "As needed." With no visible Android app window, the VM idles down. The ADB daemon also terminates with the VM. When WSA restarts (triggered by the next app launch), it comes up fresh with no `adb reverse` rules — even though the monitor may believe the connection is still alive.

**Consequences:**
POS app prints fail silently in production between customer transactions. The bridge monitor's `adb reverse --list` check correctly detects the tunnel is gone and attempts reconnection, but `adb connect` to 58526 fails because WSA is suspended. The reconnect loop does not trigger WSA to start — it just retries connection.

**Warning signs:**
- Monitor log shows "WSA bridge tunnel lost. Reconnecting..." during low-activity periods (overnight, between shifts)
- `adb connect` in the reconnect attempt returns refused rather than connected
- WSA UI shows as "not running" when the terminal has been idle

**Prevention:**
Set WSA's Subsystem Resources to "Continuous" during setup. This is controlled via the registry key `HKCU:\Software\Microsoft\WindowsSubsystemForAndroid\SubsystemResources` with value `Continuous`. Alternatively, keep a lightweight Android process alive (a background service in the APK). Additionally, the bridge reconnect logic in `wsa_bridge.py` must trigger WSA startup (`WsaClient /launch wsa://system`) before retrying `adb connect`, with a 10-15 second wait for the daemon.

**Phase:** ADB reconnection hardening (bridge monitor improvement)

---

### Pitfall 4: Add-AppxPackage Fails When Run as SYSTEM or in Non-Interactive Sessions

**What goes wrong:**
WSA installation via `Add-AppxPackage` (used in `Install.ps1`) fails with `HRESULT: 0x80073CF9` when the PowerShell process runs as the SYSTEM account (e.g., triggered by a scheduled task using the SYSTEM identity). The AppX deployment service explicitly rejects package installs from the SYSTEM context.

**Why it happens:**
`Add-AppxPackage` deploys packages per-user. The SYSTEM account has no user profile in the traditional sense, so the AppX stack cannot associate the package with a user. This is a by-design Microsoft restriction.

**Consequences:**
If the setup script is wrapped in a scheduled task (for example, for headless IT deployment) and that task runs as SYSTEM, WSA will never install. The script may report success (no error thrown if `-ErrorAction SilentlyContinue` is used) while WSA is silently not installed.

**Warning signs:**
- WSA package not present after script run when executed via scheduled task
- Event log shows `0x80073CF9` in Windows Apps deployment log
- `Get-AppxPackage -Name "MicrosoftCorporationII.WindowsSubsystemForAndroid"` returns null after installation step

**Prevention:**
Always invoke the WSA installation step as an interactive admin user, not as SYSTEM. When wrapping deployment in a scheduled task, use `Run only when user is logged on` with an admin account identity. If unattended deployment is required, use `schtasks /RU <DOMAIN\AdminUser>` with stored credentials, or deploy via a logon script that runs in the user context.

**Phase:** Setup script admin/privilege handling

---

### Pitfall 5: MagiskOnWSALocal Install.ps1 Spawns Multiple WSA Windows Asynchronously

**What goes wrong:**
The `Finish` function in MagiskOnWSALocal's `Install.ps1` launches WSA configuration via multiple `wsa://` protocol URIs asynchronously. This causes 3–4 WSA Settings windows to open simultaneously on the terminal screen. If not suppressed, these windows remain open and visible to store staff, blocking the UI and making the terminal appear broken. The current script has an aggressive `Stop-WSAWindows` call but the timing is fragile — killing windows too early aborts WSA's first-boot initialization.

**Why it happens:**
`Install.ps1` uses `Finish` to verify the installation by launching Android system apps via `wsa://` URIs. These launches are fire-and-forget with no way to suppress them from outside the script. The MagiskOnWSALocal maintainers acknowledged this behavior but did not provide a suppression mechanism.

**Consequences:**
Terminals display Android settings windows during deployment. Staff may interact with them (changing settings, toggling things). If windows are killed before WSA completes initialization, the WSA package can be left in a broken state requiring full uninstall/reinstall.

**Warning signs:**
- Multiple `WsaSettings.exe` or `WsaClient.exe` processes appearing in Task Manager during install
- WSA reports as installed but ADB connection fails after install completes
- WSA settings window shows "First run setup" screen on next launch

**Prevention:**
Insert a fixed wait of at least 15 seconds after `Install.ps1` exits before killing any WSA processes. Use the aggressive `Stop-WSAWindows` mode with extended kill loop only after this wait. The first-boot WSA initialization writes to the user profile and must be allowed to complete. Verify initialization is complete by checking that `WsaService.exe` is running and stable before proceeding to ADB steps.

**Phase:** WSA installation (Install.ps1 execution and cleanup)

---

### Pitfall 6: VirtualMachinePlatform Reboot-Resume Uses RunOnce Without Privilege Preservation

**What goes wrong:**
The reboot-resume mechanism in `windows_setup.ps1` registers the script in `HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce`. RunOnce entries run in the user's session context after logon. If the terminal auto-logs in as a standard (non-admin) user, the resumed script runs without elevation — and then fails silently at any step requiring admin privileges (WSA install, firewall rules, feature enablement verification).

**Why it happens:**
RunOnce does not preserve UAC elevation. The original script ran elevated, but the RunOnce trigger starts a new process in the user's default privilege level. Without `#Requires -RunAsAdministrator` or a self-elevating preamble in the continued execution path, the script proceeds with a false sense of being "already elevated."

**Consequences:**
The reboot-resume run appears to complete successfully but critical steps (WSA install, Windows Firewall rule creation, AppxPackage operations) silently fail or are skipped because `ErrorActionPreference = "Continue"` swallows errors. The terminal is left in a partially configured state.

**Warning signs:**
- Script output after resume shows "already done" for steps that were never completed
- Firewall rule not present after deployment (`netsh advfirewall firewall show rule name="Baraka Printer Server"` returns nothing)
- WSA not installed after reboot-resume despite install step appearing to pass

**Prevention:**
The RunOnce entry must launch PowerShell with explicit `-Verb RunAs` to request elevation, or use `schtasks` with `HIGHEST` run level instead of RunOnce. Prefer: register a one-shot scheduled task with `RunLevel = HIGHEST` and `LogonType = Interactive`, which self-deletes on completion. Additionally, add an admin check at the top of every sensitive function, not just at script entry.

**Phase:** VM features enablement / reboot-resume handling

---

### Pitfall 7: ADB Server Version Mismatch Silently Fails All Operations

**What goes wrong:**
If the terminal has an older ADB installation from a previous deployment attempt (e.g., Android Studio, another tool) and the setup script installs a newer `adb.exe` to a different path, two ADB server instances compete. When `adb connect` is run with one binary while the server was started by the other, all ADB commands appear to succeed (return code 0, output says "connected") but subsequent commands like `adb reverse` silently have no effect or return unexpected errors.

**Why it happens:**
ADB uses a client-server model. If two `adb` binaries with different versions exist and the old one started the daemon, the new binary kills the old server and restarts its own — but this restart is logged to stderr only, and some callers miss this. The reconnection race after server restart means the first `adb connect` call may hit the old server's dying process.

**Consequences:**
`adb reverse` appears to run but the tunnel is not active. The print server starts reporting "WSA bridge active" while no actual tunnel exists. The APK cannot reach the printer server. No error is surfaced unless `adb reverse --list` is explicitly checked.

**Warning signs:**
- Multiple `adb.exe` binaries found on PATH (`where adb` returns more than one path)
- `adb connect` output includes "daemon not running, starting it now" followed immediately by connection success
- `adb reverse --list` is empty immediately after `adb reverse tcp:3006 tcp:3006` returns 0

**Prevention:**
Before any ADB operation, enumerate all `adb.exe` on PATH and warn if more than one is found. Use an absolute path for ADB in all operations — never rely on PATH resolution when multiple installations may exist. After `adb start-server`, wait at least 3 seconds (not 2) before first `adb connect` — the daemon startup is not synchronous with the server process being listed.

**Phase:** ADB setup and bridge initialization

---

## Moderate Pitfalls

These cause unreliable behavior but can be worked around without a full re-deploy.

---

### Pitfall 8: CORS Wildcard Allows Any LAN Host to Trigger Prints

**What goes wrong:**
`allow_origins=["*"]` in `printer_server.py` means any machine on the store network — not just the POS app — can trigger print jobs. In a store environment, this includes customer Wi-Fi, PoS peripherals with web UIs, and staff personal devices. A misconfigured or malicious device could exhaust printer paper or trigger fraudulent receipts.

**Prevention:**
Replace `["*"]` with `["http://localhost", "http://127.0.0.1", "http://10.0.0.0/8"]` or derive allowed origins from an `ALLOWED_ORIGINS` env variable. Because this is a LAN-only server with no auth, CORS is the only access boundary. Restricting to localhost and the LAN subnet is sufficient. Note: `allow_credentials=True` is incompatible with `allow_origins=["*"]` — if credentials are ever added, the wildcard will cause runtime errors.

**Phase:** CORS hardening

---

### Pitfall 9: WSA Bridge Monitor Silently Swallows All Exceptions

**What goes wrong:**
`_monitor_loop()` in `wsa_bridge.py` has a bare `except Exception: pass` that silently absorbs every error including ADB binary not found, process crashes, and permission errors. If `adb.exe` is deleted or PATH changes after deployment, the monitor continues running, reports no errors, but `adb reverse --list` calls never succeed. The bridge appears "connected" (`self.connected = True` is never cleared by the monitor) while actually being dead.

**Prevention:**
Replace `pass` with at minimum `logger.debug(f"WSA bridge monitor error: {e}")`. Add a `self.connected = False` path when the health check fails multiple consecutive times. Expose bridge status via a `/health` or `/wsa-bridge/status` endpoint that the monitoring/ops team can poll.

**Phase:** Bridge monitor reliability

---

### Pitfall 10: WSA Startup Timing Is Non-Deterministic Across Hardware

**What goes wrong:**
The setup script uses fixed `Start-Sleep` durations (2s, 5s, 15s) to wait for WSA to start. On slower store terminals (older Celeron-based units, HDDs), WSA cold start can take 30–45 seconds. On faster hardware, 5 seconds is more than enough. Fixed sleeps mean either over-waiting on fast hardware (poor UX) or under-waiting on slow hardware (false failures).

**Prevention:**
Replace all fixed sleep-then-connect patterns with poll-until-ready loops with a configurable timeout. Pattern: poll `adb connect 127.0.0.1:58526` every 2 seconds up to a maximum of 60 seconds, breaking early on success. This is already partially implemented in `Step-ConfigureWSADevMode` (6 attempts × 2s = 12s) but the pre-ADB waits still use fixed sleeps.

**Phase:** WSA startup and ADB connection sequencing

---

### Pitfall 11: Blocked Deployment When Script Is Re-Run on Partially-Configured Terminal

**What goes wrong:**
If a previous deployment attempt left the terminal partially configured (WSA installed but Dev Mode not enabled, or bridge set up but no APK), a re-run of the setup script may skip steps that appear complete but are actually broken. For example, `Test-WSAInstalled` checks for the AppxPackage name — but a corrupt WSA installation still satisfies this check. The script skips reinstall and proceeds to ADB steps that then fail.

**Prevention:**
Add a `--force-reinstall` flag that bypasses all "already done" checks. For each step that has a health check, separate "is it installed" from "is it working correctly." Specifically: WSA install check should verify not just package presence but that `WsaService` can be started and ADB connects, not just that the AppxPackage is registered.

**Phase:** Setup script idempotency and error recovery

---

## Minor Pitfalls

---

### Pitfall 12: ADB Reverse Drops on WSA Reboot (Not WSA Sleep)

**What goes wrong:**
If the Windows terminal restarts (update, power cycle), the `adb reverse` tunnel is completely gone. The `wsa_bridge.py` monitor reconnects the ADB TCP connection but does not re-run `adb reverse` unless `adb reverse --list` shows the rule missing. However, the `--list` check can succeed (return exit code 0) while actually listing no rules — this is correct behavior, but the current code checks for the string `tcp:{server_port}` in stdout, which works correctly only if the list output format matches expectations across ADB versions.

**Prevention:**
After any ADB reconnect, always re-issue `adb reverse tcp:{port} tcp:{port}` unconditionally rather than checking whether it's still listed. The cost of re-issuing a no-op reverse command is negligible. This also handles the edge case where WSA restarted and cleared all rules.

**Phase:** Bridge monitor reliability

---

### Pitfall 13: python-escpos and Pillow Version Conflicts on Repeat Deployments

**What goes wrong:**
If the setup script is re-run on a terminal where a different version of Python or its packages was previously installed, `pip install -r requirements.txt` may partially upgrade or downgrade packages. Pillow 10.x renamed `Image.LANCZOS` to `Image.Resampling.LANCZOS` — having Pillow 9.x installed causes `AttributeError` on first image print. The `requirements.txt` uses `>=` bounds that allow this.

**Prevention:**
Pin exact versions in `requirements.txt` for production deployment. Use `pip install --upgrade -r requirements.txt` rather than `pip install -r requirements.txt` to ensure consistent state. The CONCERNS.md already flags this — address it in the hardening milestone.

**Phase:** Python dependency management

---

### Pitfall 14: WSA Package Name Hardcoding Will Break on Community Builds

**What goes wrong:**
All WSA checks in `windows_setup.ps1` hardcode `MicrosoftCorporationII.WindowsSubsystemForAndroid`. MagiskOnWSALocal community builds (MustardChef/WSABuilds) use a different package identity. If the terminal uses a community-build MSIX rather than the Microsoft Store package, `Get-AppxPackage -Name "MicrosoftCorporationII.WindowsSubsystemForAndroid"` returns null and all WSA-related steps are skipped.

**Warning signs:**
- `Test-WSAInstalled` returns false on a terminal where WSA is visibly running
- Script skips Steps 7–9 because it believes WSA is not installed

**Prevention:**
Use a wildcard pattern in the package name check: `Get-AppxPackage -Name "*WindowsSubsystemForAndroid*"`. This matches both official and community builds. Store the resolved package object once and reference it throughout the script rather than re-querying.

**Phase:** WSA detection and install logic

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| VM features enablement | Reboot-resume loses elevation (Pitfall 6) | Use scheduled task with HIGHEST run level instead of RunOnce |
| VM features enablement | Hyper-V claims port 58526 before reboot (Pitfall 2) | Run `netsh int ipv4 add excludedportrange` before rebooting |
| WSA installation | Install.ps1 spawns windows, timing-sensitive (Pitfall 5) | 15s wait after Install.ps1 exit before any process kills |
| WSA Developer Mode | Registry write does not activate daemon (Pitfall 1) | WSA restart after registry write; poll port readiness |
| ADB setup | Multiple ADB binaries competing (Pitfall 7) | Enumerate PATH, warn, use absolute paths only |
| Bridge monitor | Silent exception swallowing (Pitfall 9) | Log all exceptions; clear `connected` flag on failure |
| Bridge monitor | WSA idle terminates VM, drops tunnel (Pitfall 3) | Set WSA to Continuous mode; trigger WSA start before reconnect |
| Re-deployment | Corrupt install passes `Test-WSAInstalled` (Pitfall 11) | Add `--force-reinstall` flag; health check vs. presence check |
| CORS hardening | Wildcard allows full LAN access (Pitfall 8) | Restrict to localhost + LAN subnet via env var |

---

## Sources

- [WSA ADB Connection Refusal — microsoft/WSA Issue #136](https://github.com/microsoft/WSA/issues/136) (MEDIUM confidence — multiple user reports, unresolved by Microsoft)
- [WSA ADB Port 127.0.0.1:58526 — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/788883/cannot-connect-to-127-0-0-1-58526-(port-shown-unde)) (MEDIUM confidence)
- [Hyper-V Port Exclusion Ranges — microsoft/WSL Issue #5514](https://github.com/microsoft/WSL/issues/5514) (HIGH confidence — well-documented Hyper-V behavior)
- [WSA Command Line Launch — microsoft/WSA Issue #218](https://github.com/microsoft/WSA/issues/218) (HIGH confidence — `WsaClient /launch wsa://system` confirmed working)
- [MagiskOnWSALocal Install.ps1 failures — LSPosed Issue #122](https://github.com/LSPosed/MagiskOnWSALocal/issues/122) (HIGH confidence — maintainer acknowledgment)
- [Add-AppxPackage SYSTEM user failure — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/354337/system-user-cannot-run-the-add-appxpackage-command) (HIGH confidence — documented Microsoft restriction)
- [ADB reverse fails via TCP — Google Issue Tracker #37066218](https://issuetracker.google.com/issues/37066218) (MEDIUM confidence — reported behavior)
- [WSA Hidden Settings — XDA Forums](https://xdaforums.com/t/windows-subsystem-for-android-hidden-settings-device-administrator-access.4399723/) (LOW confidence — community exploration, no official confirmation)
- [FastAPI CORS Wildcard Risk](https://fastapi.tiangolo.com/tutorial/cors/) (HIGH confidence — official FastAPI docs)
- Baraka codebase: `wsa_bridge.py`, `windows_setup.ps1`, `.planning/codebase/CONCERNS.md` (HIGH confidence — direct code inspection)
