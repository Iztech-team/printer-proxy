#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Baraka Printer Proxy — Windows Setup

.DESCRIPTION
    Installs Python, sets up dependencies, registers USB printers,
    and optionally configures auto-start.

.NOTES
    Run via the included setup.bat, or manually:
      powershell -ExecutionPolicy Bypass -File deployment\setup-windows.ps1
#>

$ErrorActionPreference = "Stop"

function Write-Info  { Write-Host "[+] $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "[!] $args" -ForegroundColor Yellow }
function Write-Err   { Write-Host "[x] $args" -ForegroundColor Red }

$ProjectDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Baraka Printer Proxy — Windows Setup"       -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Project dir: $ProjectDir"
Write-Host ""

# ─── 1. Install or find Python ───────────────────────────────
Write-Info "Checking Python installation..."

$PythonCmd = $null
foreach ($cmd in @("python", "python3", "py")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3\.\d+") {
            # Detect Microsoft Store Python (causes venv/pywin32 issues)
            $pythonPath = (Get-Command $cmd -ErrorAction SilentlyContinue).Source
            if ($pythonPath -and $pythonPath -match "WindowsApps") {
                Write-Warn "Found Microsoft Store Python at $pythonPath"
                Write-Warn "Store Python has issues with venv and pywin32."
                Write-Warn "Attempting to install python.org version instead..."
                continue
            }
            $PythonCmd = $cmd
            Write-Info "Found: $ver ($cmd)"
            break
        }
    } catch { }
}

if (-not $PythonCmd) {
    Write-Info "Python not found. Attempting auto-install..."

    $installed = $false

    # Method 1: Try winget (Windows 11 and recent Windows 10)
    $wingetAvailable = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetAvailable) {
        Write-Info "Installing Python via winget..."
        try {
            winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            $installed = $true
        } catch {
            Write-Warn "winget install failed, trying direct download..."
        }
    }

    # Method 2: Download installer from python.org
    if (-not $installed) {
        Write-Info "Downloading Python from python.org..."
        $installerUrl = "https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe"
        $installerPath = Join-Path $env:TEMP "python-installer.exe"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
            Write-Info "Installing Python (silent)..."
            Start-Process -FilePath $installerPath -ArgumentList `
                "/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_pip=1" `
                -Wait -NoNewWindow
            Remove-Item $installerPath -ErrorAction SilentlyContinue
            $installed = $true
            Write-Info "Python installed"
        } catch {
            Write-Warn "Download failed: $_"
        }
    }

    if ($installed) {
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        foreach ($cmd in @("python", "python3", "py")) {
            try {
                $ver = & $cmd --version 2>&1
                if ($ver -match "Python 3\.\d+") {
                    $PythonCmd = $cmd
                    Write-Info "Found: $ver"
                    break
                }
            } catch { }
        }
    }

    if (-not $PythonCmd) {
        Write-Err "Could not install Python automatically."
        Write-Err "Please install from https://www.python.org/downloads/"
        Write-Err "IMPORTANT: Check 'Add Python to PATH' during installation."
        Write-Err "Then re-run this script."
        exit 1
    }
}

# ─── 2. Virtual environment ─────────────────────────────────
$VenvDir = Join-Path $ProjectDir "venv"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$VenvPip = Join-Path $VenvDir "Scripts\pip.exe"

if (-not (Test-Path $VenvDir)) {
    Write-Info "Creating Python virtual environment..."
    & $PythonCmd -m venv $VenvDir
    if (-not (Test-Path $VenvPip)) {
        Write-Err "Venv creation failed. If using Microsoft Store Python, install from python.org instead."
        exit 1
    }
    Write-Info "Venv created at $VenvDir"
} else {
    # Validate venv is not corrupted
    if (-not (Test-Path $VenvPip)) {
        Write-Warn "Venv exists but pip is missing. Recreating..."
        Remove-Item -Recurse -Force $VenvDir
        & $PythonCmd -m venv $VenvDir
        if (-not (Test-Path $VenvPip)) {
            Write-Err "Venv creation failed."
            exit 1
        }
        Write-Info "Venv recreated"
    } else {
        Write-Info "Venv already exists at $VenvDir"
    }
}

Write-Info "Installing Python dependencies..."
try {
    # Use python -m pip instead of pip.exe directly — more reliable with path spaces
    & $VenvPython -m pip install -q --upgrade pip 2>&1 | Out-Null
    & $VenvPython -m pip install -q -r (Join-Path $ProjectDir "requirements.txt")
    Write-Info "Python dependencies installed"
} catch {
    Write-Err "Failed to install dependencies: $_"
    Write-Err "Try manually: $VenvPython -m pip install -r requirements.txt"
    exit 1
}

# ─── 3. Auto-detect and register USB printers ────────────────
Write-Host ""
Write-Info "Scanning for USB printers..."

# Check if PrintManagement module is available (not on Windows Home)
$hasPrintMgmt = $false
try {
    Import-Module PrintManagement -ErrorAction Stop
    $hasPrintMgmt = $true
} catch {
    Write-Warn "PrintManagement module not available (Windows Home edition?)."
    Write-Warn "Trying alternative method..."
}

if ($hasPrintMgmt) {
    # --- Standard approach using PrintManagement cmdlets ---
    $installedDrivers = Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    $driverName = $null

    $driverCandidates = @("Generic / Text Only", "Generic/Text Only", "MS Publisher Imagesetter")
    foreach ($candidate in $driverCandidates) {
        if ($installedDrivers -contains $candidate) {
            $driverName = $candidate
            Write-Info "Found printer driver: $driverName"
            break
        }
    }

    if (-not $driverName) {
        Write-Info "Installing 'Generic / Text Only' printer driver..."
        $infPath = Join-Path $env:SystemRoot "inf\ntprint.inf"

        # Step 1: Register ntprint.inf via pnputil (this is what actually works)
        if (Test-Path $infPath) {
            try {
                pnputil /add-driver $infPath /install 2>&1 | Out-Null
                Write-Info "Registered ntprint.inf via pnputil"
            } catch {
                Write-Warn "pnputil failed: $_"
            }
        }

        # Step 2: Now Add-PrinterDriver can find it
        try {
            Add-PrinterDriver -Name "Generic / Text Only" -ErrorAction Stop
            $driverName = "Generic / Text Only"
            Write-Info "Driver installed successfully"
        } catch {
            # Fallback: try with -InfPath
            try {
                Add-PrinterDriver -Name "Generic / Text Only" -InfPath $infPath -ErrorAction Stop
                $driverName = "Generic / Text Only"
                Write-Info "Driver installed via -InfPath"
            } catch {
                Write-Warn "Could not install 'Generic / Text Only' driver: $_"
            }
        }
    }

    # Find USB ports and create printer queues
    $usbPorts = Get-PrinterPort -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "USB*" }
    $existingPrinters = Get-Printer -ErrorAction SilentlyContinue
    $registeredCount = 0

    foreach ($port in $usbPorts) {
        $portName = $port.Name
        $alreadyUsed = $existingPrinters | Where-Object { $_.PortName -eq $portName }

        if ($alreadyUsed) {
            Write-Info "Port $portName already has printer: $($alreadyUsed.Name)"
        } elseif ($driverName) {
            $printerName = "POS-Printer-$portName"
            try {
                Add-Printer -Name $printerName -DriverName $driverName -PortName $portName -ErrorAction Stop
                Write-Info "Created printer '$printerName' on port $portName"
                $registeredCount++
            } catch {
                Write-Warn "Could not create printer on $portName : $_"
            }
        } else {
            Write-Warn "Port $portName found but no driver available"
        }
    }

    if ($usbPorts.Count -eq 0) {
        Write-Warn "No USB printer ports found. Plug in a USB printer and re-run."
    } elseif ($registeredCount -gt 0) {
        Write-Info "Registered $registeredCount new USB printer(s)"
    } else {
        Write-Info "All USB ports already have printer queues"
    }
} else {
    # --- Fallback for Windows Home: use rundll32 + printui.dll ---
    Write-Info "Using printui.dll for printer setup..."

    # Install Generic / Text Only driver via printui
    $infPath = Join-Path $env:SystemRoot "inf\ntprint.inf"
    if (Test-Path $infPath) {
        try {
            Start-Process -FilePath "rundll32.exe" `
                -ArgumentList "printui.dll,PrintUIEntry /ia /m `"Generic / Text Only`" /f `"$infPath`"" `
                -Wait -NoNewWindow
            Write-Info "Generic / Text Only driver installed"
        } catch {
            Write-Warn "Could not install driver: $_"
        }
    }

    # Try to detect and add USB printers via WMI (works on all editions)
    $usbPrinterPorts = Get-WmiObject -Class Win32_PortResource -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*USB*" }

    # Also check for existing USB ports via registry
    $regPorts = Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\USB Monitor\Ports" -ErrorAction SilentlyContinue
    if ($regPorts) {
        foreach ($port in $regPorts) {
            $portName = $port.PSChildName
            Write-Info "Found USB port in registry: $portName"

            # Add printer via printui (works on Home edition)
            try {
                Start-Process -FilePath "rundll32.exe" `
                    -ArgumentList "printui.dll,PrintUIEntry /if /b `"POS-Printer-$portName`" /r `"$portName`" /m `"Generic / Text Only`"" `
                    -Wait -NoNewWindow
                Write-Info "Created printer POS-Printer-$portName"
            } catch {
                Write-Warn "Could not create printer on $portName : $_"
            }
        }
    } else {
        Write-Warn "No USB printer ports detected. Plug in a USB printer and re-run."
    }
}

Write-Host ""

# ─── 4. Firewall rule ───────────────────────────────────────
Write-Info "Adding firewall rule for port 3006..."

$RuleName = "Baraka Printer Proxy"
$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

if ($existing) {
    Write-Info "Firewall rule already exists"
} else {
    New-NetFirewallRule `
        -DisplayName $RuleName `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 3006 `
        -Action Allow `
        -Profile Private,Domain | Out-Null
    Write-Info "Firewall rule added (port 3006, private/domain networks)"
}

# ─── 5. Auto-start (hidden background service via Task Scheduler) ─
Write-Info "Setting up auto-start..."

$TaskName = "Baraka Printer Proxy"
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if ($existingTask) {
    # Remove old task to recreate with current paths
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Info "Removed old scheduled task"
}

# Create a VBS launcher so the process runs completely hidden (no console window)
$LauncherVbs = Join-Path $ProjectDir "deployment\start-hidden.vbs"
@"
Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "$ProjectDir"
WshShell.Run """$VenvPython"" ""$(Join-Path $ProjectDir "app.py")""", 0, False
"@ | Out-File -Encoding ASCII $LauncherVbs

$Action = New-ScheduledTaskAction `
    -Execute "wscript.exe" `
    -Argument """$LauncherVbs""" `
    -WorkingDirectory $ProjectDir

$Trigger = New-ScheduledTaskTrigger -AtLogOn

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Days 365) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Description "Baraka POS Printer Proxy Server (hidden)" `
    -RunLevel Highest | Out-Null

Write-Info "Auto-start configured (hidden, runs on login)"
Write-Info "  Task name: '$TaskName'"
Write-Info "  Start now: Start-ScheduledTask '$TaskName'"
Write-Info "  Stop:      Stop-ScheduledTask '$TaskName'"
Write-Info "  Remove:    Unregister-ScheduledTask '$TaskName'"

# ─── Done ────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Setup complete!"                            -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Server:  http://localhost:3006"
Write-Host "  Health:  http://localhost:3006/api/health"
Write-Host "  Swagger: http://localhost:3006/docs"
Write-Host ""

Write-Info "Done."
