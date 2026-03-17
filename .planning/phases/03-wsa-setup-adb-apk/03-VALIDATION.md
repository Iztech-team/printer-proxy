---
phase: 3
slug: wsa-setup-adb-apk
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-17
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Pester 5.x (PowerShell native test framework) |
| **Config file** | none — reuses Phase 1-2 infrastructure |
| **Quick run command** | `Invoke-Pester -Path tests/ -Tag Unit` |
| **Full suite command** | `Invoke-Pester -Path tests/ -Output Detailed` |
| **Estimated runtime** | ~12 seconds |

---

## Sampling Rate

- **After every task commit:** Run `Invoke-Pester -Path tests/ -Tag Unit`
- **After every plan wave:** Run `Invoke-Pester -Path tests/ -Output Detailed`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 12 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 3-01-01 | 01 | 1 | WSAI-01, WSAI-02, WSAI-03, WSAI-04 | unit | `Invoke-Pester -Path tests/WsaInstall.Tests.ps1` | ❌ W0 | ⬜ pending |
| 3-01-02 | 01 | 1 | ADBM-01, ADBM-02, ADBM-03, ADBM-04, ADBM-05 | unit | `Invoke-Pester -Path tests/WsaConfigure.Tests.ps1` | ❌ W0 | ⬜ pending |
| 3-01-03 | 01 | 1 | APKS-01, APKS-02, APKS-03 | unit | `Invoke-Pester -Path tests/ApkInstall.Tests.ps1` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/WsaInstall.Tests.ps1` — stubs for WSAI-01 through WSAI-04
- [ ] `tests/WsaConfigure.Tests.ps1` — stubs for ADBM-01 through ADBM-05
- [ ] `tests/ApkInstall.Tests.ps1` — stubs for APKS-01 through APKS-03

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| WSA installs with no visible windows | WSAI-02 | Requires real Windows desktop | Run deploy, observe no WSA Settings windows appear |
| ADB connects to WSA | ADBM-03 | Requires running WSA instance | After deploy, run `adb devices` and verify `device` status |
| APK visible in WSA | APKS-03 | Requires running WSA + ADB | Run `adb shell pm list packages` and verify Baraka package |
| Manual fallback message shown | ADBM-05 | Requires ADB failure scenario | Disable WSA dev mode, run deploy, verify clear instruction |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 12s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
