---
phase: 02-vm-features-reboot-resume
plan: 01
subsystem: deployment
tags: [powershell, pester, windows-features, scheduled-task, reboot-resume, hyper-v, port-reservation]

requires:
  - phase: 01-foundation/01-01
    provides: "lib/Log.psm1, lib/State.psm1 (Set-DeployState/Get-DeployState), lib/Guard.psm1 (Invoke-Step)"
  - phase: 01-foundation/01-02
    provides: "deploy.ps1 (entry point), steps/01-preflight.ps1 (BARAKA_TEST_MODE pattern)"

provides:
  - "steps/02-vm-features.ps1 — Test-VmFeaturesEnabled, Invoke-NetshPortReserve, Register-ResumeTask, Invoke-SystemReboot, Invoke-VmFeatures"
  - "tests/VmFeatures.Tests.ps1 — 15 Pester tests covering all 7 requirements (VMFT-01/02/03, BOOT-01/02/03/04)"
  - "deploy.ps1 (extended) — -ResumeAfterReboot parameter, resume routing, VmFeatures step, finally cleanup"

affects:
  - Phase 3 (WSA install) — VM features must be enabled and reboot completed before WSA can run
  - All subsequent deploys — finally block ensures BarakaDeploy-Resume task is always cleaned up

tech-stack:
  added:
    - Enable-WindowsOptionalFeature (DISM module, built-in PS 5.1) — feature enablement
    - Get-WindowsOptionalFeature (DISM module) — idempotency state check
    - Register-ScheduledTask / Unregister-ScheduledTask (ScheduledTasks module) — resume task lifecycle
    - netsh int ipv4 add excludedportrange — port 58526 reservation before Hyper-V activation
  patterns:
    - "Invoke-SystemReboot test seam: wraps Restart-Computer -Force for cross-platform mock compatibility (no ParameterBindingException on Linux)"
    - "Global stubs in BeforeAll: Windows-only cmdlets stubbed before Pester Mock to avoid CommandNotFoundException on Linux"
    - "Call-sequence array: List<string> tracks mock call order for BOOT-02 ordering assertion"
    - "Nested try/catch/finally: inner try/catch for step failures (EXIT_STEP_FAILED), outer catch for unexpected errors (EXIT_UNKNOWN), finally for task cleanup"

key-files:
  created:
    - steps/02-vm-features.ps1
    - tests/VmFeatures.Tests.ps1
  modified:
    - deploy.ps1

key-decisions:
  - "Invoke-SystemReboot test seam: rather than mocking Restart-Computer directly (which causes ParameterBindingException in Pester on Linux for switches like -Force), wrap it in Invoke-SystemReboot. Tests mock the wrapper. Production path unchanged on Windows."
  - "Global command stubs in BeforeAll: Windows-only cmdlets (Get-WindowsOptionalFeature, Enable-WindowsOptionalFeature, Register-ScheduledTask, etc.) are stubbed with function global:CmdletName before dot-sourcing the step file. Pester then intercepts at the stub level via Mock."
  - "Nested try/catch rather than single try/catch/finally: fixes pre-existing ExitCodes.Tests.ps1 failure where deploy.ps1 had no EXIT_UNKNOWN path. The outer catch handles unexpected errors (module import, log init), inner catch handles step failures."

metrics:
  duration: 9min
  completed: 2026-03-17
  tasks: 3
  files_modified: 3
---

# Phase 2 Plan 1: VM Features + Reboot Resume Summary

**VirtualMachinePlatform and HypervisorPlatform enablement with port 58526 reservation, scheduled-task reboot-resume at HIGHEST elevation, and idempotent re-run safety — 15 new Pester tests, full suite 52/52 green**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-17T10:25:03Z
- **Completed:** 2026-03-17T10:34:03Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments

- steps/02-vm-features.ps1: `Test-VmFeaturesEnabled` returns `$true` when both features are `Enabled` (VMFT-02 idempotency); `Invoke-NetshPortReserve` wraps netsh port 58526 reservation as a test seam (BOOT-02); `Register-ResumeTask` creates `BarakaDeploy-Resume` scheduled task with `-RunLevel Highest` and `-AtStartup` trigger (BOOT-01); `Invoke-SystemReboot` test seam wraps `Restart-Computer -Force`; `Invoke-VmFeatures` orchestrates the full VMFT-01/02/03 + BOOT-01/02/03 sequence; `BARAKA_TEST_MODE` guard prevents auto-execution in tests
- deploy.ps1: `param([switch]$ResumeAfterReboot)` added; resume routing reads `ResumeStep` registry key on resume; Preflight skipped on resume; `Invoke-Step VmFeatures` step added; `finally` block unconditionally calls `Unregister-ScheduledTask BarakaDeploy-Resume` (BOOT-04); nested try/catch adds `EXIT_UNKNOWN` path for unexpected errors
- tests/VmFeatures.Tests.ps1: 15 tests covering all 7 requirements using Pester module-scope mocks for registry (State module) and global stubs for Windows-only cmdlets; call-sequence tracking array verifies BOOT-02 ordering (port before reboot); BOOT-04 verified via structural deploy.ps1 text check
- Full test suite: 52 tests across 6 files, all green

## Task Commits

Each task was committed atomically:

1. **Task 1: VmFeatures.Tests.ps1 — RED phase (15 failing tests)** - `abfa601` (test)
2. **Task 2: steps/02-vm-features.ps1 — GREEN phase (14/15 tests pass)** - `d8bdfad` (feat)
3. **Task 3: deploy.ps1 — ResumeAfterReboot, VmFeatures step, finally cleanup** - `585e7fb` (feat)

## Files Created/Modified

- `steps/02-vm-features.ps1` — Five functions: Test-VmFeaturesEnabled, Invoke-SystemReboot, Invoke-NetshPortReserve, Register-ResumeTask, Invoke-VmFeatures; BARAKA_TEST_MODE guard
- `tests/VmFeatures.Tests.ps1` — 15 tests (3 for Test-VmFeaturesEnabled, 3 for already-enabled path, 3 for no-restart path, 5 for restart-required path, 1 for BOOT-04 structural); global stubs for cross-platform mock compatibility
- `deploy.ps1` — param block, resume routing, Preflight skip on resume, VmFeatures Invoke-Step, nested try/catch for EXIT_UNKNOWN, finally block for BarakaDeploy-Resume cleanup

## Decisions Made

- **Invoke-SystemReboot test seam:** Pester on Linux throws `ParameterBindingException: A parameter cannot be found that matches parameter name 'Force'` when mocking a cmdlet via a global stub function that uses `[CmdletBinding()]`. The cleanest fix is a thin wrapper `Invoke-SystemReboot` that calls `Restart-Computer -Force`. Tests mock the wrapper with a parameter-free body. Production behavior on Windows is unchanged.

- **Global command stubs before dot-source:** Windows-only cmdlets like `Get-WindowsOptionalFeature` don't exist on the Linux CI runner. Without a stub, `Mock Get-WindowsOptionalFeature` throws `CommandNotFoundException` even before any test runs. Stubbing with `function global:CmdletName {}` in `BeforeAll` lets Pester intercept the call at the global scope, identical to how it intercepts real cmdlets on Windows.

- **Nested try/catch for EXIT_UNKNOWN:** The pre-existing `ExitCodes.Tests.ps1` test asserted `deploy.ps1` contained `exit $EXIT_UNKNOWN`, but the original Phase 1 deploy.ps1 never had this path. Rather than weakening the test, we fixed the implementation: an outer `catch` block around the entire step-dispatch block handles unexpected errors (module import failures, log initialization failures) with `EXIT_UNKNOWN`. The inner `catch` handles step failures with `EXIT_STEP_FAILED` as before.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Pre-existing ExitCodes test failure: deploy.ps1 missing EXIT_UNKNOWN path**
- **Found during:** Task 3 (full suite run)
- **Issue:** `tests/ExitCodes.Tests.ps1` line 49 asserted `$script:DeployContent | Should -Match 'exit\s+\$EXIT_UNKNOWN'`. The original Phase 1 deploy.ps1 had `$EXIT_UNKNOWN = 99` defined but never used it — the outer catch only called `exit $EXIT_STEP_FAILED`. The test was already failing before Task 3 started.
- **Fix:** Added nested try/catch structure: inner catch handles `EXIT_STEP_FAILED` (step failures), outer catch handles `EXIT_UNKNOWN` (unexpected errors like module import failure). Finally block remains at outermost level.
- **Files modified:** deploy.ps1
- **Verification:** All 52 tests pass; ExitCodes.Tests.ps1 5/5 green (was 5/6 before fix)
- **Committed in:** 585e7fb (Task 3 commit)

**2. [Rule 3 - Blocking] Cross-platform Pester mock incompatibility for Windows-only cmdlets**
- **Found during:** Task 2 (GREEN phase verification on Linux)
- **Issue 1:** `Get-WindowsOptionalFeature` does not exist on Linux. `Mock Get-WindowsOptionalFeature` throws `CommandNotFoundException` because Pester cannot create a mock for a non-existent command.
- **Fix 1:** Added `if (-not (Get-Command ...)) { function global:CmdletName {...} }` stubs in `BeforeAll` for all 8 Windows-only cmdlets. Pester then intercepts these global stubs cleanly.
- **Issue 2:** Even with a stub, `Mock Restart-Computer { ... }` created a Pester wrapper without the `-Force` switch, causing `ParameterBindingException` when the step called `Restart-Computer -Force`.
- **Fix 2:** Introduced `Invoke-SystemReboot` as an explicit test seam in `steps/02-vm-features.ps1` (following the same pattern as `Invoke-NetshPortReserve`). The step calls `Invoke-SystemReboot` instead of `Restart-Computer -Force` directly. Tests mock `Invoke-SystemReboot` with a parameter-free body.
- **Files modified:** steps/02-vm-features.ps1, tests/VmFeatures.Tests.ps1
- **Verification:** 15/15 VmFeatures tests pass on Linux
- **Committed in:** d8bdfad (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 bug fix, 1 blocking cross-platform compatibility)
**Impact on plan:** Both fixes are strict improvements. The EXIT_UNKNOWN fix makes the error taxonomy complete. The Invoke-SystemReboot seam is consistent with the established test-seam pattern from 01-preflight.ps1 and makes the test seams explicit and documentable. No scope creep.

## Issues Encountered

- PowerShell's Pester mock framework creates internal wrapper functions that don't automatically inherit the parameter signatures of the original command stubs. This is a known cross-platform behavior difference — on real Windows, the cmdlets have their own parameter metadata and Pester can consult it. On Linux, the stubs need to be more carefully structured or test seams need to be used.

## User Setup Required

None - no external service configuration required. All code is PowerShell targeting Windows deployment terminals.

## Next Phase Readiness

- steps/02-vm-features.ps1 is complete and tested; Phase 3 (WSA install) can call `Invoke-Step VmFeatures` which will be a fast no-op on already-configured machines
- deploy.ps1 is ready for Phase 3 to add new steps after the VmFeatures Invoke-Step call
- The `Invoke-SystemReboot` test seam pattern is now established and can be reused in any step that needs to trigger a system reboot
- Full test suite (52 tests) is green and cross-platform

## Self-Check: PASSED

All created files exist on disk. All task commits verified in git log.

- steps/02-vm-features.ps1: FOUND
- tests/VmFeatures.Tests.ps1: FOUND
- .planning/phases/02-vm-features-reboot-resume/02-01-SUMMARY.md: FOUND
- Commit abfa601 (test RED): FOUND
- Commit d8bdfad (feat GREEN): FOUND
- Commit 585e7fb (feat deploy.ps1): FOUND

---
*Phase: 02-vm-features-reboot-resume*
*Completed: 2026-03-17*
