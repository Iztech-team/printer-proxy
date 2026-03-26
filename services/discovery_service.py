import json
import logging
import platform as _platform

from settings.registry import PRINTERS, save_registry
from services.connection import evict_printer_connection
from discovery import PrinterDiscovery


def merge_discovered_printers(found):
    new_count = 0
    updated_count = 0

    for ip, info in found.items():
        found_mac = info.get("mac") or "unknown"
        found_port = info.get("port", 9100)
        matched_name = None

        if found_mac != "unknown":
            for name, config in PRINTERS.items():
                existing_mac = config.get("mac", "unknown")
                if existing_mac != "unknown" and existing_mac == found_mac:
                    matched_name = name
                    break

        if not matched_name:
            for name, config in PRINTERS.items():
                if config["host"] == ip:
                    matched_name = name
                    break

        if matched_name:
            config = PRINTERS[matched_name]
            old_ip = config["host"]
            if old_ip != ip:
                logging.info(f"  {matched_name}: IP changed {old_ip} -> {ip} (MAC: {found_mac})")
                config["host"] = ip
                evict_printer_connection(matched_name)
                updated_count += 1
            if found_mac != "unknown":
                config["mac"] = found_mac
            config["port"] = found_port
        else:
            name = _next_printer_name()
            PRINTERS[name] = {"host": ip, "port": found_port, "mac": found_mac}
            new_count += 1
            logging.info(f"  Discovered: {name} @ {ip} (MAC: {found_mac})")

    return new_count, updated_count


def _next_printer_name():
    existing_nums = []
    for n in PRINTERS:
        if n.startswith("printer_"):
            try:
                existing_nums.append(int(n.split("_")[1]))
            except (ValueError, IndexError):
                pass
    return f"printer_{max(existing_nums, default=0) + 1}"


def _find_existing_by_host(host_value):
    for n, c in PRINTERS.items():
        if c["host"] == host_value:
            return n
    return None


def discovery_event_stream():
    discovery = PrinterDiscovery()
    discovered_hosts = set()

    for event in discovery.scan_streaming():
        if event["type"] == "status":
            yield f"event: status\ndata: {json.dumps(event)}\n\n"

        elif event["type"] == "network":
            ip = event["ip"]
            discovered_hosts.add(ip)
            found = {ip: {"port": event["port"], "mac": event.get("mac"), "responsive": True}}
            merge_discovered_printers(found)
            name = _find_existing_by_host(ip)
            if name:
                PRINTERS[name]["connection_type"] = "network"
                yield f"event: printer\ndata: {json.dumps({'name': name, 'connection_type': 'network', 'host': ip, 'port': event['port'], 'mac': event.get('mac', 'unknown'), 'connected': True})}\n\n"

        elif event["type"] in ("system", "serial"):
            device = event["device"]
            conn_type = event["connection_type"]
            is_responsive = event.get("responsive", True)

            if is_responsive:
                discovered_hosts.add(device)

            name = _find_existing_by_host(device)
            if not name:
                name = _next_printer_name()
                PRINTERS[name] = {
                    "host": device,
                    "port": event.get("port", 0),
                    "mac": "local",
                    "connection_type": conn_type,
                }

            PRINTERS[name]["connection_type"] = conn_type
            yield f"event: printer\ndata: {json.dumps({'name': name, 'connection_type': conn_type, 'device': device, 'description': event.get('description', ''), 'connected': is_responsive})}\n\n"

    save_registry()

    result = {}
    for name, config in PRINTERS.items():
        conn_type = config.get("connection_type", "network")
        connected = config["host"] in discovered_hosts
        result[name] = {
            "host": config["host"],
            "port": config["port"],
            "mac": config.get("mac", "unknown"),
            "connection_type": conn_type,
            "connected": connected,
        }

    yield f"event: complete\ndata: {json.dumps({'printers': result, 'total': len(result)})}\n\n"


REGISTER_USB_PS_SCRIPT = r"""
$results = @()
$usbPorts = Get-PrinterPort | Where-Object { $_.Name -like 'USB*' }
$existingPrinters = Get-Printer

$driverCandidates = @('Generic / Text Only', 'Generic/Text Only', 'MS Publisher Imagesetter')
$driverName = $null
$installedDrivers = Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name

foreach ($candidate in $driverCandidates) {
    if ($installedDrivers -contains $candidate) {
        $driverName = $candidate
        break
    }
}

if (-not $driverName) {
    $infPath = Join-Path $env:SystemRoot 'INF\ntprint.inf'
    if (Test-Path $infPath) {
        try { pnputil /add-driver $infPath /install 2>&1 | Out-Null } catch {}
    }
    try {
        Add-PrinterDriver -Name 'Generic / Text Only' -ErrorAction Stop
        $driverName = 'Generic / Text Only'
    } catch {
        try {
            Add-PrinterDriver -Name 'Generic / Text Only' -InfPath $infPath -ErrorAction Stop
            $driverName = 'Generic / Text Only'
        } catch {}
    }
}

if (-not $driverName) {
    $anyDriver = $installedDrivers | Select-Object -First 1
    if ($anyDriver) {
        $driverName = $anyDriver
    } else {
        @{ port = 'N/A'; status = 'failed'; error = 'No printer drivers available.' } | ConvertTo-Json -Compress
        exit 0
    }
}

foreach ($port in $usbPorts) {
    $portName = $port.Name
    $alreadyUsed = $existingPrinters | Where-Object { $_.PortName -eq $portName }
    if ($alreadyUsed) {
        $results += @{ port = $portName; status = 'exists'; name = $alreadyUsed.Name; driver = $alreadyUsed.DriverName }
    } else {
        $printerName = "POS-Printer-$portName"
        try {
            Add-Printer -Name $printerName -DriverName $driverName -PortName $portName -ErrorAction Stop
            $results += @{ port = $portName; status = 'created'; name = $printerName; driver = $driverName }
        } catch {
            $results += @{ port = $portName; status = 'failed'; error = $_.ToString() }
        }
    }
}

$results | ConvertTo-Json -Compress
"""


def register_usb_printers_windows():
    if _platform.system() != "Windows":
        return {"success": True, "message": "Not needed on Linux", "registered": 0}

    import subprocess
    try:
        result = subprocess.run(
            ["powershell", "-ExecutionPolicy", "Bypass", "-Command", REGISTER_USB_PS_SCRIPT],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return {"success": False, "error": result.stderr.strip() or "PowerShell command failed"}

        output = result.stdout.strip()
        if not output:
            return {"success": True, "registered": 0, "message": "No USB printer ports found", "printers": []}

        printers = json.loads(output)
        if isinstance(printers, dict):
            printers = [printers]

        created = [p for p in printers if p.get("status") == "created"]
        return {"success": True, "registered": len(created), "printers": printers}
    except Exception as e:
        return {"success": False, "error": str(e)}
