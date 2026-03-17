---
phase: 03-wsa-setup-adb-apk
plan: 02
subsystem: infra
tags: [powershell, pester, wsa, adb, registry, tdd]

# Dependency graph
requires:
  - phase: 03-wsa-setup-adb-apk/03-01
    provides: WSA installation step (03-wsa-install.ps1) and WsaInstall.Tests.ps1 pattern
  - phase: 02-vm-features-reboot-resume
    provides: VmFeatures.Tests.ps1 pattern for mocking Windows-only cmdlets

provides:
  - steps/04-wsa-configure.ps1 with Set-WsaDeveloperMode, Invoke-WsaRestart, Connect-Adb, Invoke-AdbCommand, Invoke-Sleep, Invoke-WsaConfigure
  - tests/WsaConfigure.Tests.ps1 with 16 Pester tests covering ADBM-01 through ADBM-05
  - Exponential backoff ADB retry pattern with manual fallback when all retries exhausted
  - Guard flag protection via throw on ADB failure

affects: [03-wsa-setup-adb-apk/03-03, deploy.ps1 orchestration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Exponential backoff retry with no sleep after last attempt
    - ADB success via device-status regex parsing (not exit codes)
    - Manual fallback message emitted on exhausted retries, then $false returned
    - Invoke-WsaConfigure throws on $false to prevent Guard.psm1 done flag

key-files:
  created:
    - steps/04-wsa-configure.ps1
    - tests/WsaConfigure.Tests.ps1
  modified: []

key-decisions:
  - "Remove -PropertyType DWord from Set-ItemProperty call: registry type auto-inferred; -PropertyType is not a standard parameter on all PS hosts"
  - "No Invoke-Sleep call after last retry attempt: sleep only between attempts, not after final failure"
  - "Use string interpolation for WsaClient.exe path instead of Join-Path to avoid Windows drive letter failure on Linux test runners"
  - "Mock InstallLocation returns /mock/wsa (Linux path) instead of C:\\ path to avoid Join-Path drive exception on test platform"

patterns-established:
  - "Exponential backoff: delaySec = [math]::Min(BaseDelaySec * 2^(i-1), 60); skip sleep on final iteration"
  - "ADB device check regex: [regex]::Escape(endpoint) + '\\s+device' matched against adb devices output"
  - "Manual fallback: 4 WARN-level log lines with MANUAL ACTION REQUIRED before returning $false"
  - "Guard protection: main orchestrator throws when connection helper returns $false"

requirements-completed: [ADBM-01, ADBM-02, ADBM-03, ADBM-04, ADBM-05]

# Metrics
duration: 5min
completed: 2026-03-17
---

# Phase 3 Plan 02: WSA Configure + ADB Connection Summary

**WSA developer mode registry configuration and ADB connection with 5-attempt exponential backoff (5/10/20/40/60s) and WARN-level manual fallback message when all retries fail**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-17T11:09:07Z
- **Completed:** 2026-03-17T11:13:56Z
- **Tasks:** 2 (RED + GREEN TDD)
- **Files modified:** 2

## Accomplishments

- Set-WsaDeveloperMode writes DeveloperMode=1 (ADBM-01) and VMLifeCycleMode=Continuous (ADBM-02) to correct HKCU registry paths with path auto-creation
- Connect-Adb implements 5-attempt exponential backoff (BaseDelaySec * 2^(i-1), capped at 60s), no sleep after last attempt (ADBM-03)
- ADB success determined exclusively by regex match on `adb devices` output for `endpoint\s+device` pattern, not exit codes (ADBM-04)
- Invoke-WsaConfigure throws when Connect-Adb returns $false, preventing Guard.psm1 from setting the done flag so re-run works (ADBM-05)
- Full suite: 80 tests passing, zero regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: RED — WsaConfigure.Tests.ps1 with failing tests** - `f10d935` (test)
2. **Task 2: GREEN — steps/04-wsa-configure.ps1 passing all tests** - `f8fd81d` (feat)

_Note: TDD tasks — test commit (RED) then implementation commit (GREEN)_

## Files Created/Modified

- `tests/WsaConfigure.Tests.ps1` — 16 Pester tests covering all 5 ADBM requirements
- `steps/04-wsa-configure.ps1` — WSA developer mode config + ADB retry with manual fallback

## Decisions Made

- Removed `-PropertyType DWord` from `Set-ItemProperty`: the parameter is not universally available across PS hosts and the registry infers type from value
- No sleep after final retry attempt: spec says delays are between attempts, the loop only sleeps when `$i -lt $MaxAttempts`
- Mock `Get-AppxPackage` returns a Linux-friendly path `/mock/wsa` instead of a Windows `C:\...` path to prevent `Join-Path` from throwing a drive-not-found error on Linux test runners
- Used string interpolation `"$($wsaPkg.InstallLocation)\WsaClient\WsaClient.exe"` for WsaClient.exe path construction to avoid `Join-Path` cross-platform issues

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed unsupported -PropertyType parameter from Set-ItemProperty**
- **Found during:** Task 2 (GREEN — first test run)
- **Issue:** `Set-ItemProperty -PropertyType DWord` caused `ParameterBindingException` because the Pester mock and the cmdlet on Linux don't expose that parameter
- **Fix:** Removed `-PropertyType DWord`; registry type is inferred from the .NET value (Int32 → DWord on Windows)
- **Files modified:** steps/04-wsa-configure.ps1
- **Verification:** 16 tests pass after fix
- **Committed in:** f8fd81d (Task 2 commit)

**2. [Rule 1 - Bug] Fixed cross-platform path construction for WsaClient.exe**
- **Found during:** Task 2 (GREEN — first test run)
- **Issue:** `Join-Path $wsaPkg.InstallLocation "WsaClient\WsaClient.exe"` threw "Cannot find drive 'C'" on Linux when mock returned a Windows-style path
- **Fix:** Changed to string interpolation; updated test mock to return a Linux-friendly path `/mock/wsa`
- **Files modified:** steps/04-wsa-configure.ps1, tests/WsaConfigure.Tests.ps1
- **Verification:** Invoke-WsaRestart tests pass; Start-Process mock receives non-empty FilePath
- **Committed in:** f8fd81d (Task 2 commit)

**3. [Rule 1 - Bug] Fixed sleep-after-last-attempt: exponential backoff only between attempts**
- **Found during:** Task 2 (GREEN — first test run)
- **Issue:** Loop called `Invoke-Sleep` on every failure including the last, giving 3 sleep calls for MaxAttempts=3 when test expected 2
- **Fix:** Wrapped sleep in `if ($i -lt $MaxAttempts)` guard
- **Files modified:** steps/04-wsa-configure.ps1
- **Verification:** ADBM-03 delay test expects exactly 2 sleep calls for MaxAttempts=3; now passes
- **Committed in:** f8fd81d (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (all Rule 1 - Bug)
**Impact on plan:** All three fixes were necessary for correct cross-platform test execution. No scope creep.

## Issues Encountered

None beyond the three auto-fixed bugs above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- steps/04-wsa-configure.ps1 complete and tested; deploy.ps1 can dot-source it inside `Invoke-Step "WsaConfigure"`
- Ready for Phase 3 Plan 03: APK sideload step (05-apk-sideload.ps1)
- ADB binary path pattern `Join-Path $PSScriptRoot '..\adb\adb.exe'` established; Plan 03 should reuse same pattern

---
*Phase: 03-wsa-setup-adb-apk*
*Completed: 2026-03-17*
