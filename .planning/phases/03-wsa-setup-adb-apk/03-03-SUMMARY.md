---
phase: 03-wsa-setup-adb-apk
plan: "03"
subsystem: apk-install
tags: [tdd, apk, adb, deploy-wiring]
dependency_graph:
  requires: [03-01, 03-02]
  provides: [apk-auto-detect, apk-skip-if-installed, apk-install-verify, deploy-phase3-wiring]
  affects: [deploy.ps1, steps/05-apk-install.ps1]
tech_stack:
  added: []
  patterns: [test-seam-via-function, baraka-test-mode-guard, pester-mock-tdd]
key_files:
  created:
    - tests/ApkInstall.Tests.ps1
    - steps/05-apk-install.ps1
  modified:
    - deploy.ps1
decisions:
  - "Invoke-ApkInstallCommand is a test seam (not an alias of Invoke-AdbCommand) to allow targeted mocking of install output without affecting pm-list mocks in the same test"
  - "Get-InstalledApkVersionCode returns 1/not-version because aapt is unavailable; any installed instance is treated as current — no forced upgrades without explicit version comparison"
metrics:
  duration: 2min
  completed: 2026-03-17
  tasks_completed: 3
  files_changed: 3
---

# Phase 03 Plan 03: APK Installation Step + deploy.ps1 Wiring Summary

**One-liner:** APK auto-detection from bundle dir with pm-list skip-if-installed check, adb install -r Success verification, and full Phase 3 step sequence wired into deploy.ps1.

## What Was Built

### steps/05-apk-install.ps1
- `Find-ApkFile` — `Get-ChildItem -Filter "*.apk" -Recurse`, throws if none found
- `Get-InstalledApkVersionCode` — queries `adb shell pm list packages`, returns 1 (present) or -1 (absent)
- `Invoke-ApkInstallCommand` — test seam wrapping `adb install -r $ApkPath`
- `Invoke-ApkInstall` — orchestrates detect -> skip-or-install -> verify "Success" string -> post-install log

### tests/ApkInstall.Tests.ps1
Nine tests covering APKS-01, APKS-02, APKS-03:
- APKS-02: Find-ApkFile found/not-found paths
- APKS-01: Get-InstalledApkVersionCode with package absent/present
- APKS-01: Invoke-ApkInstall skip path + "already installed" log
- APKS-03: Fresh install success — Invoke-ApkInstallCommand called once
- APKS-03: Fresh install success — logs success message
- APKS-03: Install failure — throws when output lacks "Success"

### deploy.ps1
Added three Invoke-Step calls after VmFeatures block:
```
Preflight -> VmFeatures -> WsaInstall -> WsaConfigure -> ApkInstall
```

## TDD Phases

| Phase | Commit | Outcome |
|-------|--------|---------|
| RED | b536831 | 9 tests fail (step file absent) |
| GREEN | 2583246 | 9/9 pass |
| WIRE | 82350ae | 89/89 full suite pass |

## Verification

- `grep "Invoke-Step" deploy.ps1` — 5 calls in correct order
- Full suite: **89 tests, 0 failures**

## Deviations from Plan

None — plan executed exactly as written.

## Self-Check: PASSED

- steps/05-apk-install.ps1: FOUND
- tests/ApkInstall.Tests.ps1: FOUND
- deploy.ps1 modified: FOUND
- Commit b536831 (RED): FOUND
- Commit 2583246 (GREEN): FOUND
- Commit 82350ae (WIRE): FOUND
