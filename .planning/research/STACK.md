# Technology Stack

**Project:** Baraka POS Deployment Hardening
**Dimension:** Windows automation — WSA, ADB, PowerShell
**Researched:** 2026-03-17

---

## Recommended Stack

### Scripting Runtime

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Windows PowerShell | 5.1 (built-in on Win 10/11) | Primary orchestration script | Ships with Windows, no install step, full access to DISM, Appx, and registry cmdlets. PowerShell 7+ is NOT recommended — it does not include the Windows-only modules (Appx, DISM) that this project needs |
| cmd.exe / schtasks.exe | Built-in | Scheduling resume-after-reboot tasks | PowerShell `Register-ScheduledTask` requires a user context; `schtasks.exe /ru SYSTEM` runs headless without credentials |

**Confidence: HIGH** — Verified via Microsoft official documentation.

### Windows Feature Management

| Technology | Cmdlet | Purpose | Why |
|------------|--------|---------|-----|
| DISM PowerShell module | `Enable-WindowsOptionalFeature` | Enable Virtual Machine Platform, Hyper-V prerequisites for WSA | Official Microsoft cmdlet, returns `RestartNeeded` property for programmatic reboot detection. Use `-NoRestart` to suppress automatic reboot, then inspect return value. `-All` flag enables parent features automatically |

Feature names required for WSA:
- `VirtualMachinePlatform` — mandatory for WSA
- `Microsoft-Windows-Subsystem-Linux` — NOT needed for WSA, do not enable
- `HypervisorPlatform` — needed if VirtualMachinePlatform alone is insufficient on some hardware

Unattended pattern:
```powershell
$result = Enable-WindowsOptionalFeature -Online -FeatureName 'VirtualMachinePlatform' -All -NoRestart
if ($result.RestartNeeded) {
    # write resume checkpoint, then reboot
}
```

**Confidence: HIGH** — Verified against official DISM module documentation (updated 2025-05-14).

### WSA Package Installation

| Technology | Cmdlet / Method | Purpose | Why |
|------------|-----------------|---------|-----|
| Appx PowerShell module | `Add-AppxPackage -Register -ForceApplicationShutdown -ForceUpdateFromAnyVersion` | Install MagiskOnWSALocal from unpacked directory | `-Register` installs from the extracted folder (AppxManifest.xml path), not a bundled .appx; `-ForceApplicationShutdown` prevents conflicts if WSA is already running; `-ForceUpdateFromAnyVersion` handles re-deployment without version order constraints |
| `Get-AppxPackage` | Query | Detect existing WSA installation | Check before install to handle upgrade vs. fresh install paths |

Correct invocation for MagiskOnWSALocal:
```powershell
Add-AppxPackage `
    -Register "$wsaRoot\AppxManifest.xml" `
    -ForceApplicationShutdown `
    -ForceUpdateFromAnyVersion
```

Note: `Add-AppxPackage` produces NO output object (returns `None`). Error detection must use `$LASTEXITCODE`, try/catch, or `$?`.

**Confidence: HIGH** — Verified against official Appx module documentation (updated 2025-05-14). MagiskOnWSALocal uses exactly this pattern per its own installer.

### WSA Process Control

| Method | Purpose | Why |
|--------|---------|-----|
| `Get-Process WsaClient` / `Start-Process WsaClient` | Launch WSA to ensure it is running before ADB connects | ADB on port 58526 is only accessible when WSA is actively running; port is not open when WSA is stopped |
| `WsaClient.exe /restart` | Restart WSA VM | Faster than kill-and-relaunch when stale state is detected |
| `WsaClient.exe /shutdown` | Stop WSA cleanly | Required before re-registration; avoids lock conflicts |
| URI `wsa-client://developer-settings` | Open developer settings pane | Can be invoked via `Start-Process "wsa-client://developer-settings"` — opens the UI panel but does NOT toggle the setting programmatically |

**Confidence: MEDIUM** — WSAClient.exe parameters sourced from community documentation (vhanla gist). Not verified against official Microsoft docs (which were removed when WSA was deprecated March 2025).

### WSA Developer Mode — The Core Problem

This is the hardest piece. Research uncovered three approaches with different confidence levels:

#### Approach A: ADB via `settings put global` after first-time manual enable (MEDIUM confidence)

Once developer mode has been enabled at least once (either manually or via the approaches below), the Android runtime's USB debugging state can be toggled via:
```
adb shell settings put global development_settings_enabled 1
adb shell settings put global adb_enabled 1
```
This works on standard Android including Android 11-15 and has been confirmed functional. The chicken-and-egg problem: ADB is not available until developer mode is already on. This approach is only useful to re-enable ADB if it gets disabled, not for first-run automation.

#### Approach B: Windows registry write (LOW confidence — needs on-machine verification)

The known WSA registry locations are:
- `HKCU:\Software\Microsoft\WSA\VMLifeCycleMode`
- `HKLM:\Software\Microsoft\WSA\VMLifeCycleMode`

No public documentation maps a specific registry key to "Developer mode enabled" for WSA. Microsoft never published a registry API for WSA developer settings. This approach requires empirical discovery on a real machine: enable developer mode via UI, then export `HKCU:\Software\Microsoft\WSA` and `HKLM:\Software\Microsoft\WSA` to discover what changed.

Recommended investigation command (run on a terminal with developer mode ON):
```powershell
Get-ChildItem -Path 'HKCU:\Software\Microsoft\WSA' -Recurse
Get-ChildItem -Path 'HKLM:\Software\Microsoft\WSA' -Recurse
```

#### Approach C: ADB probe loop with first-run bootstrap (RECOMMENDED — HIGH confidence for the overall strategy)

The reliable automation pattern for fresh machines:
1. Install WSA (via `Add-AppxPackage`)
2. Start WSA (via `Start-Process WsaClient.exe`)
3. Attempt `adb connect localhost:58526` in a retry loop with 5-second waits (up to ~60 seconds)
4. If connection fails after timeout, write a clear error message instructing the operator to manually enable developer mode once, then re-run the script
5. Script records a state file (e.g., `C:\baraka-deploy\state.json`) so re-running skips already-completed steps

This is the honest approach: the first deployment on a new machine may need one manual step. Every subsequent deployment on that machine (or a cloned state) is fully automated.

**Rationale:** No community project has achieved reliable zero-touch developer mode enablement on stock WSA/MagiskOnWSA without root — the documented methods all require either pre-existing ADB access (circular) or registry keys that have not been publicly mapped. The ADB probe + retry + clear error approach is more reliable than a fragile registry hack that may break across WSA versions.

### ADB Tooling

| Technology | Version | Source | Purpose |
|------------|---------|--------|---------|
| Android SDK Platform Tools (adb.exe) | Latest (currently 35.x) | Official: developer.android.com/tools/releases/platform-tools | ADB binary for APK install, port-forwarding, shell access |

Delivery: Bundle `adb.exe`, `AdbWinApi.dll`, `AdbWinUsbApi.dll` directly in the deployment package. Do NOT rely on a system PATH `adb` — terminals are heterogeneous and existing ADB installations may be wrong version or missing.

ADB connection to WSA uses a fixed port: `localhost:58526`. This port is not configurable.

Reliable ADB retry pattern in PowerShell:
```powershell
function Invoke-AdbWithRetry {
    param(
        [string]$AdbPath,
        [int]$MaxAttempts = 12,
        [int]$DelaySeconds = 5
    )
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        & $AdbPath connect localhost:58526 2>&1 | Out-Null
        $devices = & $AdbPath devices
        if ($devices -match 'localhost:58526\s+device') {
            return $true
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}
```

Parse `adb devices` output rather than relying on `adb connect` exit codes — `adb connect` returns exit code 0 even on failure. The string `device` (not `offline`, not `unauthorized`) in `adb devices` is the only reliable success signal.

**Confidence: HIGH** — ADB behavior verified against official Android documentation. WSA port 58526 confirmed via multiple community sources consistent with each other.

Common ADB failure modes and mitigation:
- `offline` state: run `adb kill-server && adb start-server`, then reconnect
- `unauthorized`: developer mode was not enabled (see above)
- connection refused: WSA is not running or VirtWifi adapter is disabled
- VPN interference: WSA VirtWifi bridge and some VPN drivers conflict; this is a terminal configuration problem, not solvable by the script

### Reboot-and-Resume Pattern

Enabling VirtualMachinePlatform requires a reboot before WSA can be installed or run. This is unavoidable.

Recommended pattern (verified via multiple sources):

```powershell
# Step 1: Before reboot — register resume task
$scriptPath = $MyInvocation.MyCommand.Path
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -ResumeAfterReboot"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'BarakaDeploy-Resume' `
    -Action $action -Trigger $trigger `
    -RunLevel Highest -Force | Out-Null

# Step 2: Reboot
Restart-Computer -Force

# Step 3: On resume (script called with -ResumeAfterReboot parameter)
# First thing: unregister the task so it doesn't loop
Unregister-ScheduledTask -TaskName 'BarakaDeploy-Resume' -Confirm:$false
```

Use `-RunLevel Highest` (not `-RunLevel LUA`) to ensure the resumed script has admin rights.

Use a checkpoint file (`C:\baraka-deploy\checkpoint.txt`) to track which phases completed before the reboot, so the script resumes at the right step.

Alternative for fully headless scenarios (no interactive user session at all): use `schtasks.exe /create /sc ONSTART /ru SYSTEM /rl HIGHEST` — this runs under SYSTEM account without requiring auto-logon.

**Confidence: HIGH** — Pattern confirmed via multiple independent sources.

### Popup/Window Suppression During Install

`Add-AppxPackage` can trigger a brief Windows Store UI flash. Mitigation:
- Run the entire deployment script in a hidden PowerShell window, launched via Task Scheduler (this prevents window inheritance)
- The `WsaClient.exe` settings app window opened by WSA on first launch cannot be suppressed via PowerShell alone — see developer mode discussion above

`-WindowStyle Hidden` on `Start-Process` is unreliable when Windows Terminal is the default console host (known upstream bug). The Task Scheduler approach (which never creates a visible console) is more reliable.

**Confidence: MEDIUM** — `-WindowStyle Hidden` limitation documented in PowerShell GitHub issue tracker; Task Scheduler workaround is community-established.

### Registry Manipulation

PowerShell cmdlets for registry operations:

| Operation | Cmdlet | Notes |
|-----------|--------|-------|
| Read key | `Get-ItemProperty -Path 'HKLM:\...' -Name 'ValueName'` | Returns PSCustomObject; use error handling if key may not exist |
| Write key | `Set-ItemProperty` / `New-ItemProperty` | Use `-Force` to create if not exists |
| Ensure path exists | `New-Item -Path 'HKLM:\...' -Force` | `-Force` is idempotent (no error if exists) |
| Delete value | `Remove-ItemProperty` | |

Pattern for safe registry write:
```powershell
function Set-RegistryValue {
    param($Path, $Name, $Value, $Type = 'DWord')
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
}
```

Known WSA-relevant registry paths (HIGH confidence):
- `HKCU:\Software\Microsoft\WSA\VMLifeCycleMode` — controls VM lifecycle (values: `Auto` = stop when idle, `Persistent` = always running)
- `HKLM:\Software\Microsoft\WSA\` — machine-wide WSA configuration

Developer mode registry path: NOT publicly documented. Needs empirical discovery. See Approach B above.

**Confidence: MEDIUM** — VMLifeCycleMode sourced from community gist with multiple corroborating references; developer mode key unconfirmed.

### State Management and Error Handling

Use a structured state file at a fixed path:
```
C:\baraka-deploy\state.json
```

Schema:
```json
{
  "vmPlatformEnabled": true,
  "rebooted": true,
  "wsaInstalled": true,
  "developerModeEnabled": false,
  "adbConnected": false,
  "apkInstalled": false,
  "adbReverseConfigured": false,
  "lastError": "ADB connection timed out after 60s"
}
```

Each phase checks the state file before executing, making the script fully idempotent — safe to re-run after any failure.

**Confidence: HIGH** — Standard pattern for multi-phase unattended deployment scripts.

### Elevation (Admin Check)

```powershell
function Assert-Administrator {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # Self-elevate
        $args = "-NonInteractive -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
        Start-Process powershell.exe -Verb RunAs -ArgumentList $args
        exit
    }
}
```

This is the canonical elevation check. It triggers a UAC prompt when the script is run without admin rights. For fully unattended operation (no UAC), the script must be launched from a context that already has admin rights (e.g., Task Scheduler with SYSTEM account, or an IT provisioning tool).

**Confidence: HIGH** — Pattern is decades-stable in PowerShell ecosystem.

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Script runtime | PowerShell 5.1 | PowerShell 7+ | Missing Appx and DISM modules on Windows client |
| Feature enablement | `Enable-WindowsOptionalFeature` | `dism.exe /online` CLI | Cmdlet returns structured object with `RestartNeeded`; CLI requires string parsing |
| Reboot resume | Scheduled Task (SYSTEM) | PowerShell Workflow checkpoints | PS Workflows are deprecated in PS 7+; require complex DSC-like syntax |
| ADB binary | Bundled in deployment package | System PATH reliance | Hardware variance means inconsistent or missing ADB on terminals |
| Developer mode | Registry write | UI automation (SendKeys, AutoIt) | UI automation is fragile across hardware/DPI differences; requires interactive session |
| WSA developer mode (first run) | Manual-once + state file | Full automation | No reliable programmatic method found; honest fallback beats silent failure |

---

## Installation / Deployment Package Contents

The deployment package should be a self-contained directory, no network access required:

```
baraka-deploy/
  deploy.ps1              # Main orchestration script
  adb/
    adb.exe
    AdbWinApi.dll
    AdbWinUsbApi.dll
  wsa/
    MagiskOnWSALocal-build/
      AppxManifest.xml
      WsaClient.exe
      ... (full WSA build directory)
  apk/
    baraka-pos.apk
  state.json              # Written at runtime, persists across runs/reboots
```

---

## Sources

- [Enable-WindowsOptionalFeature — Microsoft Docs (updated 2025-05-14)](https://learn.microsoft.com/en-us/powershell/module/dism/enable-windowsoptionalfeature?view=windowsserver2025-ps)
- [Add-AppxPackage — Microsoft Docs (updated 2025-05-14)](https://learn.microsoft.com/en-us/powershell/module/appx/add-appxpackage?view=windowsserver2025-ps)
- [Android Debug Bridge (adb) — Android Developers](https://developer.android.com/tools/adb)
- [ADB Connection and Commands — MustardChef/WSABuilds DeepWiki](https://deepwiki.com/MustardChef/WSABuilds/6.1-adb-connection-and-commands)
- [WSAClient.exe parameters — vhanla gist](https://gist.github.com/vhanla/247ee77dd0cdd5449e02e2d517a13019)
- [adb shell settings put global — Stack Overflow / XDA](https://xdaforums.com/t/guide-how-to-enable-access-via-adb-on-a-new-installed-os.4535165/)
- [WSA ADB connection refused — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/788883/cannot-connect-to-127-0-0-1-58526-(port-shown-unde)
- [MagiskOnWSALocal installer — GitHub](https://github.com/LSPosed/MagiskOnWSALocal)
- [MustardChef/WSABuilds — GitHub](https://github.com/MustardChef/WSABuilds)
- [WSA deprecated March 2025 — Microsoft](https://learn.microsoft.com/en-us/windows/android/wsa/)
