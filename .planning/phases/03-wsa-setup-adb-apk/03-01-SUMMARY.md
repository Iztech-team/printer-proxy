---
phase: 03-wsa-setup-adb-apk
plan: "01"
subsystem: wsa-install
tags: [powershell, pester, wsa, appx, tdd]

# Dependency graph
requires:
  - phase: 02-vm-features-reboot-resume
    provides: "VM features enabled and patterns for test seams, BARAKA_TEST_MODE guard, Write-Log usage"
provides:
  - "steps/03-wsa-install.ps1 with Test-WsaInstalled, Invoke-AddAppxPackage, Stop-WsaWindows, Invoke-Sleep, Invoke-WsaServiceWait, Invoke-WsaInstall"
  - "tests/WsaInstall.Tests.ps1 with 12 Pester tests covering WSAI-01 through WSAI-04"
affects: [03-02-wsa-configure, 03-03-apk-sideload, deploy.ps1-wiring]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Test seam functions for Add-AppxPackage and Start-Sleep enable cross-platform Pester mocking"
    - "Global function stubs for Windows-only cmdlets before Pester Mock calls"
    - "Should -Invoke Get-Process with ParameterFilter used to verify process targeting without pipeline tracking"
    - "Invoke-Sleep / Invoke-WsaServiceWait seams wrap OS calls for timing control in tests"

key-files:
  created:
    - steps/03-wsa-install.ps1
    - tests/WsaInstall.Tests.ps1
  modified: []

key-decisions:
  - "Track Stop-WsaWindows behavior via Should -Invoke Get-Process ParameterFilter rather than pipeline output capture — pipeline mock parameter binding for Stop-Process is unreliable on Linux"
  - "Invoke-WsaServiceWait emits WARN not exception on timeout — WSA may still initialize, consistent with community-derived polling approach"
  - "WsaService process is explicitly NOT stopped by Stop-WsaWindows — it is the VM itself and must remain running"

patterns-established:
  - "Test seam pattern: wrap Windows-only cmdlets in Invoke-* functions for Pester compatibility on Linux"
  - "Global stubs added in BeforeAll for any cmdlet mocked in per-test Mocks (prevents CommandNotFoundException)"
  - "BARAKA_TEST_MODE guard at bottom of step file prevents auto-execution when dot-sourced from tests"

requirements-completed: [WSAI-01, WSAI-02, WSAI-03, WSAI-04]

# Metrics
duration: 4min
completed: 2026-03-17
---

# Phase 3 Plan 01: WSA Installation Step Summary

**Silent WSA installation step with idempotency, window suppression (kill WsaSettings/WsaClient, not WsaService), and poll-based WsaService init confirmation — all 12 Pester tests green via TDD (RED then GREEN)**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-17T11:09:00Z
- **Completed:** 2026-03-17T11:13:00Z
- **Tasks:** 2 (RED + GREEN)
- **Files modified:** 2

## Accomplishments
- Created `tests/WsaInstall.Tests.ps1` with 12 tests covering all four WSAI requirements (RED phase)
- Created `steps/03-wsa-install.ps1` with 6 exported functions implementing WSAI-01 through WSAI-04 (GREEN phase)
- All 12 WsaInstall tests pass; no regressions in prior 52-test suite (only pre-existing 03-02 RED failure)

## Task Commits

Each task was committed atomically:

1. **Task 1: RED — WsaInstall.Tests.ps1 with failing tests** - `04210a4` (test)
2. **Task 2: GREEN — steps/03-wsa-install.ps1 passing all tests** - `4605b96` (feat)

_Note: TDD tasks have two commits (test RED → feat GREEN). Test file was updated in GREEN commit to fix Stop-WsaWindows assertions._

## Files Created/Modified
- `steps/03-wsa-install.ps1` - WSA installation orchestrator with idempotency check, silent Add-AppxPackage, window suppression, and poll-based init wait
- `tests/WsaInstall.Tests.ps1` - 12 Pester unit tests covering WSAI-01 through WSAI-04

## Decisions Made
- Track `Stop-WsaWindows` behavior via `Should -Invoke Get-Process -ParameterFilter` rather than pipeline output capture from `Stop-Process`. Pipeline mock parameter binding for `Stop-Process` on Linux doesn't populate `$InputObject` reliably.
- `Invoke-WsaServiceWait` emits `WARN` not an exception on timeout — consistent with RESEARCH.md finding that WSA may still initialize after the polling window.
- `WsaService` is explicitly excluded from `Stop-WsaWindows` — it is the Android VM itself, not a UI window.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed Stop-WsaWindows test assertions in RED phase**
- **Found during:** Task 2 (GREEN — running tests)
- **Issue:** Original `Stop-WsaWindows` tests in RED phase tracked stopped processes by capturing pipeline output into `$StoppedProcessNames` via `Stop-Process` mock's `$InputObject` parameter. On Linux, Pester does not populate pipeline-bound parameters in mocks the same way — `$InputObject` was always `$null`.
- **Fix:** Rewrote test assertions to use `Should -Invoke Get-Process -ParameterFilter { $Name -eq 'WsaSettings' }` and `Should -Invoke Stop-Process -Times 2` instead of capturing process names. Still fully verifies WSAI-02 behavior.
- **Files modified:** tests/WsaInstall.Tests.ps1
- **Verification:** All 12 tests pass after fix
- **Committed in:** `4605b96` (Task 2 GREEN commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug in test assertions)
**Impact on plan:** Auto-fix necessary for cross-platform Pester compatibility. No scope creep. Behavioral coverage unchanged.

## Issues Encountered
- `Stop-Process` mock pipeline binding on Linux: `$InputObject` was never populated when piping from `Get-Process` mock. Resolved by switching to `Should -Invoke` with `ParameterFilter` approach — consistent with how `VmFeatures.Tests.ps1` verifies similar patterns.

## Next Phase Readiness
- `steps/03-wsa-install.ps1` is ready to be wired into `deploy.ps1` via `Invoke-Step` in plan 03-03
- Pattern for test seams (Invoke-AddAppxPackage, Invoke-Sleep, Invoke-WsaServiceWait) established and available for plan 03-02 (WSA configure) to follow
- Pre-existing 03-02 RED tests in `WsaConfigure.Tests.ps1` will pass once plan 03-02 implementation is executed

---
*Phase: 03-wsa-setup-adb-apk*
*Completed: 2026-03-17*

## Self-Check: PASSED

- FOUND: steps/03-wsa-install.ps1
- FOUND: tests/WsaInstall.Tests.ps1
- FOUND: .planning/phases/03-wsa-setup-adb-apk/03-01-SUMMARY.md
- FOUND: commit 04210a4 (RED phase test)
- FOUND: commit 4605b96 (GREEN phase implementation)
