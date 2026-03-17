---
phase: 2
slug: vm-features-reboot-resume
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-17
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Pester 5.x (PowerShell native test framework) |
| **Config file** | none — reuses Phase 1 infrastructure |
| **Quick run command** | `Invoke-Pester -Path tests/ -Tag Unit` |
| **Full suite command** | `Invoke-Pester -Path tests/ -Output Detailed` |
| **Estimated runtime** | ~8 seconds |

---

## Sampling Rate

- **After every task commit:** Run `Invoke-Pester -Path tests/ -Tag Unit`
- **After every plan wave:** Run `Invoke-Pester -Path tests/ -Output Detailed`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 8 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 2-01-01 | 01 | 1 | VMFT-01, VMFT-02, VMFT-03 | unit | `Invoke-Pester -Path tests/VmFeatures.Tests.ps1` | ❌ W0 | ⬜ pending |
| 2-01-02 | 01 | 1 | BOOT-01, BOOT-02, BOOT-03, BOOT-04 | unit | `Invoke-Pester -Path tests/RebootResume.Tests.ps1` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/VmFeatures.Tests.ps1` — stubs for VMFT-01, VMFT-02, VMFT-03
- [ ] `tests/RebootResume.Tests.ps1` — stubs for BOOT-01, BOOT-02, BOOT-03, BOOT-04

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Actual reboot + resume cycle | BOOT-01 | Requires real Windows reboot | Run deploy on test terminal with VM features disabled, verify script resumes after reboot |
| Port reservation survives reboot | BOOT-02 | Requires real Windows reboot | After reboot, run `netsh int ipv4 show excludedportrange` and verify 58526 is listed |
| Scheduled task runs at HIGHEST | BOOT-01 | Requires Task Scheduler UI or `schtasks /query` | Verify task properties show RunLevel=Highest |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 8s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
