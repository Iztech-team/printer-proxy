---
phase: 01-foundation
verified: 2026-03-17T00:00:00Z
status: gaps_found
score: 10/11 must-haves verified
re_verification: false
gaps:
  - truth: "Script exits with code 20 when a step throws an unhandled exception"
    status: failed
    reason: "deploy.ps1 top-level catch block exits with $EXIT_UNKNOWN (99), not $EXIT_STEP_FAILED (20). $EXIT_STEP_FAILED is defined but never referenced in any exit path."
    artifacts:
      - path: "deploy.ps1"
        issue: "catch block on line 46-49 calls `exit $EXIT_UNKNOWN` (99). $EXIT_STEP_FAILED (20) is defined on line 17 but unused throughout the file."
    missing:
      - "Either use $EXIT_STEP_FAILED (20) in the top-level catch instead of $EXIT_UNKNOWN (99), OR remove the misleading truth from must_haves and document that code 20 is reserved for future step-level re-throw usage and code 99 is the current catch-all"
---

# Phase 1: Foundation Verification Report

**Phase Goal:** IT can invoke the deployment script on any terminal and it validates prerequisites, logs everything, and fails fast with a clear message before touching the system
**Verified:** 2026-03-17
**Status:** gaps_found
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

The four ROADMAP.md Success Criteria plus the must_haves truths from both PLANs are used as the verification contract.

**ROADMAP Success Criteria:**

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| SC-1 | Script exits immediately with clear diagnostic if OS edition, admin, virtualization, disk space, or ADB binary are missing | VERIFIED | steps/01-preflight.ps1: five check functions each call `exit $EXIT_*` with a `Write-Log ERROR` message before any system mutation |
| SC-2 | Every mutating call is wrapped in try/catch and all output including errors appears in a timestamped deploy.log | VERIFIED | deploy.ps1 wraps all step dispatch in try/catch; Guard.psm1 wraps every body execution; Log.psm1 writes `[$timestamp] [$Level]` format to file + console |
| SC-3 | Re-running after failure replays only steps that haven't completed (registry guards prevent double execution) | VERIFIED | Guard.psm1 Invoke-Step: checks `Get-DeployState "$StepName-Done"` before executing; skips with "Already complete" log if flag is 1; only sets flag after success |
| SC-4 | Script exits with non-zero code matching the failure category; exit 0 reserved for full success only | VERIFIED | deploy.ps1 defines exit code taxonomy (10-14, 20, 99); all preflight failures exit with category codes; `exit $EXIT_SUCCESS` only fires after all steps complete |

**Plan 01-01 must_haves truths:**

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 1 | Write-Log writes timestamped, levelled lines to both deploy.log and console | VERIFIED | lib/Log.psm1 lines 52-63: formats `[$timestamp] [$Level] $Message`, calls Add-Content (file) and Write-Host (console) |
| 2 | Invoke-Step skips a step when its registry flag is already set | VERIFIED | lib/Guard.psm1 lines 36-39: checks Get-DeployState for `$StepName-Done` == 1; returns early with log message |
| 3 | Invoke-Step sets the registry flag after successful execution | VERIFIED | lib/Guard.psm1 line 51: `Set-DeployState -Name "$StepName-Done" -Value 1` after `& $Body` completes without throw |
| 4 | Every module sets $ErrorActionPreference = Stop internally | VERIFIED | Log.psm1 line 3, State.psm1 line 3, Guard.psm1 line 3 all set `$ErrorActionPreference = "Stop"` at module scope |
| 5 | Guard.psm1 creates the HKLM:\SOFTWARE\Baraka\Deploy registry path if missing | VERIFIED | State.psm1 Set-DeployState lines 71-73: `if (-not (Test-Path $script:RegBase)) { New-Item -Path $script:RegBase -Force }` — Guard routes through State helpers |

**Plan 01-02 must_haves truths:**

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 6 | Script exits with code 10 if OS edition is not Pro/Enterprise | VERIFIED | steps/01-preflight.ps1 Test-OsEdition: Caption-contains-"Home" check + SKU allowlist; both paths call `exit $EXIT_OS_EDITION` |
| 7 | Script exits with code 11 if not running as Administrator | VERIFIED | steps/01-preflight.ps1 Test-AdminPrivilege line 74: `exit $EXIT_NOT_ADMIN` |
| 8 | Script exits with code 12 if BIOS virtualization is disabled | VERIFIED | steps/01-preflight.ps1 Test-VirtualizationCapability line 111: `exit $EXIT_NO_VIRT` when `$virtEnabled -eq $false` |
| 9 | Script exits with code 13 if disk space is below 12GB | VERIFIED | steps/01-preflight.ps1 Test-DiskSpace line 137: `exit $EXIT_DISK_SPACE` when `$freeGB -lt 12` |
| 10 | Script exits with code 14 if ADB binary is not found in the bundle | VERIFIED | steps/01-preflight.ps1 Test-AdbBinary line 164: `exit $EXIT_ADB_MISSING` when `$exists` is false |
| 11 | Script exits with code 20 when a step throws an unhandled exception | FAILED | deploy.ps1 catch block (line 46-48) exits with `$EXIT_UNKNOWN` (99), not `$EXIT_STEP_FAILED` (20). $EXIT_STEP_FAILED is defined on line 17 but never referenced in any exit path. |
| 12 | Script exits with code 0 only when all steps complete successfully | VERIFIED | deploy.ps1 line 45: `exit $EXIT_SUCCESS` only reached after Invoke-Step completes; any failure throws and is caught, exiting non-zero |
| 13 | deploy.ps1 imports all three lib modules and initializes logging before any step | VERIFIED | deploy.ps1 lines 24-32: Import-Module Log/State/Guard, then Initialize-Log, then the try block containing Invoke-Step |

**Score: 12/13 truths verified (10/11 counting ROADMAP Success Criteria separately from plan truths)**

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/Log.psm1` | Write-Log and Initialize-Log functions | VERIFIED | 66 lines; exports both functions; $ErrorActionPreference = "Stop" at scope |
| `lib/State.psm1` | Registry read/write helpers | VERIFIED | 78 lines; exports Get-DeployState, Set-DeployState, Set-RegistryBase; New-Item -Force for path creation |
| `lib/Guard.psm1` | Invoke-Step idempotency wrapper | VERIFIED | 55 lines; exports Invoke-Step; full skip/log/catch/flag semantics implemented |
| `deploy.ps1` | Entry point: #Requires, exit codes, module imports, log init, step dispatch | VERIFIED | 49 lines; all structural elements present; $EXIT_STEP_FAILED defined but unused in any exit path |
| `steps/01-preflight.ps1` | Five pre-flight validation checks | VERIFIED | 198 lines; five check functions + Invoke-Preflight + BARAKA_TEST_MODE guard; test seams via mock parameters |
| `tests/Log.Tests.ps1` | Pester tests for Write-Log | VERIFIED | 7 tests in Describe blocks; tests directory creation, log path, format pattern, append, level tags, default INFO |
| `tests/Guard.Tests.ps1` | Pester tests for Invoke-Step | VERIFIED | 7 tests; uses Pester -ModuleName mocks for cross-platform registry isolation |
| `tests/ErrorHandling.Tests.ps1` | Pester tests for EAP and catch-block logging | VERIFIED | 4 tests; text-pattern check for $ErrorActionPreference = "Stop" in each module + catch-block ERROR logging |
| `tests/ExitCodes.Tests.ps1` | Structural tests for deploy.ps1 | VERIFIED | 6 tests; text-pattern analysis without executing deploy.ps1 |
| `tests/Preflight.Tests.ps1` | Pester tests for all five preflight checks | VERIFIED | 13 tests; child-process exit-code testing pattern; all five checks + Invoke-Preflight orchestration |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/Guard.psm1` | `lib/Log.psm1` | Invoke-Step calls Write-Log | WIRED | Guard.psm1 lines 38, 42, 47, 52: Write-Log calls for skip/start/error/done messages |
| `lib/Guard.psm1` | `HKLM:\SOFTWARE\Baraka\Deploy` | Registry guard flags via State helpers | WIRED | Guard routes through Get-DeployState/Set-DeployState; State.psm1 line 6: `$script:RegBase = "HKLM:\SOFTWARE\Baraka\Deploy"` |
| `deploy.ps1` | `lib/Log.psm1` | Import-Module at startup | WIRED | deploy.ps1 line 24: `Import-Module (Join-Path $LibDir "Log.psm1") -Force` |
| `deploy.ps1` | `lib/Guard.psm1` | Import-Module + Invoke-Step for each step | WIRED | deploy.ps1 line 26 (import) + line 38 (Invoke-Step -StepName "Preflight") |
| `deploy.ps1` | `steps/01-preflight.ps1` | Dot-source inside Invoke-Step body | WIRED | deploy.ps1 lines 38-40: `. (Join-Path $PSScriptRoot "steps\01-preflight.ps1")` inside Body scriptblock |
| `steps/01-preflight.ps1` | `lib/Log.psm1` | Write-Log calls for each check result | WIRED | steps/01-preflight.ps1: Write-Log calls on lines 32, 48, 52, 73, 77, 93, 104, 110, 114, 136, 140, 163, 167 |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|---------|
| CORE-01 | 01-01 | $ErrorActionPreference = "Stop" with try/catch on every mutating call | SATISFIED | All three modules set EAP=Stop at scope; Guard.psm1 wraps body execution in try/catch; deploy.ps1 sets EAP=Stop and has top-level try/catch |
| CORE-02 | 01-01 | Each step checks registry guard before executing and sets it on success | SATISFIED | Invoke-Step in Guard.psm1 implements full guard check-execute-flag semantics; idempotency verified in Guard.Tests.ps1 (7 tests) |
| CORE-03 | 01-01 | All output goes through a single timestamped Write-Log function to deploy.log | SATISFIED | Write-Log is the sole output channel; all module messages route through it; Initialize-Log sets the file path |
| CORE-04 | 01-02 | Script validates OS edition, admin, virtualization, disk space, ADB binary before any system changes | SATISFIED | steps/01-preflight.ps1 implements all five checks; dispatch is the first (and currently only) Invoke-Step call in deploy.ps1 |
| CORE-05 | 01-02 | Script exits code 0 only on full success, non-zero per failure category | PARTIALLY SATISFIED | Exit 0 is correctly reserved; codes 10-14 are correctly used; code 20 ($EXIT_STEP_FAILED) is defined but the catch block uses 99 instead — see gap above |

**Orphaned requirements check:** REQUIREMENTS.md traceability maps only CORE-01 through CORE-05 to Phase 1. All five are claimed by plans. No orphaned requirements.

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `deploy.ps1` | 17 | `$EXIT_STEP_FAILED = 20` defined but never used in any exit path | Warning | The exit code taxonomy in the plan and RESEARCH.md says code 20 is emitted when a step throws; the actual catch uses 99. Consumers of the exit code (IT runbooks, monitoring) would be misled. |

No TODO/FIXME/HACK comments found. No placeholder returns (return null, return {}) found. No stub implementations detected.

---

## Human Verification Required

### 1. End-to-end execution on a real Windows terminal

**Test:** Run `powershell.exe -ExecutionPolicy Bypass -File deploy.ps1` as Administrator on a Windows 10/11 Pro terminal where the adb bundle is NOT present.
**Expected:** Script imports modules, initializes deploy.log, runs preflight, logs "Pre-flight FAILED: ADB binary not found" to console AND deploy.log, exits with code 14.
**Why human:** Cannot execute PowerShell 5.1 registry and WMI calls in the Linux CI environment; the production code paths (Get-WmiObject, WindowsPrincipal, Get-PSDrive, Get-ComputerInfo) are not exercised by the mock-based tests.

### 2. Idempotency on re-run after partial success

**Test:** Run deploy.ps1 twice in succession. First run should succeed. Second run should skip the "Preflight" step with "Already complete" in the log.
**Expected:** Second run exits 0 with no system mutations and the log contains "Already complete -- skipping" for the Preflight step.
**Why human:** Requires real HKLM registry write on first run and read on second run. Registry mocks in tests cannot confirm that HKLM:\SOFTWARE\Baraka\Deploy is correctly created and read on a real Windows machine.

---

## Gaps Summary

One gap was found. The `must_haves.truths` in 01-02-PLAN.md states "Script exits with code 20 when a step throws an unhandled exception." The implementation exits with code 99 (`$EXIT_UNKNOWN`) from the top-level catch, not code 20 (`$EXIT_STEP_FAILED`). The constant is defined and tested for existence (ExitCodes.Tests.ps1 line 28 checks it is defined) but is never referenced in any `exit` statement.

The fix is one of:
1. Change the catch block in deploy.ps1 to `exit $EXIT_STEP_FAILED` — consistent with the stated taxonomy where code 20 means "a step threw."
2. Remove the truth from must_haves and document that code 20 is reserved for future step-level re-throw differentiation, and code 99 is the current single catch-all.

Option 1 is the more correct resolution: code 20 (step failed) and code 99 (unknown error) serve different diagnostic purposes, and collapsing them into 99 loses specificity.

All other must-have truths, artifacts, and key links are fully verified. The foundational modules (Log, State, Guard) are substantive, well-tested, and correctly wired. The deploy.ps1 entry point and preflight checks meet their stated goals. The 37-test suite is comprehensive and cross-platform.

---

_Verified: 2026-03-17_
_Verifier: Claude (gsd-verifier)_
