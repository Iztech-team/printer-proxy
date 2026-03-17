# Roadmap: Baraka POS Deployment Hardening

## Overview

Five phases deliver a single-script, zero-intervention deployment for Baraka store terminals. Phase 1 builds the foundation (logging, state machine, preflight). Phase 2 enables VM features and survives the mandatory Hyper-V reboot. Phase 3 installs WSA, establishes ADB, and sideloads the APK — the complete Android stack in one phase. Phase 4 hardens the print server independently of the WSA chain. Phase 5 validates the entire deployment end-to-end and exits cleanly.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Foundation** - Script scaffolding, structured logging, preflight validation (completed 2026-03-17)
- [x] **Phase 2: VM Features + Reboot Resume** - Enable Hyper-V, reserve port 58526, survive reboot with elevation (completed 2026-03-17)
- [ ] **Phase 3: WSA Setup + ADB + APK** - Install WSA, configure developer mode, connect ADB, sideload the app
- [ ] **Phase 4: Print Server Hardening** - Harden CORS, fix bridge monitor, verify service state
- [ ] **Phase 5: Verification** - Smoke test full stack, exit 0 only on confirmed working deployment

## Phase Details

### Phase 1: Foundation
**Goal**: IT can invoke the deployment script on any terminal and it validates prerequisites, logs everything, and fails fast with a clear message before touching the system
**Depends on**: Nothing (first phase)
**Requirements**: CORE-01, CORE-02, CORE-03, CORE-04, CORE-05
**Success Criteria** (what must be TRUE):
  1. Script exits immediately with a clear diagnostic if OS edition, admin privileges, virtualisation capability, disk space, or ADB binary are missing
  2. Every mutating call is wrapped in try/catch and all output — including errors — appears in a timestamped `deploy.log`
  3. Re-running the script after a failure replays only the steps that haven't completed (registry guards prevent double execution)
  4. Script exits with a non-zero code matching the failure category; exit 0 is reserved for full success only
**Plans:** 2/2 plans complete

Plans:
- [x] 01-01-PLAN.md — Shared modules: Log.psm1, State.psm1, Guard.psm1 + Pester tests
- [ ] 01-02-PLAN.md — Entry point deploy.ps1 + preflight validation + Pester tests

### Phase 2: VM Features + Reboot Resume
**Goal**: Terminal boots with VirtualMachinePlatform and HypervisorPlatform enabled, port 58526 reserved from Hyper-V, and the deployment resumes automatically at HIGHEST privilege after reboot
**Depends on**: Phase 1
**Requirements**: BOOT-01, BOOT-02, BOOT-03, BOOT-04, VMFT-01, VMFT-02, VMFT-03
**Success Criteria** (what must be TRUE):
  1. If VM features are already enabled, script skips enablement and does not trigger a reboot
  2. When features need enabling, terminal reboots and the deployment script resumes automatically at the correct step with admin elevation intact
  3. Port 58526 is listed in `netsh int ipv4 show excludedportrange` output before the reboot occurs
  4. After successful resume, the scheduled task is no longer present in Task Scheduler
**Plans:** 1/1 plans complete

Plans:
- [ ] 02-01-PLAN.md — VM feature enablement, port reservation, reboot-resume via scheduled task + Pester tests

### Phase 3: WSA Setup + ADB + APK
**Goal**: The Baraka POS APK is installed and running inside WSA on a fully configured, ADB-connected terminal
**Depends on**: Phase 2
**Requirements**: WSAI-01, WSAI-02, WSAI-03, WSAI-04, ADBM-01, ADBM-02, ADBM-03, ADBM-04, ADBM-05, APKS-01, APKS-02, APKS-03
**Success Criteria** (what must be TRUE):
  1. WSA installs silently with no unexpected windows appearing during or after install
  2. `adb devices` shows the WSA instance with `device` status (not `unauthorized` or absent)
  3. If ADB connection fails after all retries, a clear single-step manual instruction is displayed — script does not silently proceed or crash
  4. `adb shell pm list packages` shows the Baraka APK package after deployment
  5. Re-running the script on a correctly deployed terminal skips WSA install and APK install without error
**Plans:** 1/3 plans executed

Plans:
- [ ] 03-01-PLAN.md — WSA install step (TDD): Test-WsaInstalled, Add-AppxPackage, window suppression, poll-based init wait
- [ ] 03-02-PLAN.md — WSA configure + ADB step (TDD): Developer mode, Continuous mode, ADB exponential backoff retry, manual fallback
- [ ] 03-03-PLAN.md — APK install step (TDD) + deploy.ps1 wiring: APK auto-detect, version check, adb install -r, step orchestration

### Phase 4: Print Server Hardening
**Goal**: The Python print server runs with restricted CORS, the bridge monitor reliably reconnects WSA, and no exceptions are swallowed silently
**Depends on**: Phase 1
**Requirements**: PRNT-01, PRNT-02, PRNT-03, PRNT-04
**Success Criteria** (what must be TRUE):
  1. Print server `/health` endpoint rejects requests from origins outside localhost and the local network subnet (wildcard CORS is removed)
  2. Bridge monitor wakes WSA via `WsaClient /launch` before each reconnect attempt (not a blind `adb connect` retry)
  3. `adb reverse` is re-issued after every reconnect, not only on first connection
  4. All exceptions in the bridge monitor appear in logs — no silent `except: pass` blocks remain
**Plans**: TBD

### Phase 5: Verification
**Goal**: Deployment is confirmed working by a smoke test that checks every layer of the stack before reporting success
**Depends on**: Phase 3, Phase 4
**Requirements**: HLTH-01, HLTH-02, HLTH-03, HLTH-04
**Success Criteria** (what must be TRUE):
  1. Smoke test confirms WSA process is running, ADB device is connected and authorized, Baraka APK package is listed, and print server `/health` returns 200 — all four checks must pass
  2. Script exits with code 0 only when all smoke tests pass; any single failure produces a non-zero exit with the specific failing check named
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5
(Phase 4 depends only on Phase 1 and can be planned in parallel with Phases 2-3, but executes before Phase 5)

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 2/2 | Complete    | 2026-03-17 |
| 2. VM Features + Reboot Resume | 1/1 | Complete    | 2026-03-17 |
| 3. WSA Setup + ADB + APK | 1/3 | In Progress|  |
| 4. Print Server Hardening | 0/? | Not started | - |
| 5. Verification | 0/? | Not started | - |
