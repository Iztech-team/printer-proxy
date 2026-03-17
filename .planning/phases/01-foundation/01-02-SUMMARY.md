---
phase: 01-foundation
plan: 02
subsystem: infra
tags: [powershell, pester, preflight, exit-codes, deployment, validation]

requires:
  - phase: 01-foundation/01-01
    provides: "lib/Log.psm1 (Write-Log, Initialize-Log), lib/State.psm1, lib/Guard.psm1 (Invoke-Step)"

provides:
  - "deploy.ps1 — entry point with exit code taxonomy, module imports, log init, and step dispatch"
  - "steps/01-preflight.ps1 — five pre-flight checks: OS edition, admin, virtualization, disk space, ADB binary"
  - "tests/ExitCodes.Tests.ps1 — 6 structural tests for deploy.ps1"
  - "tests/Preflight.Tests.ps1 — 13 Pester tests for all five preflight checks (child-process exit-code testing)"

affects:
  - all subsequent phases (every step is dispatched via deploy.ps1's Invoke-Step pattern)
  - 01-03 and beyond (steps/02-*.ps1 files follow same pattern as 01-preflight.ps1)

tech-stack:
  added: []
  patterns:
    - "Test seam pattern: mock parameters (-MockSkuOverride, -MockIsAdmin, etc.) injected into check functions for cross-platform testing without real system calls"
    - "BARAKA_TEST_MODE env-var guard: prevents auto-run Invoke-Preflight when dot-sourced from tests"
    - "Child-process exit-code testing: functions that call exit $EXIT_* are tested via Start-Process + ExitCode to avoid terminating the test runner"
    - "Belt-and-suspenders OS check: Caption-contains-Home check AND SKU allowlist — handles Win10 and Win11 Home variants"
    - "WARN-not-ERROR on virtualization query failure (Pitfall 2): false negatives on some hardware are not blocking"

key-files:
  created:
    - deploy.ps1
    - steps/01-preflight.ps1
    - tests/ExitCodes.Tests.ps1
    - tests/Preflight.Tests.ps1
  modified: []

key-decisions:
  - "Test seams via parameters chosen over Pester mocks for exit-code testing: functions that call exit cannot be mocked at the PS level without a subprocess boundary. Mock parameters keep production code clean and make seams explicit."
  - "BARAKA_TEST_MODE guard in 01-preflight.ps1: prevents the bottom-of-file Invoke-Preflight call from firing when dot-sourced in tests. Production deploy.ps1 never sets this variable."
  - "Child-process temp-script approach for exit-code tests: writes a .ps1 file to disk and runs it via Start-Process -File, avoiding all quoting/escaping issues in -Command strings."
  - "WARN-not-ERROR for Get-ComputerInfo failure per RESEARCH.md Pitfall 2: some hardware does not expose virtualization info correctly; treating this as a hard failure would block valid terminals."

patterns-established:
  - "Pattern: each step file is self-contained with test seams; dot-sourced by deploy.ps1 Invoke-Step body"
  - "Pattern: BARAKA_TEST_MODE=1 suppresses auto-run code in step files during test execution"
  - "Pattern: exit-code functions tested via Start-Process subprocess, not Pester process-in-process mocks"

requirements-completed: [CORE-04, CORE-05]

duration: 3min
completed: 2026-03-17
---

# Phase 1 Plan 2: Entry Point and Pre-flight Checks Summary

**deploy.ps1 entry point with eight exit-code constants and 01-preflight.ps1 implementing five pre-flight checks (OS edition, admin privilege, BIOS virtualization, disk space, ADB binary) — 19 new Pester tests, full suite 37/37 green**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-17T09:55:31Z
- **Completed:** 2026-03-17T09:58:26Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- deploy.ps1: `#Requires -Version 5.1`, `$ErrorActionPreference = "Stop"`, eight exit code constants (0, 10-14, 20, 99), Import-Module for Log/State/Guard, Initialize-Log before step dispatch, top-level try/catch with `$EXIT_UNKNOWN`
- steps/01-preflight.ps1: five check functions each with test seams (mock parameters) and correct exit codes on failure; belt-and-suspenders OS check rejects "Home" in Caption regardless of SKU; WARN-not-ERROR on virtualization query failure; `BARAKA_TEST_MODE` guard prevents auto-execution in tests
- 6 structural tests (ExitCodes.Tests.ps1) verify deploy.ps1 without executing it — parse as text
- 13 unit tests (Preflight.Tests.ps1) cover all pass/fail paths using child-process exit-code testing pattern
- Full test suite: 37 tests across 5 files, all green

## Task Commits

Each task was committed atomically:

1. **Task 1: Create deploy.ps1 entry point with exit code taxonomy** - `0820e68` (feat)
2. **Task 2: Create steps/01-preflight.ps1 — five pre-flight checks** - `ba011b2` (feat)

## Files Created/Modified

- `deploy.ps1` — Entry point: #Requires, EAP=Stop, exit code constants, module imports, log init, Invoke-Step dispatch for Preflight
- `steps/01-preflight.ps1` — Five check functions (Test-OsEdition, Test-AdminPrivilege, Test-VirtualizationCapability, Test-DiskSpace, Test-AdbBinary) + Invoke-Preflight orchestrator; BARAKA_TEST_MODE guard
- `tests/ExitCodes.Tests.ps1` — 6 structural/text-pattern tests for deploy.ps1
- `tests/Preflight.Tests.ps1` — 13 Pester tests using child-process exit-code testing pattern

## Decisions Made

- **Test seams via parameters:** Functions that call `exit $EXIT_*` cannot be mocked at the PowerShell level without a subprocess boundary. Mock parameters (-MockSkuOverride, -MockIsAdmin, etc.) make seams explicit in the function signature and keep production code clean.
- **BARAKA_TEST_MODE guard:** The `Invoke-Preflight` call at the bottom of 01-preflight.ps1 runs when dot-sourced in production (deploy.ps1 sets no env var). Setting `$env:BARAKA_TEST_MODE = '1'` in test scripts suppresses this auto-run without touching Guard or deploy.ps1.
- **Temp-script child-process approach:** Writing the test scaffold to a .ps1 file avoids all quoting/escaping complexity of `-Command` string construction. `Start-Process -File` returns a clean exit code.
- **WARN not ERROR on Get-ComputerInfo failure:** RESEARCH.md Pitfall 2 notes that some hardware doesn't expose virtualization info. Treating query failure as a hard block would prevent deployment on valid terminals. Definitive `$false` still exits with code 12.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] BARAKA_TEST_MODE guard added to prevent auto-execution during dot-source**
- **Found during:** Task 2 (Preflight.Tests.ps1 RED phase)
- **Issue:** 01-preflight.ps1 calls `Invoke-Preflight` at the bottom so it runs when dot-sourced by deploy.ps1. When tests dot-source it to load the functions, the bare `Invoke-Preflight` call fires immediately with no mock parameters and tries real system calls (Get-WmiObject not available on Linux).
- **Fix:** Wrapped bottom-of-file call: `if (-not $env:BARAKA_TEST_MODE) { Invoke-Preflight }`. Test scaffold sets `$env:BARAKA_TEST_MODE = '1'` before dot-sourcing.
- **Files modified:** steps/01-preflight.ps1, tests/Preflight.Tests.ps1
- **Verification:** All 13 Preflight tests pass; production deploy.ps1 never sets BARAKA_TEST_MODE so production behavior is unchanged.
- **Committed in:** ba011b2 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking — test isolation)
**Impact on plan:** Auto-fix is a strict improvement: production path unchanged, test isolation is clean and portable. No scope creep.

## Issues Encountered

- Get-WmiObject is not available on PowerShell 7 on Linux (deprecated). The mock-parameter test seam design means 01-preflight.ps1 never reaches the WMI call during tests — this is by design. On the actual Windows deployment target, PS 5.1 has Get-WmiObject available.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- deploy.ps1 and 01-preflight.ps1 are complete and tested; subsequent phases add new step files and register them in deploy.ps1's try block under `Invoke-Step`
- The `BARAKA_TEST_MODE` pattern and child-process exit-code testing pattern are established for all future preflight-style steps
- Full test suite (37 tests) is green and cross-platform — CI can run on Linux without Windows registry or WMI

---
*Phase: 01-foundation*
*Completed: 2026-03-17*
