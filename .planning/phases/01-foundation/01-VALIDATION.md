---
phase: 1
slug: foundation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-17
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Pester 5.x (PowerShell native test framework) |
| **Config file** | none — Wave 0 installs |
| **Quick run command** | `Invoke-Pester -Path tests/ -Tag Unit` |
| **Full suite command** | `Invoke-Pester -Path tests/ -Output Detailed` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `Invoke-Pester -Path tests/ -Tag Unit`
- **After every plan wave:** Run `Invoke-Pester -Path tests/ -Output Detailed`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 1-01-01 | 01 | 1 | CORE-03 | unit | `Invoke-Pester -Path tests/Log.Tests.ps1` | ❌ W0 | ⬜ pending |
| 1-01-02 | 01 | 1 | CORE-02 | unit | `Invoke-Pester -Path tests/Guard.Tests.ps1` | ❌ W0 | ⬜ pending |
| 1-01-03 | 01 | 1 | CORE-01 | unit | `Invoke-Pester -Path tests/ErrorHandling.Tests.ps1` | ❌ W0 | ⬜ pending |
| 1-01-04 | 01 | 1 | CORE-04 | unit | `Invoke-Pester -Path tests/Preflight.Tests.ps1` | ❌ W0 | ⬜ pending |
| 1-01-05 | 01 | 1 | CORE-05 | unit | `Invoke-Pester -Path tests/ExitCodes.Tests.ps1` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/Log.Tests.ps1` — stubs for CORE-03
- [ ] `tests/Guard.Tests.ps1` — stubs for CORE-02
- [ ] `tests/ErrorHandling.Tests.ps1` — stubs for CORE-01
- [ ] `tests/Preflight.Tests.ps1` — stubs for CORE-04
- [ ] `tests/ExitCodes.Tests.ps1` — stubs for CORE-05

*Note: Pester tests are dev/CI tooling only — not bundled in the deployment package.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Registry guard survives reboot | CORE-02 | Requires actual reboot cycle | Set a guard key, reboot, verify key persists and step skips |
| Admin elevation detection | CORE-04 | Requires running as non-admin | Run script without admin, verify preflight fails with exit code 11 |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
