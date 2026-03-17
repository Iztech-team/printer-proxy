# Project Research Summary

**Project:** Baraka POS Deployment Hardening
**Domain:** Windows unattended deployment automation (WSA + ADB + Python print server)
**Researched:** 2026-03-17
**Confidence:** HIGH (majority of findings backed by official Microsoft documentation)

## Executive Summary

Baraka is a POS system running an Android APK on Windows via the Windows Subsystem for Android (WSA), with a Python/FastAPI print server bridged over ADB reverse tunneling. The deployment hardening goal is to replace a fragile, partially-manual setup sequence with a single self-contained PowerShell script that can be run unattended on any qualified terminal and reach a verified working state — including after reboots. The established approach for this class of problem is a registry-backed state machine with per-step idempotency guards, a scheduled-task-based reboot-resume mechanism, and a final health-verification pass before declaring success.

The recommended architecture is a single `deploy.ps1` entry point with discrete step files (preflight, VM features, WSA install, WSA configure, ADB, APK, print server, verify), each guarded by a registry flag. This structure makes partial re-runs safe and makes failures diagnosable. PowerShell 5.1 (built-in) is the correct runtime — PowerShell 7+ lacks the Windows-only Appx and DISM modules that this project needs. ADB binaries must be bundled in the deployment package; system PATH cannot be trusted.

The single highest-risk area is WSA Developer Mode: no reliable zero-touch programmatic method exists for first-run activation. The honest strategy is to write the registry key, restart WSA, and probe ADB with a retry loop — and if ADB is still refused after 60 seconds, emit a clear instruction asking the operator to enable developer mode once via the WSA Settings UI, then re-run. Every subsequent re-run on that terminal (or a cloned image) is fully automatic. The second critical pitfall is Hyper-V port exclusion: port 58526 must be explicitly reserved via `netsh` before the VirtualMachinePlatform reboot, or Hyper-V may claim it and break ADB on every subsequent boot.

## Key Findings

### Recommended Stack

The entire automation layer is built on Windows PowerShell 5.1 using only built-in Windows modules: DISM (`Enable-WindowsOptionalFeature`) for VM feature management, Appx (`Add-AppxPackage`) for WSA MSIX registration, and the Task Scheduler cmdlets for reboot-resume. No external dependencies or installable runtimes are needed for the deployment script itself.

ADB tooling must be bundled (`adb.exe`, `AdbWinApi.dll`, `AdbWinUsbApi.dll`) rather than resolved from PATH — terminals may have stale or mismatched ADB installations from prior attempts. The WSA package itself (MagiskOnWSALocal build) is also part of the deployment bundle; the script must accept its path as a parameter rather than hardcoding it.

**Core technologies:**
- PowerShell 5.1: primary orchestration — only version with Appx + DISM modules on Windows client
- `Enable-WindowsOptionalFeature` (DISM module): enable VirtualMachinePlatform before WSA can start
- `Add-AppxPackage -Register -ForceApplicationShutdown -ForceUpdateFromAnyVersion`: WSA MSIX install from unpacked directory
- Bundled `adb.exe` (SDK Platform Tools 35.x): APK install and port-forwarding — must use absolute path
- Task Scheduler (`Register-ScheduledTask -RunLevel Highest`): reboot-resume without losing elevation
- Registry (`HKLM:\SOFTWARE\Baraka\Deploy\`): persistent state machine surviving reboots
- `netsh int ipv4 add excludedportrange`: reserve port 58526 before Hyper-V claims it

### Expected Features

**Must have (table stakes):**
- Idempotent execution — safe to re-run after any failure at any step
- Structured timestamped logging to `%ProgramData%\Baraka\deploy.log`
- Explicit exit codes (0 = success, non-zero per failure category)
- Pre-flight checks — OS edition, admin privilege, virtualisation capability, disk space, ADB binary
- `$ErrorActionPreference = "Stop"` with try/catch on every mutating call
- Windows Optional Features enablement (VirtualMachinePlatform, HypervisorPlatform)
- Reboot-resume via scheduled task at HIGHEST run level (not RunOnce — RunOnce loses elevation)
- WSA Developer Mode: registry write + WSA restart + ADB probe loop, with clear manual-fallback message
- ADB connection with exponential backoff retry (poll `adb devices` for `device` status, not exit codes)
- APK install idempotency — compare installed version before `adb install`
- Print server service/task verification
- Post-deployment health verification — WSA running, ADB connected, APK listed, print server HTTP reachable

**Should have (differentiators, next hardening pass):**
- Dry-run / -WhatIf mode for pre-deployment audits
- Machine-readable `deploy-result.json` for IT tooling / RMM ingestion
- Verbose / debug flag for troubleshooting individual terminals
- Configurable parameters via `deploy.config.json` sidecar
- CORS restriction — replace wildcard with localhost + LAN subnet
- `--force-reinstall` flag to bypass "already done" guards on corrupt partial installs
- Network log archival to UNC share

**Defer to v2+:**
- Full rollback — a re-run of the idempotent script is the pragmatic substitute at this scale
- Machine-readable deployment report / transcript archival to central share
- Canary or blue-green deployment patterns (inapplicable to single-terminal fleet)

**Anti-features (explicitly avoid):**
- `Read-Host` or any interactive prompts during deployment
- Silent `catch {}` blocks — every catch must log
- Hardcoded APK/WSA package paths
- GUI-dependent automation (SendKeys, AutoIt)
- Reboot without registered resume task

### Architecture Approach

The architecture is a single-entry PowerShell orchestrator (`deploy.ps1`) backed by three shared library modules (State, Log, Guard) and eight discrete step scripts. Each step is wrapped in a standard `Invoke-Step` pattern that checks a per-step registry guard before executing and sets it on success. The registry under `HKLM:\SOFTWARE\Baraka\Deploy\` serves as the sole persistent state store — it survives reboots, is readable by external tools, and can be cleared to force a full re-run. The print server setup step is independent of the WSA/ADB chain and can run in parallel or in its own phase.

**Major components:**
1. `deploy.ps1` — argument parsing, phase routing, reboot orchestration, scheduled task lifecycle
2. `State.psm1` — registry-backed phase tracking; read on startup to resume post-reboot at correct step
3. `Log.psm1` — all output through a single timestamped `Write-Log` function; append to `deploy.log`
4. `Guard.psm1` — `Assert-NotAlreadyDone` per-step idempotency check against registry flags
5. Steps 01–08 — each owns one responsibility: preflight, VM features, WSA install, WSA configure, ADB connect, APK install, print server, verify

### Critical Pitfalls

1. **Developer Mode registry write does not activate ADB daemon** — The registry key is advisory; WSA only reads it on restart. After writing `DeveloperMode = 1`, kill WsaService + WsaClient and relaunch via `WsaClient /launch wsa://system`, then wait 10–15 seconds before probing `netstat -an | findstr 58526`. If port never opens, emit a clear manual-fallback message.

2. **Hyper-V claims port 58526 at boot** — Run `netsh int ipv4 add excludedportrange protocol=tcp startport=58526 numberofports=1` during the VM features step, before the reboot that activates VirtualMachinePlatform. If this step is skipped, ADB connection will fail intermittently — only detectable via `netsh int ipv4 show excludedportrange`.

3. **Reboot-resume loses admin elevation via RunOnce** — RunOnce runs at user privilege level. Replace with a one-shot scheduled task using `RunLevel = HIGHEST` and `LogonType = Interactive`, self-deleted on completion. The current `windows_setup.ps1` uses RunOnce and is vulnerable to this on standard-user auto-logon terminals.

4. **`Add-AppxPackage` fails when run as SYSTEM** — This is a by-design Microsoft restriction. The WSA install step must run as an interactive admin user, not as the SYSTEM account. Scheduled tasks for reboot-resume must use `Run only when user is logged on` with an admin identity, not the SYSTEM account.

5. **WSA auto-terminates when idle, dropping ADB reverse tunnel** — WSA defaults to "As needed" resource mode. Set `HKCU:\Software\Microsoft\WindowsSubsystemForAndroid\SubsystemResources = Continuous` during the configure step. The bridge monitor (`wsa_bridge.py`) must also trigger `WsaClient /launch wsa://system` before retrying `adb connect` on reconnect — not just retry the connection blindly.

## Implications for Roadmap

Based on the dependency chain discovered in research, the natural phase structure follows the hard dependency order: environment prerequisites before installation, installation before configuration, configuration before connectivity, connectivity before application, and verification last. The print server work is independent and can be parallelized or treated as a separate phase.

### Phase 1: Foundation and Pre-flight

**Rationale:** Library modules (State, Log, Guard) and pre-flight checks must exist before any mutating step runs. Failing fast on an incompatible machine protects IT from partial-deploy confusion. This is pure scaffolding — no system changes.
**Delivers:** `deploy.ps1` entry point, three shared lib modules, pre-flight validation step (OS edition, admin, virtualisation, disk, ADB binary)
**Addresses:** Idempotent execution, structured logging, explicit exit codes, admin privilege detection, `$ErrorActionPreference = "Stop"` enforcement
**Avoids:** Silent error swallowing (Pitfall 9 pattern), monolithic script anti-pattern

### Phase 2: VM Features + Reboot Resume

**Rationale:** VirtualMachinePlatform must be enabled and a reboot completed before WSA can be installed or run. This phase is the primary deployment blocker. Port reservation must happen here before Hyper-V claims 58526 on the reboot.
**Delivers:** VirtualMachinePlatform + HypervisorPlatform enabled, port 58526 reserved via `netsh`, scheduled task registered for post-reboot resume at HIGHEST run level, terminal rebooted and deployment continued automatically
**Addresses:** Windows Optional Features enablement, reboot-resume logic (registry checkpoint + scheduled task)
**Avoids:** Hyper-V port theft (Pitfall 2), elevation loss via RunOnce (Pitfall 6)
**Research flag:** Standard — well-documented Microsoft patterns, HIGH confidence

### Phase 3: WSA Installation

**Rationale:** Depends on VM features + reboot. Must install before any WSA configuration can occur. Timing and process handling here is finicky per pitfall research.
**Delivers:** MagiskOnWSALocal MSIX registered via `Add-AppxPackage`, WSA first-boot initialization completed (15s wait before any process kills), install idempotency guard in place
**Addresses:** WSA installation state detection, `Add-AppxPackage` flag usage (`-ForceApplicationShutdown`, `-ForceUpdateFromAnyVersion`), wildcard package name detection (`*WindowsSubsystemForAndroid*`)
**Avoids:** Install.ps1 async window spawning (Pitfall 5), SYSTEM account install failure (Pitfall 4), hardcoded package name (Pitfall 14)
**Research flag:** Standard — well-documented, but test timing assumptions on slow hardware

### Phase 4: WSA Developer Mode + ADB Connection

**Rationale:** Configuration must follow installation. ADB cannot connect until developer mode is active. This is the hardest phase with the most pitfalls — deserves its own phase boundary.
**Delivers:** Registry developer mode key written, WSA restarted to apply config, WSA set to Continuous resource mode, ADB connection established via exponential-backoff retry loop (60s timeout), clear manual-fallback message if ADB still refused
**Addresses:** Developer Mode enablement (table stakes), ADB connection with retry, WSA persistent mode (`SubsystemResources = Continuous`)
**Avoids:** Registry write without WSA restart (Pitfall 1), ADB binary version conflicts (Pitfall 7), non-deterministic WSA startup timing (Pitfall 10), WSA idle termination dropping tunnel (Pitfall 3)
**Research flag:** Needs validation — developer mode registry key mapping requires empirical discovery on real hardware (Approach B from STACK.md); the ADB probe fallback is the reliable backstop

### Phase 5: APK Installation

**Rationale:** Depends on active ADB connection. Straightforward once ADB is working.
**Delivers:** Baraka POS APK installed and version-verified on WSA
**Addresses:** APK installation idempotency (version check before install), `adb install -r` with guard
**Avoids:** Unnecessary reinstall of already-correct version

### Phase 6: Print Server Hardening

**Rationale:** Independent of WSA/ADB chain. Can be addressed after the ADB path is stable. Groups two related concerns (service verification and CORS security).
**Delivers:** Print server scheduled task verified present and in correct state; CORS restricted from wildcard to localhost + LAN subnet via `ALLOWED_ORIGINS` env variable; bridge monitor exception handling improved (log all exceptions, clear `connected` flag on consecutive failures)
**Addresses:** Print server service registration verification, CORS hardening, bridge monitor silent swallowing (Pitfall 9)
**Avoids:** Wildcard CORS allowing full-LAN print access (Pitfall 8), phantom "connected" bridge state (Pitfall 9)
**Research flag:** Standard — FastAPI CORS docs are authoritative, patterns are clear

### Phase 7: End-to-End Verification + Reporting

**Rationale:** Must run last. Confirms the deployment actually worked, not just that steps appeared to complete. Includes final state cleanup.
**Delivers:** Smoke test suite (WSA running, ADB device listed, APK package present, print server `/health` reachable), `deploy-result.json` written, scheduled task cleanup confirmed, exit code 0 only on full pass
**Addresses:** Post-deployment health verification, explicit exit codes, step-level error messages
**Avoids:** False success from steps that appeared to complete but left broken state (Pitfall 11)

### Phase Ordering Rationale

- Phases 1-2 are pure prerequisites — no WSA work can proceed without them.
- Phase 3 depends on a completed reboot from Phase 2 (hard OS dependency).
- Phase 4 depends on Phase 3 (cannot configure WSA before it is installed).
- Phase 5 depends on Phase 4 (cannot install APK without ADB connection).
- Phase 6 is independent — deliberately separated to isolate the riskier WSA/ADB work.
- Phase 7 is unconditionally last — it validates all prior work.
- The registry state machine means any failure drops a checkpoint that allows re-running from the failure point, not from the beginning.

### Research Flags

Phases needing deeper research / on-machine validation during planning:
- **Phase 4 (Developer Mode):** WSA developer mode registry key path is not publicly documented. Requires empirical discovery: enable via UI on a test machine, then diff `HKCU:\Software\Microsoft\WindowsSubsystemForAndroid` before/after. The ADB probe loop is the reliable backstop if registry automation fails.
- **Phase 3 (WSA Install timing):** 15-second wait after Install.ps1 exit is community-derived. Should be validated on the actual terminal hardware used in stores (especially older Celeron-based units).

Phases with standard patterns (skip additional research):
- **Phase 1:** Logging, state management, and pre-flight patterns are well-documented and HIGH confidence.
- **Phase 2:** DISM cmdlets, port reservation, and scheduled task reboot-resume are officially documented.
- **Phase 5:** ADB `adb install -r` with `pm list packages` version check is standard, well-documented.
- **Phase 6:** FastAPI CORS and Python dependency pinning are authoritative-source patterns.
- **Phase 7:** PowerShell health-check patterns are established; no novel territory.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | PowerShell 5.1 modules (DISM, Appx), ADB tooling all verified against official Microsoft/Android docs. WSAClient.exe parameters are MEDIUM (community-only, official docs removed with WSA deprecation March 2025). |
| Features | HIGH | Table stakes list cross-referenced against PSAppDeployToolkit, Microsoft Intune patterns, and direct codebase inspection. Differentiators are clearly separated from MVP. |
| Architecture | HIGH | Step-module pattern with registry state machine is confirmed by multiple independent sources. Build order follows hard OS dependencies. |
| Pitfalls | HIGH | 7 critical pitfalls with direct evidence (GitHub issues, Microsoft Q&A, official docs). 2 pitfalls (developer mode registry key, WSA package name variant) flagged as needing on-machine verification. |

**Overall confidence:** HIGH

### Gaps to Address

- **WSA Developer Mode registry key:** The exact registry path and value that activates WSA's ADB daemon is not publicly documented. Plan for Phase 4 to include an empirical discovery step on a test terminal (diff registry before/after UI toggle). Design Phase 4 with the manual-fallback path as an acceptable first-deployment outcome — full automation is a stretch goal.
- **WSA startup timing on store hardware:** All timing values (15s post-install wait, 10–15s post-restart wait) are community-derived. Validate on actual store terminal hardware — particularly any Celeron-based units that may have 30–45 second WSA cold-start times. Make all waits poll-based with configurable maximums, not fixed sleeps.
- **WSA deprecation impact:** Microsoft deprecated WSA in March 2025. Official documentation is partially removed. Community-maintained builds (MustardChef/WSABuilds) are the active continuation. Wildcard package name detection (`*WindowsSubsystemForAndroid*`) insulates against build variants, but long-term WSA viability is a strategic risk outside the scope of this hardening work.

## Sources

### Primary (HIGH confidence)
- [Enable-WindowsOptionalFeature — Microsoft Docs (2025-05-14)](https://learn.microsoft.com/en-us/powershell/module/dism/enable-windowsoptionalfeature) — DISM cmdlet, RestartNeeded property
- [Add-AppxPackage — Microsoft Docs (2025-05-14)](https://learn.microsoft.com/en-us/powershell/module/appx/add-appxpackage) — MSIX registration flags
- [Android Debug Bridge — Android Developers](https://developer.android.com/tools/adb) — ADB connect, devices, reverse, install
- [Hyper-V Port Exclusion — microsoft/WSL Issue #5514](https://github.com/microsoft/WSL/issues/5514) — port reservation before Hyper-V reboot
- [Add-AppxPackage SYSTEM failure — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/354337/system-user-cannot-run-the-add-appxpackage-command) — SYSTEM account restriction
- [MagiskOnWSALocal Install.ps1 — LSPosed Issue #122](https://github.com/LSPosed/MagiskOnWSALocal/issues/122) — window spawning timing pitfall
- [FastAPI CORS — Official Docs](https://fastapi.tiangolo.com/tutorial/cors/) — CORS wildcard risks
- [PSAppDeployToolkit](https://psappdeploytoolkit.com/) — enterprise deployment lifecycle patterns
- Baraka codebase: `wsa_bridge.py`, `windows_setup.ps1`, `.planning/codebase/CONCERNS.md` — direct code inspection

### Secondary (MEDIUM confidence)
- [WsaClient.exe parameters — vhanla gist](https://gist.github.com/vhanla/247ee77dd0cdd5449e02e2d517a13019) — WsaClient CLI flags (no official docs post-deprecation)
- [ADB Connection and Commands — MustardChef/WSABuilds DeepWiki](https://deepwiki.com/MustardChef/WSABuilds/6.1-adb-connection-and-commands) — WSA port 58526 confirmation
- [Continuing PowerShell Scripts After Reboot — Advanced Installer](https://www.advancedinstaller.com/continue-powershell-script-after-reboot.html) — registry checkpoint reboot-resume pattern
- [Microsoft Intune PowerShell Best Practices](https://headsinthecloud.blog/2026/02/24/from-packaging-to-logic-powershell-as-the-new-win32-installer-in-intune/) — state check before transition pattern
- [WSA ADB Connection Refused — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/788883/cannot-connect-to-127-0-0-1-58526) — community-confirmed behavior

### Tertiary (LOW confidence)
- [WSA Hidden Settings — XDA Forums](https://xdaforums.com/t/windows-subsystem-for-android-hidden-settings-device-administrator-access.4399723/) — developer mode registry key exploration (needs on-machine verification)

---
*Research completed: 2026-03-17*
*Ready for roadmap: yes*
