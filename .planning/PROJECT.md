# Baraka POS Deployment Hardening

## What This Is

A deployment toolkit for the Baraka POS system that installs a React Native Android app onto Windows store terminals via WSA (Windows Subsystem for Android), along with a Python print server that bridges the app to thermal receipt printers on the local network. The goal is to make this deployment fully automated and reliable — eliminating manual steps and flaky connections.

## Core Value

Store terminal deployment must be a single-script, zero-intervention process that IT can run on any terminal without manual UI interaction or troubleshooting.

## Requirements

### Validated

- ✓ Python FastAPI printer server with thermal printer discovery (port 9100) — existing
- ✓ Per-printer job queue with retry logic (replaces CUPS spooler) — existing
- ✓ Network printer auto-discovery via TCP scan + MAC resolution (HTTP/SNMP/ARP) — existing
- ✓ WSA bridge (adb reverse) for APK-to-printer-server communication — existing
- ✓ Printer connection pooling with health checks — existing
- ✓ Receipt, text, image, QR, barcode printing endpoints — existing
- ✓ Auto-start via Windows scheduled task or startup shortcut — existing

### Active

- [ ] Fully automated WSA Developer Mode enablement (no manual UI toggle)
- [ ] Reliable ADB connection with robust reconnection logic
- [ ] Automated VM features enablement with seamless reboot-resume
- [ ] Clean WSA installation without spurious window popups
- [ ] Single-command deployment with zero manual intervention
- [ ] Graceful error handling with clear diagnostics when steps fail
- [ ] CORS hardening (restrict from wildcard to localhost/local network)

### Out of Scope

- React Native Web migration — future initiative, not this project
- Android hardware migration — requires hardware procurement, separate decision
- Changes to the React Native APK itself — this project only fixes deployment
- Printer server feature additions — server code is stable, only deployment changes

## Context

- **Terminal fleet:** Under 10 terminals currently, deployed by IT team on-site
- **Terminal hardware:** Varies across stores (different models), cannot use golden image cloning
- **WSA build:** MagiskOnWSALocal (community build with Magisk root + MindTheGapps). Root access is intentionally required by the APK
- **WSA status:** Officially deprecated by Microsoft (March 2025), but still functional. This hardening buys time while a longer-term migration is planned
- **Urgency:** Deployments are blocked this week — fixes needed immediately
- **Printers:** Thermal receipt printers on port 9100 (ESC/POS protocol), discovered via network scan
- **Network:** LAN-only, no public internet required for operation

## Constraints

- **Platform:** Windows 10/11 only — terminals run Windows, cannot change OS
- **WSA dependency:** Must use WSA (deprecated) until migration path is chosen — no alternatives available on Windows for running the APK
- **Magisk root:** Required by the APK — cannot switch to vanilla WSA
- **Hardware variance:** Different terminal models across stores prevents image-based deployment
- **Admin privileges:** Script must handle both admin and non-admin execution paths

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Harden WSA setup vs. migrate away | Under 10 terminals, need fix this week, migration is a separate initiative | — Pending |
| Keep MagiskOnWSALocal build | Root access required by APK, Google Play needed | — Pending |
| Automate Developer Mode via registry + ADB probing | Avoid manual UI interaction during deployment | — Pending |
| Restrict CORS from wildcard | Security hardening for POS environment | — Pending |

---
*Last updated: 2026-03-17 after initialization*
