---
phase: 03-wsa-setup-adb-apk
verified: 2026-03-17T00:00:00Z
status: passed
score: 12/12 must-haves verified
re_verification: false
---

# Phase 3: WSA Setup, ADB, APK Verification Report

**Phase Goal:** The Baraka POS APK is installed and running inside WSA on a fully configured, ADB-connected terminal
**Verified:** 2026-03-17
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | WSA installs silently via Add-AppxPackage -Register from the unpacked MagiskOnWSALocal directory | VERIFIED | `steps/03-wsa-install.ps1:30` — `Invoke-AddAppxPackage` calls `Add-AppxPackage -Register $ManifestPath -ForceApplicationShutdown -ForceUpdateFromAnyVersion` |
| 2 | Auto-launched WSA windows are killed after a 15s post-install wait (WsaSettings, WsaClient stopped; WsaService left running) | VERIFIED | `steps/03-wsa-install.ps1:101-102` — `Invoke-Sleep -Seconds 15` then `Stop-WsaWindows`; `Stop-WsaWindows` stops only `WsaSettings` and `WsaClient` |
| 3 | Script polls for WsaService process up to 45s to confirm WSA initialization — no fixed sleep | VERIFIED | `steps/03-wsa-install.ps1:58-74` — `Invoke-WsaServiceWait` uses `while ((Get-Date) -lt $deadline)` loop, not `Start-Sleep` for the wait |
| 4 | When WSA is already installed, Add-AppxPackage is not called | VERIFIED | `steps/03-wsa-install.ps1:89-92` — `Test-WsaInstalled` checked first; returns early logging "already installed -- skipping" |
| 5 | Developer Mode registry key is written and WSA is restarted (kill + relaunch) to activate ADB daemon | VERIFIED | `steps/04-wsa-configure.ps1:50` — `Set-ItemProperty ... "DeveloperMode" -Value 1`; `Invoke-WsaRestart` called at line 62 |
| 6 | VMLifeCycleMode is set to Continuous to prevent idle VM termination between steps | VERIFIED | `steps/04-wsa-configure.ps1:57` — `Set-ItemProperty ... "VMLifeCycleMode" -Value "Continuous"` |
| 7 | ADB connection uses exponential backoff retry (5 attempts, delays 5/10/20/40/60s capped at 60) | VERIFIED | `steps/04-wsa-configure.ps1:125-129` — `$delaySec = [math]::Min($BaseDelaySec * [math]::Pow(2, $i - 1), 60)`; sleep only when `$i -lt $MaxAttempts` |
| 8 | ADB success is determined by parsing adb devices output for endpoint + device status, not exit codes | VERIFIED | `steps/04-wsa-configure.ps1:119` — `$devices -match ([regex]::Escape($Endpoint) + '\s+device')` |
| 9 | When all ADB retries fail, a clear manual instruction is logged and the step throws (guard flag NOT set) | VERIFIED | `steps/04-wsa-configure.ps1:137-141` — 4 WARN-level lines including "MANUAL ACTION REQUIRED"; `Invoke-WsaConfigure` throws at line 159 |
| 10 | APK file is auto-detected in the deployment bundle directory via Get-ChildItem *.apk | VERIFIED | `steps/05-apk-install.ps1:33` — `Get-ChildItem -Path $BundleRoot -Filter "*.apk" -Recurse ... \| Select-Object -First 1` |
| 11 | Installed APK version is queried via adb shell pm list packages before installing — skip if already present | VERIFIED | `steps/05-apk-install.ps1:53-57` — `Invoke-AdbCommand ... "shell pm list packages"` checked; returns 1 (skip) or -1 (install) |
| 12 | deploy.ps1 orchestrates all three Phase 3 steps (WsaInstall, WsaConfigure, ApkInstall) in sequence via Invoke-Step | VERIFIED | `deploy.ps1:67-77` — 5 Invoke-Step calls in order: Preflight -> VmFeatures -> WsaInstall -> WsaConfigure -> ApkInstall |

**Score:** 12/12 truths verified

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `steps/03-wsa-install.ps1` | WSA install step with idempotency, window suppression, poll-based init wait | VERIFIED | 115 lines; 6 functions: `Test-WsaInstalled`, `Invoke-AddAppxPackage`, `Stop-WsaWindows`, `Invoke-Sleep`, `Invoke-WsaServiceWait`, `Invoke-WsaInstall`; BARAKA_TEST_MODE guard present |
| `tests/WsaInstall.Tests.ps1` | Pester tests covering WSAI-01 through WSAI-04; min 80 lines | VERIFIED | 256 lines; 12 It-blocks spanning 4 Describe blocks covering all WSAI requirements |
| `steps/04-wsa-configure.ps1` | WSA dev mode config, Continuous resource mode, ADB retry with manual fallback | VERIFIED | 172 lines; 6 functions: `Invoke-Sleep`, `Invoke-AdbCommand`, `Set-WsaDeveloperMode`, `Invoke-WsaRestart`, `Connect-Adb`, `Invoke-WsaConfigure`; BARAKA_TEST_MODE guard present |
| `tests/WsaConfigure.Tests.ps1` | Pester tests covering ADBM-01 through ADBM-05; min 120 lines | VERIFIED | 340 lines; 16 It-blocks spanning 6 Describe blocks covering all ADBM requirements |
| `steps/05-apk-install.ps1` | APK auto-detection, version check, install with verification | VERIFIED | 117 lines; 5 functions: `Invoke-AdbCommand`, `Find-ApkFile`, `Get-InstalledApkVersionCode`, `Invoke-ApkInstallCommand`, `Invoke-ApkInstall`; BARAKA_TEST_MODE guard present |
| `tests/ApkInstall.Tests.ps1` | Pester tests covering APKS-01 through APKS-03; min 80 lines | VERIFIED | 162 lines; 9 It-blocks spanning 5 Describe blocks covering all APKS requirements |
| `deploy.ps1` | Extended with WsaInstall, WsaConfigure, ApkInstall Invoke-Step calls | VERIFIED | `Invoke-Step -StepName "WsaInstall"`, `"WsaConfigure"`, `"ApkInstall"` all present at lines 67, 71, 75 |

---

## Key Link Verification

### Plan 01 Key Links

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `steps/03-wsa-install.ps1` | `lib/Log.psm1` | `Write-Log` calls | WIRED | `Write-Log` found at lines 67, 72, 90, 95 |
| `steps/03-wsa-install.ps1` | `deploy.ps1` | `Invoke-Step -StepName "WsaInstall"` | WIRED | `deploy.ps1:67` — `Invoke-Step -StepName "WsaInstall"` with dot-source of `steps\03-wsa-install.ps1` |
| `tests/WsaInstall.Tests.ps1` | `steps/03-wsa-install.ps1` | dot-source with `BARAKA_TEST_MODE='1'` | WIRED | `tests/WsaInstall.Tests.ps1:79` — `$env:BARAKA_TEST_MODE = '1'` set before dot-source at line 80 |

### Plan 02 Key Links

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `steps/04-wsa-configure.ps1` | `lib/Log.psm1` | `Write-Log` calls | WIRED | `Write-Log` found at lines 46, 53, 59, 72, 85, 89, 120, 128, 131, 136-139, 162 |
| `steps/04-wsa-configure.ps1` | Registry `HKCU:\Software\Microsoft\WindowsSubsystemForAndroid` | `Set-ItemProperty` for `DeveloperMode` | WIRED | `steps/04-wsa-configure.ps1:50` — `Set-ItemProperty -Path $wsaPath -Name "DeveloperMode" -Value 1` |
| `steps/04-wsa-configure.ps1` | Registry `HKCU:\Software\Microsoft\WSA` | `Set-ItemProperty` for `VMLifeCycleMode` | WIRED | `steps/04-wsa-configure.ps1:57` — `Set-ItemProperty -Path $wsaVmPath -Name "VMLifeCycleMode" -Value "Continuous"` |
| `tests/WsaConfigure.Tests.ps1` | `steps/04-wsa-configure.ps1` | dot-source with `BARAKA_TEST_MODE='1'` | WIRED | `tests/WsaConfigure.Tests.ps1:75` — `$env:BARAKA_TEST_MODE = '1'` set before dot-source at line 77 |

### Plan 03 Key Links

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `steps/05-apk-install.ps1` | `steps/04-wsa-configure.ps1` | ADB prerequisite enforced by `deploy.ps1` step ordering | WIRED | `deploy.ps1` dispatches WsaConfigure (line 71) before ApkInstall (line 75) |
| `steps/05-apk-install.ps1` | `lib/Log.psm1` | `Write-Log` for all output | WIRED | `Write-Log` found at lines 37, 97, 102, 107 |
| `deploy.ps1` | `steps/03-wsa-install.ps1` | dot-source inside `Invoke-Step` body | WIRED | `deploy.ps1:68` — `. (Join-Path $PSScriptRoot "steps\03-wsa-install.ps1")` |
| `deploy.ps1` | `steps/04-wsa-configure.ps1` | dot-source inside `Invoke-Step` body | WIRED | `deploy.ps1:72` — `. (Join-Path $PSScriptRoot "steps\04-wsa-configure.ps1")` |
| `deploy.ps1` | `steps/05-apk-install.ps1` | dot-source inside `Invoke-Step` body | WIRED | `deploy.ps1:76` — `. (Join-Path $PSScriptRoot "steps\05-apk-install.ps1")` |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| WSAI-01 | 03-01 | WSA installs silently via `Add-AppxPackage -Register` from unpacked directory | SATISFIED | `Invoke-AddAppxPackage` in `steps/03-wsa-install.ps1:28-31`; tested in `WsaInstall.Tests.ps1` ("WSAI-01: calls Invoke-AddAppxPackage exactly once") |
| WSAI-02 | 03-01 | Script suppresses all auto-launched WSA windows after install | SATISFIED | `Stop-WsaWindows` kills `WsaSettings` and `WsaClient` only; `Invoke-Sleep -Seconds 15` before call; tested in 4 It-blocks |
| WSAI-03 | 03-01 | Script waits for WSA initialization via poll-based check, not fixed sleep | SATISFIED | `Invoke-WsaServiceWait` polls `Get-Process WsaService` in a deadline loop; tested in WsaInstall.Tests.ps1 |
| WSAI-04 | 03-01 | Script detects if WSA is already installed and skips reinstall | SATISFIED | `Test-WsaInstalled` returns `$true` on existing package; `Invoke-WsaInstall` returns early; tested in 2 Describe blocks |
| ADBM-01 | 03-02 | Script writes Developer Mode registry key and restarts WSA to apply | SATISFIED | `Set-WsaDeveloperMode` writes `DeveloperMode=1` and calls `Invoke-WsaRestart`; tested in 2 It-blocks |
| ADBM-02 | 03-02 | Script sets WSA to Continuous resource mode (prevents idle termination) | SATISFIED | `Set-WsaDeveloperMode` writes `VMLifeCycleMode=Continuous`; tested in WsaConfigure.Tests.ps1 |
| ADBM-03 | 03-02 | ADB connection uses exponential backoff retry (5 attempts, up to 60s timeout) | SATISFIED | `Connect-Adb` with `MaxAttempts=5`, `BaseDelaySec=5`; delay formula `Min(BaseDelay * 2^(i-1), 60)`; no sleep after last attempt |
| ADBM-04 | 03-02 | ADB connection checks `adb devices` output for `device` status (not exit codes) | SATISFIED | `$devices -match ([regex]::Escape($Endpoint) + '\s+device')` at `steps/04-wsa-configure.ps1:119` |
| ADBM-05 | 03-02 | Script emits clear, single-step manual instruction if ADB probe fails after all retries | SATISFIED | 4 WARN-level lines with "MANUAL ACTION REQUIRED"; `Invoke-WsaConfigure` throws; tested in 2 Describe blocks |
| APKS-01 | 03-03 | Script compares installed APK version before installing (skip if current) | SATISFIED | `Get-InstalledApkVersionCode` queries `pm list packages`; `Invoke-ApkInstall` skips when `$installedVersion -ge 0` |
| APKS-02 | 03-03 | Script auto-detects APK file in the deployment bundle directory | SATISFIED | `Find-ApkFile` uses `Get-ChildItem -Filter "*.apk" -Recurse`; throws with clear message if not found |
| APKS-03 | 03-03 | APK installs via `adb install -r` with success verification | SATISFIED | `Invoke-ApkInstallCommand` calls `adb install -r`; output parsed for "Success" string; throws on failure |

**All 12 required requirement IDs accounted for. No orphaned requirements.**

REQUIREMENTS.md traceability table confirms WSAI-01..04, ADBM-01..05, APKS-01..03 are all marked Complete/Phase 3.

---

## Anti-Patterns Found

No anti-patterns detected in any of the three step files or `deploy.ps1`.

Scan results:
- Zero TODO/FIXME/XXX/HACK/PLACEHOLDER comments in step files or deploy.ps1
- No `return null`, `return {}`, or empty stub bodies
- No console.log-only implementations
- All functions have substantive bodies with real logic
- BARAKA_TEST_MODE guard at bottom of each step file is the correct idempotency pattern, not a stub

---

## Human Verification Required

Two items cannot be verified programmatically and require execution on a real Windows terminal with WSA bundle present.

### 1. End-to-End Deployment Run

**Test:** On a clean Windows 11 Pro terminal with the MagiskOnWSALocal bundle and Baraka APK in the bundle directory, run `powershell.exe -ExecutionPolicy Bypass -File deploy.ps1` as Administrator
**Expected:** All 5 steps complete sequentially (Preflight, VmFeatures, WsaInstall, WsaConfigure, ApkInstall); `deploy.log` shows INFO entries for each step; process exits with code 0; Baraka POS app is visible and launchable in WSA
**Why human:** Cannot simulate Windows AppxPackage registry, real WSA ADB daemon startup, or actual APK launch in this environment

### 2. Idempotent Re-Run

**Test:** After a successful deployment, re-run `deploy.ps1` on the same terminal
**Expected:** All three Phase 3 steps log their "already installed / skipping" messages and complete without error; no re-install of WSA or APK occurs; deploy exits 0
**Why human:** Idempotency depends on real registry guard state (Guard.psm1 + HKLM:\SOFTWARE\Baraka\Deploy) and real AppxPackage presence; cannot mock on this Linux runner

### 3. ADB Manual Fallback Message Clarity

**Test:** Configure WSA developer mode OFF, make ADB unreachable, run `deploy.ps1`
**Expected:** After 5 retry attempts, deploy.log contains the 4-line WARN message block with "MANUAL ACTION REQUIRED" and actionable instructions; process exits with code 20 (EXIT_STEP_FAILED)
**Why human:** Requires a real Windows terminal with WSA in a misconfigured state; the message content is validated by unit tests but usability of the instructions requires human judgment

---

## Gaps Summary

No gaps found. All 12 must-have truths verified, all 7 required artifacts exist at levels 1-3 (exist, substantive, wired), all key links confirmed. All 12 requirement IDs from PLAN frontmatter are satisfied by concrete implementation evidence.

Commit history confirms TDD discipline was maintained: RED commits (04210a4, f10d935, b536831) preceded GREEN commits (4605b96, f8fd81d, 2583246) for each plan, with deploy.ps1 wiring in a separate commit (82350ae). Full suite ended at 89 tests passing per SUMMARY 03-03.

---

_Verified: 2026-03-17_
_Verifier: Claude (gsd-verifier)_
