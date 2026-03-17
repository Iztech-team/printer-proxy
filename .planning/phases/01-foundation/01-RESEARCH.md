# Phase 1: Foundation - Research

**Researched:** 2026-03-17
**Domain:** PowerShell 5.1 deployment scaffolding — structured logging, registry state machine, error handling, pre-flight checks
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| CORE-01 | Script uses `$ErrorActionPreference = "Stop"` with try/catch on every mutating call | PowerShell error handling patterns are well-documented and stable; exact pattern verified from existing codebase and Microsoft docs |
| CORE-02 | Each step checks a registry guard before executing and sets it on success (idempotent) | Registry-backed idempotency guard pattern confirmed from architecture research; `Invoke-Step` wrapper pattern specified |
| CORE-03 | All output goes through a single timestamped `Write-Log` function to `deploy.log` | `Write-Log` pattern is standard; log path `%ProgramData%\Baraka\deploy.log` is confirmed |
| CORE-04 | Script validates OS edition, admin privileges, virtualization capability, disk space, and ADB binary before any system changes | All five pre-flight checks have specific PowerShell commands identified; each check has a distinct failure message and exit code |
| CORE-05 | Script exits with code 0 only on full success, non-zero per failure category | Exit code taxonomy defined; `exit` with named constants pattern identified |
</phase_requirements>

---

## Summary

Phase 1 is pure scaffolding — no system state changes occur. The goal is to create the shared library modules and pre-flight validation step so that all subsequent phases inherit correct logging, error handling, idempotency semantics, and exit code discipline from the start. Every single line in this phase is foundational infrastructure that later phases depend on; getting it right here prevents re-work across the entire project.

The existing `windows_setup.ps1` uses `$ErrorActionPreference = "Continue"`, has no structured logging, has no registry guards, and has no explicit exit codes — which is precisely why deployments fail silently and leave terminals in unknown states. Phase 1 replaces all of that scaffolding with clean, predictable primitives. The architecture calls for three shared modules (`State.psm1`, `Log.psm1`, `Guard.psm1`), a `deploy.ps1` entry point, and one step file (`01-preflight.ps1`).

The pre-flight check must validate five distinct conditions before any mutating step runs: (1) OS edition must be Windows 10/11 Pro or Enterprise (Home does not support Hyper-V); (2) the process must be running with admin elevation; (3) the CPU must report virtualization support via `Get-ComputerInfo`; (4) free disk space must exceed the minimum threshold (WSA requires ~10 GB); (5) the bundled ADB binary must be present at the expected path in the deployment package. Each failure must emit a clear, IT-readable diagnostic message, write to the log, and exit with a distinct non-zero code.

**Primary recommendation:** Build State.psm1, Log.psm1, and Guard.psm1 as import-ready modules first, then write deploy.ps1 and 01-preflight.ps1 against those modules. This order makes every subsequent phase a simple consumer of stable primitives.

---

## Standard Stack

### Core

| Technology | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| Windows PowerShell | 5.1 (built-in) | All scripting | Only version with Appx + DISM modules on Windows client; ships with Windows 10/11; no install step |
| HKLM Registry | Built-in | Persistent state store | Survives reboots; accessible to all elevated processes; externally inspectable by IT; cannot be lost like a temp file |
| `%ProgramData%\Baraka\` | Built-in path | Log + state directory | ProgramData is accessible by all users/services; persists across reboots; standard for machine-wide Windows tooling |

### Supporting

| Technology | Purpose | When to Use |
|-----------|---------|-------------|
| `[Security.Principal.WindowsPrincipal]` class | Admin elevation check | Pre-flight; always called before any mutating step |
| `Get-ComputerInfo -Property HyperVRequirementVirtualizationFirmwareEnabled` | BIOS virtualization check | Pre-flight; needed before VirtualMachinePlatform enable attempt |
| `Get-PSDrive -Name C` | Free disk space check | Pre-flight; simple and reliable on single-disk terminals |
| `#Requires -Version 5.1` | Runtime version guard | Top of deploy.ps1; fails immediately on wrong PS version |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Registry guards | JSON state file | JSON file can be deleted accidentally; registry survives more failure modes and is machine-readable by IT tools |
| `%ProgramData%` for logs | `$env:TEMP` | TEMP is per-user, may be cleaned by OS; ProgramData persists across user sessions and reboots |
| Module import (`.psm1`) | Dot-sourcing (`. ./lib/Log.ps1`) | Modules have explicit `Export-ModuleMember` scoping; dot-sourcing pollutes global scope |

**Installation:** No package installs required — Phase 1 uses only Windows built-in capabilities.

---

## Architecture Patterns

### Recommended Project Structure

```
baraka-deploy/
  deploy.ps1                  # Entry point: arg parsing, module import, step dispatch
  lib/
    State.psm1                # Registry read/write for phase tracking
    Log.psm1                  # Write-Log function, log file init
    Guard.psm1                # Assert-NotAlreadyDone / Set-StepDone
  steps/
    01-preflight.ps1          # OS edition, admin, virt, disk, ADB binary checks
    (02–08 added in later phases)
  adb/
    adb.exe                   # Bundled, not PATH-resolved
    AdbWinApi.dll
    AdbWinUsbApi.dll
  apk/
    baraka-pos.apk
```

### Pattern 1: Module Import at Entry Point

**What:** deploy.ps1 imports all three lib modules once at startup; every step script runs in the same session scope and calls Write-Log, Invoke-Guard, etc. without re-importing.
**When to use:** Always — modules must be imported before any step runs.

```powershell
# deploy.ps1 — top of file
#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$LibDir = Join-Path $PSScriptRoot "lib"
Import-Module (Join-Path $LibDir "Log.psm1")   -Force
Import-Module (Join-Path $LibDir "State.psm1") -Force
Import-Module (Join-Path $LibDir "Guard.psm1") -Force

# Ensure log directory exists before first Write-Log call
$null = New-Item -ItemType Directory -Path "$env:ProgramData\Baraka" -Force
Initialize-Log -Path "$env:ProgramData\Baraka\deploy.log"
```

### Pattern 2: Write-Log Implementation

**What:** Single function writing timestamped, levelled lines to both the log file and the console. All script output — including errors — must flow through this function.
**When to use:** Every Write-Host or Write-Error call becomes Write-Log.

```powershell
# Log.psm1
function Write-Log {
    param(
        [ValidateSet("INFO","WARN","ERROR","DEBUG")]
        [string]$Level = "INFO",
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Initialize-Log {
    param([string]$Path)
    $script:LogPath = $Path
    Write-Log "INFO" "=== Baraka Deploy started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
}

Export-ModuleMember -Function Write-Log, Initialize-Log
```

### Pattern 3: Idempotency Guard (Invoke-Step Wrapper)

**What:** Every step is invoked through a wrapper that checks a registry flag. If the flag is set, the step is skipped. If not, the body runs, and on success the flag is set.
**When to use:** Wrap every step call in deploy.ps1 with this pattern.

```powershell
# Guard.psm1
$RegBase = "HKLM:\SOFTWARE\Baraka\Deploy"

function Invoke-Step {
    param(
        [string]$StepName,
        [scriptblock]$Body
    )
    # Ensure registry path exists
    if (-not (Test-Path $RegBase)) {
        New-Item -Path $RegBase -Force | Out-Null
    }
    $doneProp = Get-ItemProperty -Path $RegBase -Name "$StepName-Done" -ErrorAction SilentlyContinue
    if ($doneProp -and $doneProp."$StepName-Done" -eq 1) {
        Write-Log "INFO" "[$StepName] Already complete — skipping"
        return
    }
    Write-Log "INFO" "[$StepName] Starting"
    & $Body
    Set-ItemProperty -Path $RegBase -Name "$StepName-Done" -Value 1 -Type DWord -Force
    Write-Log "INFO" "[$StepName] Done"
}

Export-ModuleMember -Function Invoke-Step
```

### Pattern 4: Exit Code Taxonomy

**What:** Each failure category maps to a distinct non-zero exit code. Exit 0 is reserved for full success only.
**When to use:** Every `throw` or fatal failure path in a step must call `exit` with the appropriate code.

```powershell
# Exit codes — define as constants in deploy.ps1
$EXIT_SUCCESS            = 0
$EXIT_OS_EDITION         = 10   # CORE-04: OS not Pro/Enterprise
$EXIT_NOT_ADMIN          = 11   # CORE-04: missing admin elevation
$EXIT_NO_VIRT            = 12   # CORE-04: BIOS virtualization off
$EXIT_DISK_SPACE         = 13   # CORE-04: insufficient disk space
$EXIT_ADB_MISSING        = 14   # CORE-04: ADB binary not in bundle
$EXIT_STEP_FAILED        = 20   # CORE-01: step threw an unhandled exception
$EXIT_UNKNOWN            = 99   # fallback for unexpected errors
```

### Pattern 5: Pre-flight Check Structure

**What:** 01-preflight.ps1 runs five sequential checks. Each check logs its result and calls `exit` with a specific code on failure. All five must pass before execution continues.
**When to use:** Always the first step invoked; runs before any system mutation.

```powershell
# steps/01-preflight.ps1
function Test-OsEdition {
    $edition = (Get-WmiObject -Class Win32_OperatingSystem).OperatingSystemSKU
    # SKUs: 48=Pro, 49=ProN, 4=Enterprise, 70=EnterpriseN, 125=Education...
    $supported = @(48, 49, 4, 27, 70, 125, 126)
    if ($edition -notin $supported) {
        $name = (Get-WmiObject -Class Win32_OperatingSystem).Caption
        Write-Log "ERROR" "OS edition not supported: $name (SKU $edition). Pro or Enterprise required."
        exit $EXIT_OS_EDITION
    }
    Write-Log "INFO" "OS edition OK: $(((Get-WmiObject -Class Win32_OperatingSystem).Caption))"
}

function Test-AdminPrivilege {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "ERROR" "Script must run as Administrator. Right-click -> Run as Administrator."
        exit $EXIT_NOT_ADMIN
    }
    Write-Log "INFO" "Admin privilege OK"
}

function Test-VirtualizationCapability {
    try {
        $info = Get-ComputerInfo -Property HyperVRequirementVirtualizationFirmwareEnabled `
                                  -ErrorAction Stop
        if (-not $info.HyperVRequirementVirtualizationFirmwareEnabled) {
            Write-Log "ERROR" "BIOS virtualization (VT-x/AMD-V) is disabled. Enable in BIOS/UEFI settings."
            exit $EXIT_NO_VIRT
        }
    } catch {
        Write-Log "WARN" "Could not read HyperV capability via Get-ComputerInfo: $_. Continuing."
    }
    Write-Log "INFO" "Virtualization capability OK"
}

function Test-DiskSpace {
    $minGB = 12
    $drive = Get-PSDrive -Name C
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGB -lt $minGB) {
        Write-Log "ERROR" "Insufficient disk space: ${freeGB}GB free, ${minGB}GB required."
        exit $EXIT_DISK_SPACE
    }
    Write-Log "INFO" "Disk space OK: ${freeGB}GB free"
}

function Test-AdbBinary {
    $adbPath = Join-Path $PSScriptRoot "..\adb\adb.exe"
    $adbPath = [System.IO.Path]::GetFullPath($adbPath)
    if (-not (Test-Path $adbPath)) {
        Write-Log "ERROR" "ADB binary not found at expected path: $adbPath. Ensure adb\ folder is in the deployment bundle."
        exit $EXIT_ADB_MISSING
    }
    Write-Log "INFO" "ADB binary found: $adbPath"
}
```

### Anti-Patterns to Avoid

- **`$ErrorActionPreference = "Continue"`:** The existing `windows_setup.ps1` uses this. It allows errors to silently propagate, leaving the script running after a fatal failure. Phase 1 must set `"Stop"` at the top of `deploy.ps1` and never override it inside a step.
- **Bare `catch {}`:** Catching without logging is the single most common cause of silent deployment failures (documented in CONCERNS.md). Every catch block must call `Write-Log "ERROR"` with the exception message.
- **`Write-Host` outside `Write-Log`:** Any `Write-Host` call outside the logging function means IT cannot diagnose failures from the log file. All output must be routed through `Write-Log`.
- **Using `$env:TEMP` for state:** Temp files can be cleaned by OS or missing after reboot. Registry keys survive all normal cleanup.
- **Dot-sourcing lib files:** Creates global scope pollution. Use `Import-Module` with explicit `Export-ModuleMember`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Registry path existence check | Custom Test-RegistryKey helper | `Test-Path "HKLM:\..."` | Built-in; exact same semantics |
| Log rotation | Custom size-checking logger | Simple `Add-Content` append (Phase 1 scope) | Log files at this scale never overflow; rotation is v2+ |
| Recursive registry key creation | Manual multi-level `New-Item` | `New-Item -Path "HKLM:\SOFTWARE\Baraka\Deploy" -Force` | `-Force` creates intermediate keys automatically |
| Admin elevation re-launch | UAC prompt trick inside script | `#Requires -RunAsAdministrator` at top of deploy.ps1 | PowerShell terminates immediately with a clear message if not admin; cleaner than mid-script elevation |

**Key insight:** Phase 1 is entirely built-in PowerShell primitives. The complexity is in discipline (always log, always guard), not in technology.

---

## Common Pitfalls

### Pitfall 1: `$ErrorActionPreference = "Stop"` Scope Leakage

**What goes wrong:** `$ErrorActionPreference = "Stop"` set in deploy.ps1 does not automatically propagate into module functions called from a separate module scope. Cmdlets inside `Log.psm1` or `Guard.psm1` may still silently continue on error.
**Why it happens:** PowerShell module scope isolation. Each module has its own scope.
**How to avoid:** Set `$ErrorActionPreference = "Stop"` at the top of each `.psm1` file as well as in `deploy.ps1`. Alternatively, pass `-ErrorAction Stop` to every cmdlet call inside modules.
**Warning signs:** A registry write fails silently inside `Invoke-Step` and the guard flag is never set, causing infinite re-runs.

### Pitfall 2: `Get-ComputerInfo` Slow or Missing on Some Editions

**What goes wrong:** `Get-ComputerInfo` can take 5-15 seconds on some older terminals because it enumerates a large amount of WMI data. On certain Windows 10 Home editions it may error.
**Why it happens:** `Get-ComputerInfo` is a thin wrapper over multiple WMI queries; the `-Property` filter helps but doesn't eliminate all overhead.
**How to avoid:** Use the specific `-Property HyperVRequirementVirtualizationFirmwareEnabled` filter. Add a try/catch with a WARN (not ERROR) so a failure here does not abort the deployment — virtualization errors surface naturally when `Enable-WindowsOptionalFeature` is called in Phase 2.
**Warning signs:** Pre-flight takes over 20 seconds; or exits with a false negative on a machine that does support virtualization.

### Pitfall 3: ADB Binary Path Resolution

**What goes wrong:** Using a relative path like `.\adb\adb.exe` inside a step script fails when the script is invoked from a scheduled task (which may use a different working directory).
**Why it happens:** Scheduled tasks do not inherit the working directory of the calling session.
**How to avoid:** Always construct ADB path with `Join-Path $PSScriptRoot "..\adb\adb.exe"` resolved to an absolute path via `[System.IO.Path]::GetFullPath()`. Pass this absolute path to all downstream steps via a script-level variable set in deploy.ps1.
**Warning signs:** ADB pre-flight passes but ADB commands fail in a later step — the path resolved differently in the scheduled task context.

### Pitfall 4: Registry Guard Race on First Run

**What goes wrong:** If `deploy.ps1` is run twice simultaneously (unlikely but possible if IT double-clicks), both instances pass the guard check before either writes the "Done" flag.
**Why it happens:** No mutex around the check-then-set operation.
**How to avoid:** At this scale (single IT person, single terminal), this is acceptable without a mutex. Document that concurrent execution is not supported. A named mutex is a Phase 2+ hardening item if needed.

### Pitfall 5: `Add-Content` Fails When Log Directory Does Not Exist

**What goes wrong:** `Add-Content` to `%ProgramData%\Baraka\deploy.log` fails if the `Baraka` directory has not been created yet — including during the very first log write.
**Why it happens:** `Add-Content` does not create intermediate directories.
**How to avoid:** `Initialize-Log` in `Log.psm1` must call `New-Item -ItemType Directory -Force` on the log directory before any `Add-Content` call. This must be the very first operation in deploy.ps1, before any other logging.

### Pitfall 6: OS SKU Check Misses Windows 11 SKUs

**What goes wrong:** Using only Windows 10 SKU numbers (48, 49, 4, 27) will falsely reject Windows 11 Pro terminals because Windows 11 Pro uses different SKU values in some configurations.
**Why it happens:** Windows 11 reuses most Win10 SKUs but adds new ones. `Win32_OperatingSystem.OperatingSystemSKU` is the most reliable check.
**How to avoid:** Test `Caption` for "Windows 10" or "Windows 11" first, then check SKU for edition (Pro/Enterprise). Or combine: check OS name contains "Windows" and check SKU is not in the Home list (SKU 101 = Home, SKU 100 = Home N).
**Warning signs:** Pre-flight falsely rejects a valid Windows 11 Pro terminal.

---

## Code Examples

Verified patterns from official sources and codebase research:

### Admin Privilege Check (HIGH confidence)

```powershell
# Standard pattern — decades-stable
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

### Registry Key Creation (idempotent)

```powershell
# -Force creates parent keys if missing; does NOT error if key already exists
New-Item -Path "HKLM:\SOFTWARE\Baraka\Deploy" -Force | Out-Null

# Safe value write
Set-ItemProperty -Path "HKLM:\SOFTWARE\Baraka\Deploy" `
                 -Name "Step-Preflight-Done" -Value 1 -Type DWord -Force
```

### Structured Error Handling (CORE-01 pattern)

```powershell
$ErrorActionPreference = "Stop"

try {
    # mutating call here
    New-Item -Path "HKLM:\SOFTWARE\Baraka" -Force | Out-Null
} catch {
    Write-Log "ERROR" "Failed to create registry key: $($_.Exception.Message)"
    exit $EXIT_STEP_FAILED
}
```

### Disk Space Check

```powershell
# Get-PSDrive returns Free in bytes
$freeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
if ($freeGB -lt 12) {
    Write-Log "ERROR" "Only ${freeGB}GB free; 12GB required."
    exit $EXIT_DISK_SPACE
}
```

### Virtualization Check

```powershell
# Get-ComputerInfo with filtered property (faster than no filter)
try {
    $virt = (Get-ComputerInfo -Property HyperVRequirementVirtualizationFirmwareEnabled `
                              -ErrorAction Stop).HyperVRequirementVirtualizationFirmwareEnabled
    if (-not $virt) {
        Write-Log "ERROR" "CPU virtualization (VT-x/AMD-V) is disabled in BIOS/UEFI. Enable it and re-run."
        exit $EXIT_NO_VIRT
    }
} catch {
    Write-Log "WARN" "Cannot verify virtualization capability: $($_.Exception.Message). Continuing."
}
```

---

## State of the Art

| Old Approach (windows_setup.ps1) | New Approach (Phase 1) | Impact |
|----------------------------------|------------------------|--------|
| `$ErrorActionPreference = "Continue"` | `$ErrorActionPreference = "Stop"` + try/catch | Failures are caught rather than silently swallowed |
| `Write-Host` scattered throughout | Single `Write-Log` function routing all output to file + console | Every failure is diagnosable from the log without re-running |
| No idempotency guards | Registry guard per step via `Invoke-Step` wrapper | Safe re-run after any failure; no double-execution |
| No explicit exit codes | Named exit code constants, non-zero per failure category | IT tooling / monitoring can detect and categorize failures |
| `$env:TEMP\baraka-setup-resume.json` for state | `HKLM:\SOFTWARE\Baraka\Deploy\` registry keys | State survives reboots and is accessible to elevated processes |
| Pre-flight inline (partial) | Dedicated `01-preflight.ps1` with 5 distinct checks | Fast-fail before any system mutation; clear per-condition messages |

**Deprecated/outdated:**
- `$ErrorActionPreference = "Continue"`: Never use in deployment scripts. Errors are silently swallowed.
- `Write-Host` for all output: Leaves no audit trail. All output goes through `Write-Log`.
- Relative paths for tools like ADB: Breaks in scheduled-task context. Always use absolute paths constructed from `$PSScriptRoot`.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Pester 5.x (PowerShell native test framework) |
| Config file | `pester.config.ps1` — does not exist yet (Wave 0 gap) |
| Quick run command | `Invoke-Pester -Path tests/ -TagFilter "unit" -Output Minimal` |
| Full suite command | `Invoke-Pester -Path tests/ -Output Detailed` |

**Note:** No test infrastructure currently exists in the project. All test files are Wave 0 gaps. Pester 5.x ships with Windows 10/11 or can be installed via `Install-Module Pester -Force`.

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CORE-01 | `$ErrorActionPreference = "Stop"` is set; every mutating call is in try/catch; catch blocks call Write-Log | unit | `Invoke-Pester -Path tests/Test-ErrorHandling.Tests.ps1 -Output Minimal` | Wave 0 |
| CORE-02 | `Invoke-Step` skips when registry flag is set; sets flag on success; does not re-run completed step | unit | `Invoke-Pester -Path tests/Test-Guard.Tests.ps1 -Output Minimal` | Wave 0 |
| CORE-03 | `Write-Log` writes timestamped line to log file; all step output goes through `Write-Log` | unit | `Invoke-Pester -Path tests/Test-Log.Tests.ps1 -Output Minimal` | Wave 0 |
| CORE-04 | Pre-flight exits with correct code for each failure condition (OS edition, admin, virt, disk, ADB missing) | unit | `Invoke-Pester -Path tests/Test-Preflight.Tests.ps1 -Output Minimal` | Wave 0 |
| CORE-05 | Exit 0 only when all steps complete; each failure path uses distinct non-zero code | unit | `Invoke-Pester -Path tests/Test-ExitCodes.Tests.ps1 -Output Minimal` | Wave 0 |

### Sampling Rate

- **Per task commit:** `Invoke-Pester -Path tests/ -TagFilter "unit" -Output Minimal`
- **Per wave merge:** `Invoke-Pester -Path tests/ -Output Detailed`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `tests/Test-Log.Tests.ps1` — covers CORE-03: Write-Log output format, file creation, multi-level logging
- [ ] `tests/Test-Guard.Tests.ps1` — covers CORE-02: Invoke-Step skip behavior, registry flag set on success
- [ ] `tests/Test-Preflight.Tests.ps1` — covers CORE-04: each of 5 checks exits with correct code; uses mocked WMI/registry
- [ ] `tests/Test-ErrorHandling.Tests.ps1` — covers CORE-01: ErrorActionPreference, catch logging behavior
- [ ] `tests/Test-ExitCodes.Tests.ps1` — covers CORE-05: exit code taxonomy, success vs. failure paths
- [ ] `pester.config.ps1` — shared test configuration
- [ ] Framework install: `Install-Module Pester -Force -SkipPublisherCheck` if Pester < 5.0 detected

---

## Open Questions

1. **Windows 11 SKU completeness**
   - What we know: Windows 10 Pro = SKU 48, Enterprise = SKU 4. Windows 11 reuses most of these.
   - What's unclear: Are there Windows 11 Pro variants with SKU numbers not in the Windows 10 list?
   - Recommendation: During Phase 1 implementation, validate against a Windows 11 Pro machine using `(Get-WmiObject Win32_OperatingSystem).OperatingSystemSKU`. Alternatively, check `Caption -match "Windows 1[01]"` AND `Caption -notmatch "Home"` as a belt-and-suspenders approach.

2. **Minimum viable disk space threshold**
   - What we know: WSA install is ~8-10 GB; APK and tooling add ~200 MB; log files are negligible.
   - What's unclear: Whether 12 GB is tight on store terminals that have other software installed.
   - Recommendation: 12 GB is a safe default. If pre-flight is failing on otherwise-valid terminals, lower to 10 GB.

3. **Pester availability on store terminals**
   - What we know: Pester 3.x ships with Windows 10; Pester 5.x needs explicit install.
   - What's unclear: Whether store terminals have internet access during deployment for `Install-Module`.
   - Recommendation: Tests are for development validation, not run-on-terminal validation. Pester is a dev/CI tool. The deployment bundle does not need to include Pester.

---

## Sources

### Primary (HIGH confidence)

- Baraka codebase: `windows_setup.ps1` — direct inspection of existing patterns and their deficiencies
- `.planning/research/ARCHITECTURE.md` — `Invoke-Step` pattern, registry layout, data flow (confirmed HIGH confidence)
- `.planning/research/STACK.md` — PowerShell 5.1 rationale, registry cmdlets, elevation pattern (confirmed HIGH confidence)
- `.planning/research/SUMMARY.md` — pre-flight check requirements, log path, exit code requirements (confirmed HIGH confidence)
- [PowerShell ErrorActionPreference — Microsoft Docs](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables) — scoping behavior

### Secondary (MEDIUM confidence)

- [Pester 5 Documentation — pester.dev](https://pester.dev/docs/quick-start) — test framework for PowerShell 5.1 compatibility
- [Get-ComputerInfo performance — PowerShell GitHub](https://github.com/PowerShell/PowerShell/issues/13024) — known slowness on some hardware

### Tertiary (LOW confidence)

- Windows 11 SKU completeness — no single authoritative reference; manual verification on target hardware recommended

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — PowerShell 5.1 built-ins, no third-party dependencies
- Architecture: HIGH — Logging, guard, and error-handling patterns are well-established and confirmed from multiple independent sources
- Pitfalls: HIGH — Directly derived from codebase inspection of the existing broken patterns in `windows_setup.ps1` and CONCERNS.md

**Research date:** 2026-03-17
**Valid until:** 2026-09-17 (stable PowerShell primitives; no external dependencies)
