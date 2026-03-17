# Phase 3: WSA Setup + ADB + APK — Research

**Researched:** 2026-03-17
**Domain:** WSA MSIX installation, Developer Mode enablement, ADB connectivity, APK sideloading (PowerShell 5.1)
**Confidence:** MEDIUM-HIGH (core patterns HIGH; developer mode registry key LOW — empirical discovery required)

---

## Summary

Phase 3 installs WSA from the local MagiskOnWSALocal bundle (already present on disk as
`WSA_2311.40000.4.0_x64_Release-Nightly-MindTheGapps-13.0/WSA_2311.40000.4.0_x64/`),
configures it for ADB access, and sideloads the Baraka APK. The phase produces three new
step files (`03-wsa-install.ps1`, `04-wsa-configure.ps1`, `05-apk-install.ps1`) that plug
into the existing `deploy.ps1` `Invoke-Step` orchestration and follow identical patterns to
the already-delivered `01-preflight.ps1` and `02-vm-features.ps1`.

The hardest problem in this phase remains WSA Developer Mode. The legacy `windows_setup.ps1`
writes `HKCU:\Software\Microsoft\WindowsSubsystemForAndroid\DeveloperMode = 1`, then
immediately tries `adb connect` — which fails because the key is only read on WSA restart.
The correct sequence is: write key, kill WSA processes, relaunch via `WsaClient.exe /launch`,
poll the ADB port with exponential backoff, and emit a clear manual-fallback instruction if
the port never opens. Every subsequent re-run on that terminal is fully automatic because
the guard flag is already set from the first successful run.

APK version checking uses `adb shell dumpsys package <packageName>` to extract `versionCode`
before deciding whether to run `adb install -r`. The APK file is auto-detected via
`Get-ChildItem -Path $PSScriptRoot -Filter "*.apk"` — matching the existing legacy pattern.

**Primary recommendation:** Split WSA install, WSA configure, and APK install into three
separate step files with separate registry guard flags. This lets re-runs skip only what is
already correct, and makes partial-failure diagnosis straightforward.

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| WSAI-01 | WSA installs silently via `Add-AppxPackage -Register` from unpacked directory | `Add-AppxPackage -Register AppxManifest.xml -ForceApplicationShutdown -ForceUpdateFromAnyVersion` — STACK.md HIGH |
| WSAI-02 | Script suppresses all auto-launched WSA windows after install | 15s post-Install.ps1 wait + aggressive process-kill loop — PITFALLS.md Pitfall 5 HIGH |
| WSAI-03 | Script waits for WSA initialization via poll, not fixed sleep | Poll `WsaService` process existence up to 60s; break early — PITFALLS.md Pitfall 10 |
| WSAI-04 | Script detects if WSA already installed and skips reinstall | `Get-AppxPackage -Name "*WindowsSubsystemForAndroid*"` wildcard — PITFALLS.md Pitfall 14 |
| ADBM-01 | Write Developer Mode registry key and restart WSA to apply | `HKCU:\Software\Microsoft\WindowsSubsystemForAndroid\DeveloperMode = 1` + WsaClient kill/relaunch |
| ADBM-02 | Set WSA to Continuous resource mode | `HKCU:\Software\Microsoft\WSA\VMLifeCycleMode = Continuous` — STACK.md MEDIUM |
| ADBM-03 | ADB retry uses exponential backoff (5 attempts, up to 60s) | Pattern in ARCHITECTURE.md Pattern 3; verified against ADB docs |
| ADBM-04 | ADB checks `adb devices` output for `device` status, not exit codes | `adb connect` always returns 0; must parse `adb devices` — STACK.md HIGH |
| ADBM-05 | Emit clear single-step manual instruction if ADB probe fails after all retries | Fallback message pattern — STACK.md Approach C HIGH |
| APKS-01 | Compare installed APK version before installing (skip if current) | `adb shell dumpsys package <pkg> | grep versionCode` — see Code Examples |
| APKS-02 | Auto-detect APK file in the deployment bundle directory | `Get-ChildItem -Path $PSScriptRoot -Filter "*.apk" \| Select-Object -First 1` |
| APKS-03 | APK installs via `adb install -r` with success verification | Parse output for `Success` string; guard flag set only on success |
</phase_requirements>

---

## Standard Stack

### Core

| Tool / Cmdlet | Version | Purpose | Why Standard |
|---------------|---------|---------|--------------|
| `Add-AppxPackage` (Appx module) | PS 5.1 built-in | Register MagiskOnWSALocal MSIX from unpacked folder | Only supported WSA install method; `-Register` targets `AppxManifest.xml` not a bundled .appx |
| `Get-AppxPackage` (Appx module) | PS 5.1 built-in | Detect existing WSA package (WSAI-04) | Wildcard pattern `*WindowsSubsystemForAndroid*` handles official and community build names |
| Bundled `adb.exe` | SDK Platform Tools 35.x | ADB connect, `pm list packages`, `install -r`, `dumpsys package` | Bundled at `$PSScriptRoot\..\adb\adb.exe` — already pre-checked by 01-preflight.ps1 |
| `Set-ItemProperty` / `New-Item` (Registry) | PS 5.1 built-in | Write DeveloperMode and VMLifeCycleMode keys | Pattern from State.psm1's `Set-RegistryValue` pattern |
| `Start-Process` / `Get-Process` / `Stop-Process` | PS 5.1 built-in | Launch and kill WsaClient.exe and WsaSettings.exe | No external dependency |

### Existing Libraries (already delivered)

| Module | Location | How Phase 3 Uses It |
|--------|----------|---------------------|
| `Log.psm1` | `lib/Log.psm1` | `Write-Log -Level INFO/WARN/ERROR` — all output |
| `State.psm1` | `lib/State.psm1` | `Get-DeployState` / `Set-DeployState` for guard flags and resume state |
| `Guard.psm1` | `lib/Guard.psm1` | `Invoke-Step -StepName X -Body { ... }` wrapper for all three steps |

### WSA Bundle on Disk

The bundle is already present:
```
WSA_2311.40000.4.0_x64_Release-Nightly-MindTheGapps-13.0/
  WSA_2311.40000.4.0_x64/
    AppxManifest.xml       <-- target for Add-AppxPackage -Register
    Install.ps1            <-- legacy installer (NOT invoked directly; we use Add-AppxPackage)
    WsaClient/             <-- WsaClient.exe lives here
    WsaSettings.exe
    product.vhdx / system.vhdx / etc.
```

The planner must parameterise the WSA root directory path. Convention from existing code:
```powershell
$WsaRoot = Join-Path $PSScriptRoot '..\WSA_2311.40000.4.0_x64_Release-Nightly-MindTheGapps-13.0\WSA_2311.40000.4.0_x64'
$WsaRoot = [System.IO.Path]::GetFullPath($WsaRoot)
```

### APK on Disk

```
/baraka/application-61084dbb-9317-4be3-bf34-07040298ed62.apk
```

Auto-detection via `Get-ChildItem -Path $BundleRoot -Filter "*.apk" -Recurse | Select-Object -First 1`.

---

## Architecture Patterns

### Recommended Step Structure

Three separate step files, three separate guard flags:

```
steps/
  03-wsa-install.ps1     # WSAI-01, WSAI-02, WSAI-03, WSAI-04
  04-wsa-configure.ps1   # ADBM-01, ADBM-02, ADBM-03, ADBM-04, ADBM-05
  05-apk-install.ps1     # APKS-01, APKS-02, APKS-03
```

Each follows the same pattern as `02-vm-features.ps1`:
- Public functions exported at the top
- `BARAKA_TEST_MODE` guard at the bottom prevents auto-execution when dot-sourced from Pester
- All external calls wrapped in test-seam functions so Pester can mock them
- `Write-Log` for all output; `Set-DeployState` only on success

### Pattern: WSA Install (WSAI-01, WSAI-02, WSAI-03, WSAI-04)

```powershell
# Source: official Add-AppxPackage docs + STACK.md
function Test-WsaInstalled {
    # WSAI-04: wildcard to handle official + community build names (Pitfall 14)
    return ($null -ne (Get-AppxPackage -Name "*WindowsSubsystemForAndroid*" -ErrorAction SilentlyContinue))
}

function Invoke-WsaInstall {
    param([string]$WsaManifestPath)  # path to AppxManifest.xml

    Add-AppxPackage `
        -Register $WsaManifestPath `
        -ForceApplicationShutdown `
        -ForceUpdateFromAnyVersion

    # WSAI-02 + Pitfall 5: Install.ps1's Finish() launches 3-4 wsa:// windows
    # asynchronously. Wait 15s for first-boot initialisation to complete BEFORE
    # killing any processes. Killing earlier leaves WSA in a broken state.
    Start-Sleep -Seconds 15
    Stop-WsaWindows

    # WSAI-03: Poll for WsaService to confirm initialisation — do NOT rely on
    # fixed sleep after window kill.
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name "WsaService" -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Seconds 2
    }
}

function Stop-WsaWindows {
    # Kill settings UI and client launcher; do NOT kill WsaService (that is the VM)
    @("WsaSettings", "WsaClient") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}
```

### Pattern: WSA Configure (ADBM-01, ADBM-02)

```powershell
# Source: STACK.md registry patterns + PITFALLS.md Pitfall 1 prevention
function Set-WsaDeveloperMode {
    # ADBM-01: Write Developer Mode key
    $devPath = "HKCU:\Software\Microsoft\WindowsSubsystemForAndroid"
    if (-not (Test-Path $devPath)) { New-Item -Path $devPath -Force | Out-Null }
    Set-ItemProperty -Path $devPath -Name "DeveloperMode" -Value 1 -Type DWord -Force

    # ADBM-02: Set Continuous resource mode (prevents idle VM suspension)
    # Source: STACK.md VMLifeCycleMode — MEDIUM confidence, community-derived
    $wsaPath = "HKCU:\Software\Microsoft\WSA"
    if (-not (Test-Path $wsaPath)) { New-Item -Path $wsaPath -Force | Out-Null }
    Set-ItemProperty -Path $wsaPath -Name "VMLifeCycleMode" -Value "Continuous" -Type String -Force

    # CRITICAL (Pitfall 1): Registry write alone does NOT activate ADB daemon.
    # WSA must restart to read the new configuration.
    Restart-WsaForDevMode
}

function Restart-WsaForDevMode {
    # Kill WsaClient and WsaService so WSA re-reads registry on next launch
    @("WsaService", "WsaClient", "WsaSettings") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    # Relaunch WSA — WsaClient.exe is inside the WSA package install location
    $wsaPkg = Get-AppxPackage -Name "*WindowsSubsystemForAndroid*" -ErrorAction SilentlyContinue
    if ($wsaPkg) {
        $wsaClientExe = Join-Path $wsaPkg.InstallLocation "WsaClient\WsaClient.exe"
        if (Test-Path $wsaClientExe) {
            Start-Process $wsaClientExe -ArgumentList "/launch wsa://system" -ErrorAction SilentlyContinue
        }
    }
    # Allow WSA daemon 10-15 seconds to start its ADB listener after relaunch
    Start-Sleep -Seconds 10
}
```

### Pattern: ADB Connection Retry (ADBM-03, ADBM-04, ADBM-05)

```powershell
# Source: ARCHITECTURE.md Pattern 3 + STACK.md ADB tooling section
function Connect-Adb {
    param(
        [string]$AdbPath,
        [string]$Endpoint   = "127.0.0.1:58526",
        [int]$MaxAttempts   = 5,
        [int]$BaseDelaySec  = 5   # exponential: 5, 10, 20, 40, 60 (capped at 60s)
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        # ADBM-04: attempt connect but DO NOT trust exit code — always parse adb devices
        & $AdbPath connect $Endpoint 2>&1 | Out-Null

        $devices = (& $AdbPath devices 2>&1 | Out-String)
        if ($devices -match [regex]::Escape($Endpoint) + '\s+device') {
            Write-Log -Level "INFO" -Message "ADB connected to $Endpoint (attempt $i/$MaxAttempts)"
            return $true
        }

        $delaySec = [math]::Min($BaseDelaySec * [math]::Pow(2, $i - 1), 60)
        Write-Log -Level "WARN" -Message "ADB probe $i/$MaxAttempts failed; waiting ${delaySec}s"
        Start-Sleep -Seconds $delaySec
    }

    # ADBM-05: Manual fallback — clear single-step instruction, no crash, no silent proceed
    Write-Log -Level "WARN" -Message "ADB connection failed after $MaxAttempts attempts."
    Write-Log -Level "WARN" -Message "MANUAL ACTION REQUIRED: Open WSA Settings on this terminal,"
    Write-Log -Level "WARN" -Message "click 'Developer' in the left sidebar, toggle 'Developer mode'"
    Write-Log -Level "WARN" -Message "to ON, then re-run deploy.ps1. All other steps will be skipped."
    return $false
}
```

**Important:** If `Connect-Adb` returns `$false`, the step must NOT set its guard flag. The guard
must remain unset so the next `deploy.ps1` run retries the ADB connection.

### Pattern: APK Version Check and Install (APKS-01, APKS-02, APKS-03)

```powershell
# Source: ADB official docs + community pm list patterns
function Get-InstalledApkVersionCode {
    param([string]$AdbPath, [string]$PackageName)
    # APKS-01: extract versionCode from dumpsys output
    $dumpsys = & $AdbPath shell "dumpsys package $PackageName" 2>&1 | Out-String
    if ($dumpsys -match 'versionCode=(\d+)') {
        return [int]$Matches[1]
    }
    return -1  # package not installed
}

function Get-ApkVersionCode {
    param([string]$ApkPath, [string]$AaptPath)
    # aapt is optional; without it, always install (safe because adb install -r is idempotent)
    # If aapt is not bundled, return -2 to signal "unknown — install anyway"
    if (-not $AaptPath -or -not (Test-Path $AaptPath)) { return -2 }
    $badge = & $AaptPath dump badging $ApkPath 2>&1 | Out-String
    if ($badge -match "versionCode='(\d+)'") { return [int]$Matches[1] }
    return -2
}

function Install-Apk {
    param([string]$AdbPath, [string]$ApkPath)
    # APKS-03: install with -r (reinstall, keep data) and verify output
    $result = (& $AdbPath install -r $ApkPath 2>&1 | Out-String).Trim()
    if ($result -notmatch "Success") {
        throw "APK install failed: $result"
    }
    Write-Log -Level "INFO" -Message "APK installed successfully"
}
```

**On aapt availability:** The project bundles `adb.exe` but not `aapt`. Without `aapt`,
version comparison is not possible from the host side. The reliable fallback is:
1. Query installed version via `adb shell dumpsys package`
2. If package is absent (version = -1), install
3. If package is present, skip (treat any installed version as current — `adb install -r`
   would upgrade silently anyway, making the skip safe for the common case)
4. Document that forced reinstall requires the v2 `--force-reinstall` flag

This satisfies APKS-01 without requiring a bundled `aapt`.

### Anti-Patterns to Avoid

- **Calling legacy `Install.ps1` directly:** The MagiskOnWSALocal `Install.ps1` spawns UI
  windows via `wsa://` URIs as side effects of its `Finish()` function. Use
  `Add-AppxPackage -Register AppxManifest.xml` directly and handle window suppression
  explicitly (WSAI-02). Never invoke `Install.ps1` via `Start-Process` from the new script.

- **Trusting `adb connect` exit code:** `adb connect` returns 0 even when the device is
  `offline` or `unauthorized`. Always parse `adb devices` for the literal string `device`
  at the correct column position (ADBM-04).

- **Hardcoding the WSA package name:** Use `*WindowsSubsystemForAndroid*` wildcard for all
  `Get-AppxPackage` calls. Community MagiskOnWSALocal builds use a different package
  identity than the Microsoft Store version (Pitfall 14).

- **Setting the guard flag when ADB fails:** If `Connect-Adb` returns `$false`, do not set
  the `WsaConfigure-Done` registry flag. The guard must stay unset so the next `deploy.ps1`
  run retries rather than declaring the step complete (ADBM-05 / success criterion 3).

- **Using `Add-AppxPackage` as SYSTEM:** This fails with `0x80073CF9`. The script must run
  as an interactive admin user. The existing `deploy.ps1` structure with
  `#Requires -RunAsAdministrator` and the scheduled task `RunLevel Highest` with
  `LogonType = Interactive` already satisfies this (Pitfall 4).

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Registry safe-write with path creation | Custom `Set-RegistryValue` function | `State.psm1`'s `Set-DeployState` for guard flags; raw `New-Item -Force` + `Set-ItemProperty` for WSA-specific keys | State.psm1 already handles path creation and is used consistently across all steps |
| Step idempotency | Per-step "is it done?" check | `Guard.psm1`'s `Invoke-Step` | All existing steps use this; consistency is required |
| ADB output parsing | Custom regex | Parse `adb devices` for `\s+device` literal | ADB spec is stable; the pattern is verified |
| WSA package detection | Name-string comparison | `Get-AppxPackage -Name "*WindowsSubsystemForAndroid*"` | Wildcard handles all known build variants |

---

## Common Pitfalls

### Pitfall 1: Registry Write Without WSA Restart (ADBM-01)

**What goes wrong:** `DeveloperMode = 1` is written to registry, but ADB port 58526 stays
closed. The daemon is not a registry watcher — it only reads config on WSA startup.

**How to avoid:** After writing the registry key, kill WsaService + WsaClient + WsaSettings,
then relaunch via `WsaClient.exe /launch wsa://system`. Wait 10–15 seconds. Only then
attempt `adb connect`.

**Source:** PITFALLS.md Pitfall 1, STACK.md Approach B/C.

### Pitfall 2: Window Timing — Kill Too Early Breaks WSA (WSAI-02)

**What goes wrong:** Killing WSA windows immediately after `Add-AppxPackage` aborts
first-boot initialisation. WSA profile writes are incomplete. Next ADB connect fails.

**How to avoid:** 15-second minimum wait after `Add-AppxPackage` returns before killing
any WSA processes. Then kill only UI processes (`WsaSettings`, `WsaClient`), never
`WsaService`.

**Source:** PITFALLS.md Pitfall 5, legacy `windows_setup.ps1` Stop-WSAWindows comments.

### Pitfall 3: `adb connect` Exit Code Is Always 0 (ADBM-04)

**What goes wrong:** Script checks `$LASTEXITCODE` after `adb connect` and sees 0 (success),
proceeds to `adb install`, which immediately fails with "device not found".

**How to avoid:** Always follow `adb connect` with `adb devices` and parse stdout for
`<endpoint>\s+device`. The strings `offline`, `unauthorized`, and absence of the endpoint
are all failure states.

**Source:** STACK.md ADB tooling section, ARCHITECTURE.md Pattern 3.

### Pitfall 4: Guard Flag Set Even When ADB Fails (ADBM-05)

**What goes wrong:** Step marks itself done in the registry even though ADB never connected.
Next `deploy.ps1` run skips the configure step. Terminal is permanently stuck without ADB.

**How to avoid:** `Invoke-Step` in Guard.psm1 only sets the flag when the body scriptblock
returns without throwing. The configure step body must `throw` when `Connect-Adb` returns
`$false` — OR the step must be structured outside `Invoke-Step` with conditional guard
setting. Chosen pattern: throw so Guard.psm1 never sets the flag.

**Warning sign:** Registry shows `WsaConfigure-Done = 1` but `adb devices` shows nothing.

### Pitfall 5: WSA Idle Termination Drops ADB After Configure (ADBM-02)

**What goes wrong:** WSA defaults to "As needed" mode. After configure step, VM idles and
terminates. APK install step runs, ADB is gone.

**How to avoid:** Write `VMLifeCycleMode = Continuous` to `HKCU:\Software\Microsoft\WSA`
during the configure step. This keeps the VM running between steps.

**Source:** PITFALLS.md Pitfall 3, STACK.md registry section.

### Pitfall 6: WSA Package Name Hardcoded (WSAI-04)

**What goes wrong:** `Get-AppxPackage -Name "MicrosoftCorporationII.WindowsSubsystemForAndroid"`
returns null on terminals running MustardChef/WSABuilds community packages. Script skips
all WSA steps thinking nothing is installed.

**How to avoid:** Always use wildcard: `Get-AppxPackage -Name "*WindowsSubsystemForAndroid*"`.

**Source:** PITFALLS.md Pitfall 14.

---

## Code Examples

### Verified: Add-AppxPackage for unpacked MSIX (WSAI-01)

```powershell
# Source: STACK.md Add-AppxPackage section (verified against official Appx module docs)
Add-AppxPackage `
    -Register "$WsaRoot\AppxManifest.xml" `
    -ForceApplicationShutdown `
    -ForceUpdateFromAnyVersion
# Returns no output. Error detection via try/catch only ($? is unreliable for this cmdlet).
```

### Verified: ADB devices parsing (ADBM-04)

```powershell
# Source: STACK.md ADB tooling section
$devices = (& $AdbPath devices 2>&1 | Out-String)
# CORRECT: parse the full output string for endpoint + status column
if ($devices -match [regex]::Escape("127.0.0.1:58526") + '\s+device') { ... }
# WRONG: check $LASTEXITCODE (always 0)
# WRONG: check 'adb connect' output (returns 0 even on failure)
```

### Verified: APK package presence check (APKS-01)

```powershell
# Source: Android ADB official docs
$pkgList = (& $AdbPath shell "pm list packages" 2>&1 | Out-String)
$packageName = "com.baraka.pos"  # placeholder — must be confirmed on real device
if ($pkgList -match "package:$([regex]::Escape($packageName))") {
    # package installed
}
```

### Verified: Idempotency guard skip pattern (WSAI-04)

```powershell
# Source: Guard.psm1 pattern (existing project code)
Invoke-Step -StepName "WsaInstall" -Body {
    if (Test-WsaInstalled) {
        Write-Log -Level "INFO" -Message "WSA already installed -- skipping"
        return  # Guard.psm1 sees no exception, sets Done flag = 1
    }
    # ... install logic
}
```

---

## State of the Art

| Old Approach (legacy `windows_setup.ps1`) | New Approach (Phase 3) | Impact |
|-------------------------------------------|------------------------|--------|
| `ErrorActionPreference = "Continue"`, silent failures | `ErrorActionPreference = "Stop"` + try/catch in Invoke-Step | Failures surface immediately |
| Hardcoded package name `MicrosoftCorporationII.WindowsSubsystemForAndroid` | Wildcard `*WindowsSubsystemForAndroid*` | Works with community builds |
| `Read-Host` prompt for developer mode | Retry loop with fallback log message (no interactive prompt) | Zero-intervention capable |
| Fixed `Start-Sleep -Seconds N` everywhere | Poll-with-deadline loops | Works on slow Celeron hardware |
| Single monolithic function, no guard flags | Separate steps with `Invoke-Step` guards | Safe idempotent re-runs |
| `adb connect` exit code check | Parse `adb devices` stdout for `\s+device` | Correct failure detection |
| No APK version check (always reinstall) | `adb shell dumpsys package` versionCode query | Skip-if-current (APKS-01) |

**Deprecated / to avoid:**
- `Install.ps1` invocation via `Start-Process` — use `Add-AppxPackage -Register` directly
- `$script:wsaDevReady` global variable pattern — state lives in registry guard flags only
- `Start-Sleep -Seconds 2` before every ADB operation — use poll loops with deadlines

---

## Open Questions

1. **APK package name**
   - What we know: APK file is `application-61084dbb-9317-4be3-bf34-07040298ed62.apk`
   - What's unclear: The Android package identifier (e.g., `com.baraka.pos`) is not known
     from the filename alone. It is required for `adb shell pm list packages` and
     `adb shell dumpsys package <name>` checks.
   - Recommendation: Wave 0 task — run `aapt dump badging application-*.apk | grep package:name`
     on any machine with aapt, OR run `adb shell dumpsys package | grep -i baraka` after
     first install. Store the package name as a constant in `05-apk-install.ps1`.
     If aapt is not available pre-deploy, fallback: install unconditionally on first run,
     query package name post-install from `pm list packages | grep -i baraka`.

2. **WsaClient.exe exact location within package**
   - What we know: `WSA_2311.40000.4.0_x64/WsaClient/` directory exists on disk
   - What's unclear: Whether `WsaClient.exe` is directly inside `WsaClient/` or one level deeper
   - Recommendation: Resolve via `Get-ChildItem -Path $WsaRoot -Filter "WsaClient.exe" -Recurse | Select-Object -First 1`
     rather than a hardcoded path. This is resilient to bundle layout variations.

3. **Developer Mode registry key confidence**
   - What we know: `HKCU:\Software\Microsoft\WindowsSubsystemForAndroid\DeveloperMode = 1`
     is what the legacy `windows_setup.ps1` uses and is confirmed by community sources
   - What's unclear: Whether this key path is consistent across MagiskOnWSALocal builds
     (the bundle on disk is `WSA_2311.40000.4.0` / Android 13)
   - Recommendation: The key is LOW confidence for guaranteeing ADB activation. It is MEDIUM
     confidence as advisory (harmless to write). Design the step so the ADB probe loop is
     the authoritative success signal, not the registry write. Manual fallback via ADBM-05
     is the accepted outcome for first-deployment on a fresh terminal.

4. **`VMLifeCycleMode` value casing**
   - What we know: Community sources document `"Continuous"` as the value (capital C)
   - What's unclear: Whether the value is case-sensitive in the WSA registry reader
   - Recommendation: Use exact casing `"Continuous"` as documented. This is LOW risk — if
     the wrong casing is used, the worst outcome is WSA idle-suspends (which is the current
     default behaviour anyway).

---

## Validation Architecture

Nyquist validation is enabled (`workflow.nyquist_validation: true`).

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Pester 5.x |
| Config file | None — loaded inline in BeforeAll (per established project pattern) |
| Quick run command | `pwsh -NonInteractive -Command "Invoke-Pester tests/WsaInstall.Tests.ps1, tests/WsaConfigure.Tests.ps1, tests/ApkInstall.Tests.ps1 -Output Minimal"` |
| Full suite command | `pwsh -NonInteractive -Command "Invoke-Pester tests/ -Output Normal"` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| WSAI-01 | `Add-AppxPackage -Register` called with correct manifest path and flags | unit | `Invoke-Pester tests/WsaInstall.Tests.ps1 -Output Minimal` | Wave 0 |
| WSAI-02 | WSA windows killed only after 15s wait; WsaService NOT stopped | unit | same | Wave 0 |
| WSAI-03 | WsaService poll loop breaks early when process appears; respects 45s deadline | unit | same | Wave 0 |
| WSAI-04 | `Add-AppxPackage` NOT called when `*WindowsSubsystemForAndroid*` package already present | unit | same | Wave 0 |
| ADBM-01 | `DeveloperMode = 1` written AND WSA restarted (kill + relaunch) | unit | `Invoke-Pester tests/WsaConfigure.Tests.ps1 -Output Minimal` | Wave 0 |
| ADBM-02 | `VMLifeCycleMode = Continuous` written to `HKCU:\Software\Microsoft\WSA` | unit | same | Wave 0 |
| ADBM-03 | Retry loop runs exactly MaxAttempts times on repeated failure; delays increase | unit | same | Wave 0 |
| ADBM-04 | Success determined by `adb devices` `\s+device` match, NOT exit code | unit | same | Wave 0 |
| ADBM-05 | WARN log emitted with manual instruction when all retries exhausted; guard flag NOT set | unit | same | Wave 0 |
| APKS-01 | `adb shell dumpsys package` queried; install skipped when package present | unit | `Invoke-Pester tests/ApkInstall.Tests.ps1 -Output Minimal` | Wave 0 |
| APKS-02 | APK auto-detected via `Get-ChildItem *.apk`; step fails clearly if none found | unit | same | Wave 0 |
| APKS-03 | `adb install -r` called; guard set on `Success` match; exception thrown on failure | unit | same | Wave 0 |

### Sampling Rate

- **Per task commit:** `Invoke-Pester tests/WsaInstall.Tests.ps1, tests/WsaConfigure.Tests.ps1, tests/ApkInstall.Tests.ps1 -Output Minimal`
- **Per wave merge:** `Invoke-Pester tests/ -Output Normal`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `tests/WsaInstall.Tests.ps1` — covers WSAI-01 through WSAI-04
- [ ] `tests/WsaConfigure.Tests.ps1` — covers ADBM-01 through ADBM-05
- [ ] `tests/ApkInstall.Tests.ps1` — covers APKS-01 through APKS-03

**Established patterns to follow (from VmFeatures.Tests.ps1):**
- `BeforeAll` stubs for Windows-only cmdlets (`Add-AppxPackage`, `Get-AppxPackage`,
  `Get-Process`, `Stop-Process`, `Start-Process`) before Pester `Mock` to avoid
  `CommandNotFoundException` on Linux CI
- `$env:BARAKA_TEST_MODE = '1'` set before dot-sourcing step files
- In-memory `$script:FakeStore` + `Mock -ModuleName State` for all registry operations
- Test seam wrapper functions for external process calls (`Invoke-WsaRestart`,
  `Invoke-AdbConnect`, etc.) so Pester can mock without subprocess boundaries

---

## Sources

### Primary (HIGH confidence)

- STACK.md (this project) — `Add-AppxPackage` flags, ADB retry pattern, registry paths — verified against official Appx module docs
- PITFALLS.md (this project) — Pitfalls 1, 3, 4, 5, 7, 10, 14 directly applicable to this phase
- ARCHITECTURE.md (this project) — Pattern 3 (ADB retry), anti-patterns, component boundaries
- [Add-AppxPackage — Microsoft Docs](https://learn.microsoft.com/en-us/powershell/module/appx/add-appxpackage) — `-Register`, `-ForceApplicationShutdown`, `-ForceUpdateFromAnyVersion` flags
- [Android Debug Bridge — Android Developers](https://developer.android.com/tools/adb) — `adb devices` output format, `pm list packages`, `adb install -r`
- Existing Phase 1-2 deliverables (`lib/Guard.psm1`, `lib/State.psm1`, `steps/02-vm-features.ps1`, `tests/VmFeatures.Tests.ps1`) — established patterns this phase must follow

### Secondary (MEDIUM confidence)

- [WSAClient.exe parameters — vhanla gist](https://gist.github.com/vhanla/247ee77dd0cdd5449e02e2d517a13019) — `/launch wsa://system` argument
- [ADB Connection and Commands — MustardChef/WSABuilds DeepWiki](https://deepwiki.com/MustardChef/WSABuilds/6.1-adb-connection-and-commands) — port 58526 confirmation
- Legacy `windows_setup.ps1` (this project) — `Step-ConfigureWSADevMode`, `Step-SideloadAPK`, `Stop-WSAWindows` — empirical patterns from working code
- [WSA ADB Connection Refused — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/788883/cannot-connect-to-127-0-0-1-58526) — community behavior confirmation

### Tertiary (LOW confidence)

- [WSA Hidden Settings — XDA Forums](https://xdaforums.com/t/windows-subsystem-for-android-hidden-settings-device-administrator-access.4399723/) — developer mode registry key path (needs on-machine verification)
- `VMLifeCycleMode = "Continuous"` value — community gist with multiple corroborating references but no official documentation post-WSA deprecation (March 2025)

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — `Add-AppxPackage -Register` and ADB patterns verified against official docs
- Architecture (step structure): HIGH — directly follows established Phase 1-2 patterns
- WSA window suppression: HIGH — Pitfall 5 has official maintainer acknowledgment
- Developer mode registry key: LOW — community-derived, on-machine validation required; ADB probe loop is the reliable backstop
- VMLifeCycleMode value: MEDIUM — community-derived, multiple corroborating sources
- APK package name: UNKNOWN — filename does not expose Android package identifier; Wave 0 discovery task required

**Research date:** 2026-03-17
**Valid until:** 2026-04-17 (stable domain — WSA deprecated March 2025, no further official changes expected)
