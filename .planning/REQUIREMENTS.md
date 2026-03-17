# Requirements: Baraka POS Deployment Hardening

**Defined:** 2026-03-17
**Core Value:** Store terminal deployment must be a single-script, zero-intervention process

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Deployment Core

- [x] **CORE-01**: Script uses `$ErrorActionPreference = "Stop"` with try/catch on every mutating call
- [x] **CORE-02**: Each step checks a registry guard before executing and sets it on success (idempotent)
- [x] **CORE-03**: All output goes through a single timestamped `Write-Log` function to `deploy.log`
- [x] **CORE-04**: Script validates OS edition, admin privileges, virtualization capability, disk space, and ADB binary before any system changes
- [x] **CORE-05**: Script exits with code 0 only on full success, non-zero per failure category

### Reboot Resume

- [x] **BOOT-01**: Reboot-resume uses a scheduled task at HIGHEST run level (not RunOnce)
- [x] **BOOT-02**: Port 58526 is reserved via `netsh` before the Hyper-V reboot
- [x] **BOOT-03**: Checkpoint state is saved to JSON before reboot for clean resume
- [x] **BOOT-04**: Scheduled task self-deletes after successful resume

### VM Features

- [x] **VMFT-01**: Script enables VirtualMachinePlatform and HypervisorPlatform silently
- [x] **VMFT-02**: Script detects if features are already enabled and skips if so
- [x] **VMFT-03**: Script triggers reboot only when `RestartNeeded` is true

### WSA Installation

- [x] **WSAI-01**: WSA installs silently via `Add-AppxPackage -Register` from unpacked directory
- [x] **WSAI-02**: Script suppresses all auto-launched WSA windows after install
- [x] **WSAI-03**: Script waits for WSA initialization to complete before proceeding (poll-based, not fixed sleep)
- [x] **WSAI-04**: Script detects if WSA is already installed and skips reinstall

### Developer Mode and ADB

- [x] **ADBM-01**: Script writes Developer Mode registry key and restarts WSA to apply
- [x] **ADBM-02**: Script sets WSA to Continuous resource mode (prevents idle termination)
- [x] **ADBM-03**: ADB connection uses exponential backoff retry (5 attempts, up to 60s timeout)
- [x] **ADBM-04**: ADB connection checks `adb devices` output for `device` status (not exit codes)
- [x] **ADBM-05**: Script emits a clear, single-step manual instruction if ADB probe fails after all retries

### APK Sideloading

- [ ] **APKS-01**: Script compares installed APK version before installing (skip if current)
- [ ] **APKS-02**: Script auto-detects APK file in the deployment bundle directory
- [ ] **APKS-03**: APK installs via `adb install -r` with success verification

### Print Server Hardening

- [ ] **PRNT-01**: CORS restricted from wildcard to localhost + local network via environment variable
- [ ] **PRNT-02**: Bridge monitor triggers WSA startup (`WsaClient /launch`) before reconnect attempts
- [ ] **PRNT-03**: Bridge monitor re-issues `adb reverse` unconditionally after any reconnect
- [ ] **PRNT-04**: Bridge monitor logs all exceptions (no silent catch blocks)

### Health Verification

- [ ] **HLTH-01**: Smoke test verifies WSA is running after deployment
- [ ] **HLTH-02**: Smoke test verifies ADB device is connected and authorized
- [ ] **HLTH-03**: Smoke test verifies APK package is listed in WSA
- [ ] **HLTH-04**: Smoke test verifies printer server `/health` endpoint responds

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Deployment Extras

- **DPLX-01**: Dry-run / -WhatIf mode for pre-deployment audits
- **DPLX-02**: Machine-readable `deploy-result.json` for fleet management
- **DPLX-03**: Verbose / debug flag for troubleshooting individual terminals
- **DPLX-04**: Configurable parameters via `deploy.config.json` sidecar
- **DPLX-05**: `--force-reinstall` flag to bypass idempotency guards

### Migration

- **MIGR-01**: React Native Web build target for browser-based POS
- **MIGR-02**: Android hardware deployment with MDM integration

## Out of Scope

| Feature | Reason |
|---------|--------|
| Full rollback / snapshot restore | Idempotent re-run is the pragmatic substitute at sub-10 terminal scale |
| GUI-based automation (SendKeys, AutoIt) | Fragile across OS versions, explicitly anti-pattern |
| Remote deployment orchestration | IT team deploys on-site; remote push is v2+ |
| React Native APK changes | This project only fixes deployment, not the app |
| Printer server feature additions | Server code is stable, only deployment and security changes |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CORE-01 | Phase 1 | Complete (01-01) |
| CORE-02 | Phase 1 | Complete (01-01) |
| CORE-03 | Phase 1 | Complete (01-01) |
| CORE-04 | Phase 1 | Complete |
| CORE-05 | Phase 1 | Complete |
| BOOT-01 | Phase 2 | Complete |
| BOOT-02 | Phase 2 | Complete |
| BOOT-03 | Phase 2 | Complete |
| BOOT-04 | Phase 2 | Complete |
| VMFT-01 | Phase 2 | Complete |
| VMFT-02 | Phase 2 | Complete |
| VMFT-03 | Phase 2 | Complete |
| WSAI-01 | Phase 3 | Complete |
| WSAI-02 | Phase 3 | Complete |
| WSAI-03 | Phase 3 | Complete |
| WSAI-04 | Phase 3 | Complete |
| ADBM-01 | Phase 3 | Complete |
| ADBM-02 | Phase 3 | Complete |
| ADBM-03 | Phase 3 | Complete |
| ADBM-04 | Phase 3 | Complete |
| ADBM-05 | Phase 3 | Complete |
| APKS-01 | Phase 3 | Pending |
| APKS-02 | Phase 3 | Pending |
| APKS-03 | Phase 3 | Pending |
| PRNT-01 | Phase 4 | Pending |
| PRNT-02 | Phase 4 | Pending |
| PRNT-03 | Phase 4 | Pending |
| PRNT-04 | Phase 4 | Pending |
| HLTH-01 | Phase 5 | Pending |
| HLTH-02 | Phase 5 | Pending |
| HLTH-03 | Phase 5 | Pending |
| HLTH-04 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 32 total
- Mapped to phases: 32
- Unmapped: 0

---
*Requirements defined: 2026-03-17*
*Last updated: 2026-03-17 — traceability updated to 5-phase roadmap (coarse granularity)*
