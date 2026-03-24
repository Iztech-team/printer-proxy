"""
Baraka POS Printer Server
==========================
Proxy server for thermal printers on the local network.
FastAPI + python-escpos + Pillow.
"""

import base64
import binascii
import json
import logging
import os
import sys
import threading
import uuid
from datetime import datetime
from typing import List, Optional

import platform as _platform

from dotenv import load_dotenv
from escpos.exceptions import Error as EscposError
from escpos.printer import Network
from fastapi import FastAPI, HTTPException, Query, Request, UploadFile

# Optional printer transports (platform-dependent)
try:
    from escpos.printer import Win32Raw
except ImportError:
    Win32Raw = None

try:
    from escpos.printer import File as FilePrinter
except ImportError:
    FilePrinter = None

try:
    from escpos.printer import Serial as SerialPrinter
except ImportError:
    SerialPrinter = None
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from PIL import Image
from pydantic import BaseModel
from werkzeug.utils import secure_filename

from print_queue import PrintQueue
from discovery import PrinterDiscovery

load_dotenv()

# ─── Configuration ───────────────────────────────────────────
UPLOAD_FOLDER = os.getenv("UPLOAD_FOLDER", "uploads")
ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "bmp", "gif"}
MAX_CONTENT_LENGTH = int(os.getenv("MAX_UPLOAD_SIZE_MB", "20")) * 1024 * 1024
SERVER_HOST = os.getenv("SERVER_HOST", "0.0.0.0")
SERVER_PORT = int(os.getenv("SERVER_PORT", "3006"))
REGISTRY_FILE = os.getenv("PRINTER_REGISTRY", "registry.json")
MIN_FEED_BEFORE_CUT = int(os.getenv("MIN_FEED_BEFORE_CUT", "4"))
QUEUE_MAX_RETRIES = int(os.getenv("QUEUE_MAX_RETRIES", "3"))
QUEUE_RETRY_BASE_DELAY = float(os.getenv("QUEUE_RETRY_BASE_DELAY", "1.0"))
QUEUE_JOB_HISTORY_SIZE = int(os.getenv("QUEUE_JOB_HISTORY_SIZE", "100"))

# ─── Global state ────────────────────────────────────────────
PRINTERS = {}
_printer_connections = {}
_pool_lock = threading.Lock()

print_queue = PrintQueue(
    max_retries=QUEUE_MAX_RETRIES,
    retry_base_delay=QUEUE_RETRY_BASE_DELAY,
    history_size=QUEUE_JOB_HISTORY_SIZE,
)


# ─── Registry persistence ────────────────────────────────────
def _registry_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), REGISTRY_FILE)


def load_registry():
    global PRINTERS
    reg_path = _registry_path()
    if os.path.exists(reg_path):
        try:
            with open(reg_path, "r") as f:
                data = json.load(f)
            entries = sorted(data.values(), key=lambda x: x.get("name", ""))
            for i, info in enumerate(entries, start=1):
                host = info.get("last_ip", info.get("host", ""))
                # Skip old pyusb-based entries
                if isinstance(host, str) and host.startswith("usb:"):
                    logging.warning(f"Skipping legacy USB entry: {host} (re-discover to use new transport)")
                    continue
                PRINTERS[f"printer_{i}"] = {
                    "host": host,
                    "port": info.get("port", 9100),
                    "mac": info.get("mac", "unknown"),
                    "connection_type": info.get("connection_type", "network"),
                    "baudrate": info.get("baudrate", 9600),
                }
            logging.info(f"Loaded {len(PRINTERS)} printer(s) from registry")
        except Exception as e:
            logging.warning(f"Could not load registry: {e}")


def save_registry():
    reg_path = _registry_path()
    data = {}
    for name, config in PRINTERS.items():
        data[name] = {
            "name": name,
            "connection_type": config.get("connection_type", "network"),
            "last_ip": config["host"],
            "port": config["port"],
            "mac": config.get("mac", "unknown"),
            "baudrate": config.get("baudrate", 9600),
            "last_seen": datetime.now().isoformat(),
        }
    try:
        with open(reg_path, "w") as f:
            json.dump(data, f, indent=2)
    except Exception as e:
        logging.warning(f"Could not save registry: {e}")


# ─── Connection management ───────────────────────────────────
# Combined init bytes — single write instead of three
_INIT_BYTES = (
    b"\x1b\x40"      # ESC @ -- hardware reset
    b"\x1b\x45\x00"  # ESC E 0 -- emphasis OFF
    b"\x1b\x47\x00"  # ESC G 0 -- double-strike OFF
)

def _init_printer(p):
    p._raw(_INIT_BYTES)


def _create_printer(config):
    """Create a new printer instance based on connection_type."""
    conn_type = config.get("connection_type", "network")

    if conn_type == "network":
        return Network(config["host"], port=config["port"], profile="TM-T88III")
    elif conn_type == "win32raw":
        if Win32Raw is None:
            raise RuntimeError("Win32Raw not available (pywin32 not installed or not on Windows)")
        return Win32Raw(config["host"], profile="TM-T88III")
    elif conn_type == "file":
        if FilePrinter is None:
            raise RuntimeError("File printer not available")
        return FilePrinter(config["host"], profile="TM-T88III")
    elif conn_type == "serial":
        if SerialPrinter is None:
            raise RuntimeError("Serial not available (pyserial not installed)")
        return SerialPrinter(
            config["host"],
            baudrate=config.get("baudrate", 9600),
            profile="TM-T88III",
        )
    else:
        raise RuntimeError(f"Unknown connection_type: {conn_type}")


def _is_job_based(printer_name: str) -> bool:
    """Win32Raw needs open/close per job — data is only sent on close()."""
    config = PRINTERS.get(printer_name, {})
    return config.get("connection_type") == "win32raw"


def _connect_printer(printer_name: str):
    """Get or create a printer connection. Thread-safe.
    For Win32Raw: creates a fresh connection each time (job-based).
    For others: reuses pooled connections.
    """
    if printer_name not in PRINTERS:
        raise RuntimeError(
            f"Unknown printer: {printer_name}. Available: {list(PRINTERS.keys())}"
        )

    config = PRINTERS[printer_name]

    # Win32Raw: always create fresh — each open/close is one print job
    if _is_job_based(printer_name):
        try:
            printer = _create_printer(config)
            printer.open()
            return printer
        except Exception as e:
            raise RuntimeError(f"Cannot connect to {printer_name}: {e}")

    # All other types: use connection pool
    with _pool_lock:
        if printer_name in _printer_connections:
            conn = _printer_connections[printer_name]
            try:
                if conn.device is not None:
                    if hasattr(conn.device, 'getpeername'):
                        conn.device.getpeername()
                    return conn
            except (OSError, AttributeError):
                pass
            try:
                conn.close()
            except Exception:
                pass
            _printer_connections.pop(printer_name, None)

        try:
            printer = _create_printer(config)
            _printer_connections[printer_name] = printer
            return printer
        except Exception as e:
            _printer_connections.pop(printer_name, None)
            raise RuntimeError(f"Cannot connect to {printer_name}: {e}")


def _close_if_job_based(printer_name: str, printer):
    """For Win32Raw, close the connection to flush data to the printer."""
    if _is_job_based(printer_name):
        try:
            printer.close()
        except Exception:
            pass


def get_printer(printer_name: str):
    try:
        return _connect_printer(printer_name)
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))


def evict_printer_connection(printer_name: str):
    with _pool_lock:
        conn = _printer_connections.pop(printer_name, None)
    if conn:
        try:
            conn.close()
        except Exception:
            pass


# ─── Image processing ────────────────────────────────────────
def allowed_file(filename: str) -> bool:
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXTENSIONS


def _prepare_image_for_thermal(filepath: str, paper_width: int) -> str:
    from PIL import ImageEnhance, ImageOps

    img = Image.open(filepath)
    try:
        if img.mode == "RGBA" or "transparency" in img.info:
            background = Image.new("RGB", img.size, (255, 255, 255))
            if img.mode == "RGBA":
                background.paste(img, mask=img.split()[3])
            else:
                background.paste(img)
            img = background
        elif img.mode != "RGB":
            img = img.convert("RGB")

        if img.width > paper_width:
            ratio = paper_width / img.width
            new_height = int(img.height * ratio)
            img = img.resize((paper_width, new_height), Image.Resampling.LANCZOS)

        img = ImageOps.autocontrast(img, cutoff=0.5)
        img = ImageEnhance.Contrast(img).enhance(1.3)
        img = ImageEnhance.Sharpness(img).enhance(1.2)

        bw = img.convert("L")
        gamma = 0.9
        lut = [min(255, int(255 * ((i / 255.0) ** gamma))) for i in range(256)]
        bw = bw.point(lut)
        bw = bw.point(lambda x: 255 if x > 245 else x)
        img = bw.convert("1", dither=Image.Dither.FLOYDSTEINBERG)
        img.save(filepath, "PNG")
    finally:
        img.close()

    return filepath


# ─── Printer validation helper ───────────────────────────────
def _validate_printer(printer_name: str):
    if printer_name not in PRINTERS:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown printer: {printer_name}. Available: {list(PRINTERS.keys())}",
        )


# ─── Discovery merge logic ───────────────────────────────────
def _merge_discovered_printers(found):
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
                logging.info(
                    f"  {matched_name}: IP changed {old_ip} -> {ip} (MAC: {found_mac})"
                )
                config["host"] = ip
                evict_printer_connection(matched_name)
                updated_count += 1
            if found_mac != "unknown":
                config["mac"] = found_mac
            config["port"] = found_port
        else:
            existing_nums = []
            for n in PRINTERS:
                if n.startswith("printer_"):
                    try:
                        existing_nums.append(int(n.split("_")[1]))
                    except (ValueError, IndexError):
                        pass
            next_num = max(existing_nums, default=0) + 1
            printer_name = f"printer_{next_num}"

            PRINTERS[printer_name] = {
                "host": ip,
                "port": found_port,
                "mac": found_mac,
            }
            new_count += 1
            logging.info(f"  Discovered: {printer_name} @ {ip} (MAC: {found_mac})")

    return new_count, updated_count


# ─── App setup ───────────────────────────────────────────────
app = FastAPI(title="Baraka Printer Server", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs(UPLOAD_FOLDER, exist_ok=True)


# ─── Error handlers ──────────────────────────────────────────
@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    if isinstance(exc, (HTTPException, RequestValidationError, EscposError)):
        raise exc
    logging.error(f"Unhandled exception: {type(exc).__name__}: {str(exc)}")
    return JSONResponse(
        status_code=500,
        content={
            "success": False,
            "error": "Internal server error",
            "detail": str(exc),
            "type": type(exc).__name__,
        },
    )


@app.exception_handler(EscposError)
async def escpos_exception_handler(request: Request, exc: EscposError):
    logging.error(f"Printer error: {str(exc)}")
    return JSONResponse(
        status_code=500,
        content={
            "success": False,
            "error": "Printer error",
            "detail": str(exc),
            "type": "PrinterError",
        },
    )


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    errors = []
    for err in exc.errors():
        clean = {k: v for k, v in err.items() if k != "ctx"}
        clean["msg"] = str(err.get("msg", ""))
        errors.append(clean)
    return JSONResponse(
        status_code=422,
        content={
            "success": False,
            "error": "Validation error",
            "detail": errors,
            "type": "ValidationError",
        },
    )


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"success": False, "error": exc.detail, "type": "HTTPException"},
    )


# ─── Print execution functions ───────────────────────────────

def _exec_text(printer_name, params):
    p = _connect_printer(printer_name)
    try:
        _init_printer(p)
        use_custom_size = params.get("width", 1) != 1 or params.get("height", 1) != 1
        p.set(
            align=params.get("align", "left"),
            bold=params.get("bold", False),
            underline=params.get("underline", 0),
            invert=params.get("invert", False),
            width=params.get("width", 1),
            height=params.get("height", 1),
            custom_size=use_custom_size,
        )
        text = params["text"]
        p.text(text)
        if not text.endswith("\n"):
            p.text("\n")
        p.set()
        lines_after = params.get("lines_after", 0)
        cut = params.get("cut", True)
        feed_lines = lines_after if lines_after > 0 else MIN_FEED_BEFORE_CUT
        if cut:
            p.text("\n" * feed_lines)
            p.cut(feed=False)
        elif lines_after > 0:
            p.text("\n" * lines_after)
        _close_if_job_based(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def _exec_receipt(printer_name, params):
    p = _connect_printer(printer_name)
    try:
        _init_printer(p)
        CHAR_WIDTH = 48

        # Header
        p.set(align="center", bold=True, width=2, height=2, custom_size=True)
        p.text(f"{params.get('header', 'BARAKA')}\n")
        p.set()

        subheader = params.get("subheader")
        if subheader:
            p.set(align="center")
            p.text(f"{subheader}\n")
            p.set()

        p.text("-" * CHAR_WIDTH + "\n")

        # Items
        items = params.get("items", [])
        if items:
            p.set(align="left")
            for item in items:
                name_part = f"{item['qty']}x {item['name']}"
                price_part = f"{item['price']:.2f}"
                padding = max(1, CHAR_WIDTH - len(name_part) - len(price_part))
                p.text(f"{name_part}{' ' * padding}{price_part}\n")
            p.set()

        p.text("-" * CHAR_WIDTH + "\n")

        def _total_line(label, value):
            val_str = f"{value:.2f}"
            pad = max(1, CHAR_WIDTH - len(label) - len(val_str))
            p.text(f"{label}{' ' * pad}{val_str}\n")

        if params.get("subtotal") is not None:
            _total_line("Subtotal:", params["subtotal"])
        if params.get("tax") is not None:
            _total_line("Tax:", params["tax"])
        if params.get("discount") is not None:
            _total_line("Discount:", -abs(params["discount"]))

        total = params.get("total")
        if total is not None:
            p.text("=" * CHAR_WIDTH + "\n")
            p.set(bold=True, width=2, height=1, custom_size=True)
            label = "TOTAL:"
            val_str = f"{total:.2f}"
            eff_width = CHAR_WIDTH // 2
            pad = max(1, eff_width - len(label) - len(val_str))
            p.text(f"{label}{' ' * pad}{val_str}\n")
            p.set()
            p.text("=" * CHAR_WIDTH + "\n")

        footer = params.get("footer")
        if footer:
            p.text("\n")
            p.set(align="center")
            p.text(f"{footer}\n")
            p.set()

        p.text("\n")
        p.set(align="center")
        p.text(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        p.set()

        lines_after = params.get("lines_after", 0)
        cut = params.get("cut", True)
        feed_lines = lines_after if lines_after > 0 else MIN_FEED_BEFORE_CUT
        if cut:
            p.text("\n" * feed_lines)
            p.cut(feed=False)
        elif lines_after > 0:
            p.text("\n" * lines_after)
        _close_if_job_based(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def _exec_qr(printer_name, params):
    p = _connect_printer(printer_name)
    try:
        _init_printer(p)
        center = params.get("center", True)
        if center:
            p.set(align="center")
        p.qr(params["text"], size=params.get("size", 3))
        if center:
            p.set(align="left")
        lines_after = params.get("lines_after", 0)
        cut = params.get("cut", True)
        feed_lines = lines_after if lines_after > 0 else MIN_FEED_BEFORE_CUT
        if cut:
            p.text("\n" * feed_lines)
            p.cut(feed=False)
        elif lines_after > 0:
            p.text("\n" * lines_after)
        _close_if_job_based(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def _exec_barcode(printer_name, params):
    p = _connect_printer(printer_name)
    try:
        _init_printer(p)
        center = params.get("center", True)
        if center:
            p.set(align="center")
        p.barcode(
            params["code"],
            params.get("barcode_type", "CODE39"),
            height=params.get("height", 64),
            width=params.get("width", 2),
            pos="BELOW",
            font="A",
        )
        if center:
            p.set(align="left")
        lines_after = params.get("lines_after", 0)
        cut = params.get("cut", True)
        feed_lines = lines_after if lines_after > 0 else MIN_FEED_BEFORE_CUT
        if cut:
            p.text("\n" * feed_lines)
            p.cut(feed=False)
        elif lines_after > 0:
            p.text("\n" * lines_after)
        _close_if_job_based(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def _exec_raw(printer_name, params):
    p = _connect_printer(printer_name)
    try:
        p._raw(params["data"])
        _close_if_job_based(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


# Print type dispatch
PRINT_HANDLERS = {
    "text": _exec_text,
    "receipt": _exec_receipt,
    "qr": _exec_qr,
    "barcode": _exec_barcode,
    "raw": _exec_raw,
}


# ─── Pydantic models ─────────────────────────────────────────

class ReceiptItem(BaseModel):
    name: str
    qty: int = 1
    price: float = 0.0


class PrintRequest(BaseModel):
    type: str
    cut: bool = True
    lines_after: int = 0

    # text fields
    text: Optional[str] = None
    bold: bool = False
    underline: int = 0
    width: int = 1
    height: int = 1
    align: str = "left"
    invert: bool = False

    # receipt fields
    header: str = "BARAKA"
    subheader: Optional[str] = None
    items: List[ReceiptItem] = []
    subtotal: Optional[float] = None
    tax: Optional[float] = None
    discount: Optional[float] = None
    total: Optional[float] = None
    footer: Optional[str] = None

    # qr fields
    size: int = 3
    center: bool = True

    # barcode fields
    code: Optional[str] = None
    barcode_type: str = "CODE39"
    # height and width are shared with text (reused)

    # raw fields
    base64: Optional[str] = None
    hex: Optional[str] = None


# ─── API Endpoints ───────────────────────────────────────────

@app.get("/api/health")
def health():
    return {
        "ok": True,
        "status": "running",
        "version": "2.0.0",
        "printers": len(PRINTERS),
    }


@app.post("/api/printers/register-usb")
def register_usb_printers():
    """
    Windows only: auto-detect USB printer ports and create printer queues
    with the 'Generic / Text Only' driver. No manual setup needed.
    """
    if _platform.system() != "Windows":
        return {
            "success": True,
            "message": "Not needed on Linux — USB printers are accessed via /dev/usb/lp*",
            "registered": 0,
        }

    try:
        import subprocess
        # Find USB ports without a printer queue and auto-register them
        ps_script = r"""
$results = @()
$usbPorts = Get-PrinterPort | Where-Object { $_.Name -like 'USB*' }
$existingPrinters = Get-Printer

# Try these driver names in order — different Windows versions have different names
$driverCandidates = @(
    'Generic / Text Only',
    'Generic/Text Only',
    'MS Publisher Imagesetter'
)

# Find a working driver
$driverName = $null
$installedDrivers = Get-PrinterDriver -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name

foreach ($candidate in $driverCandidates) {
    if ($installedDrivers -contains $candidate) {
        $driverName = $candidate
        break
    }
}

# If no known driver found, install 'Generic / Text Only'
if (-not $driverName) {
    # Step 1: Register ntprint.inf via pnputil first
    $infPath = Join-Path $env:SystemRoot 'INF\ntprint.inf'
    if (Test-Path $infPath) {
        try { pnputil /add-driver $infPath /install 2>&1 | Out-Null } catch {}
    }
    # Step 2: Now Add-PrinterDriver can find it
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
    # Last resort: use any available driver
    $anyDriver = $installedDrivers | Select-Object -First 1
    if ($anyDriver) {
        $driverName = $anyDriver
    } else {
        @{ port = 'N/A'; status = 'failed'; error = 'No printer drivers available. Run: Add-PrinterDriver -Name "Generic / Text Only"' } | ConvertTo-Json -Compress
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
        result = subprocess.run(
            ["powershell", "-ExecutionPolicy", "Bypass", "-Command", ps_script],
            capture_output=True, text=True, timeout=30,
        )

        if result.returncode != 0:
            return {
                "success": False,
                "error": result.stderr.strip() or "PowerShell command failed",
            }

        import json as _json
        output = result.stdout.strip()
        if not output or output == "":
            return {"success": True, "registered": 0, "message": "No USB printer ports found", "printers": []}

        printers = _json.loads(output)
        # PowerShell returns a single object (not array) if only one result
        if isinstance(printers, dict):
            printers = [printers]

        created = [p for p in printers if p.get("status") == "created"]
        return {
            "success": True,
            "registered": len(created),
            "printers": printers,
        }

    except Exception as e:
        return {"success": False, "error": str(e)}


@app.get("/api/printers")
def get_printers():
    """
    SSE endpoint that streams printer discovery results.

    Events:
      - event: status    → {"phase": "system"|"serial"|"network"|"done", "message": "..."}
      - event: printer   → {"name": "printer_1", "connection_type": "...", ...}
      - event: complete  → {"printers": {...}, "total": N}
    """
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

    def event_stream():
        discovery = PrinterDiscovery()
        discovered_hosts = set()

        for event in discovery.scan_streaming():
            if event["type"] == "status":
                yield f"event: status\ndata: {json.dumps(event)}\n\n"

            elif event["type"] == "network":
                ip = event["ip"]
                discovered_hosts.add(ip)
                found = {ip: {
                    "port": event["port"],
                    "mac": event.get("mac"),
                    "responsive": True,
                }}
                _merge_discovered_printers(found)
                name = _find_existing_by_host(ip)
                if name:
                    PRINTERS[name]["connection_type"] = "network"
                    yield f"event: printer\ndata: {json.dumps({'name': name, 'connection_type': 'network', 'host': ip, 'port': event['port'], 'mac': event.get('mac', 'unknown'), 'connected': True})}\n\n"

            elif event["type"] in ("system", "serial"):
                device = event["device"]
                conn_type = event["connection_type"]
                discovered_hosts.add(device)

                # Check if already registered
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
                yield f"event: printer\ndata: {json.dumps({'name': name, 'connection_type': conn_type, 'device': device, 'description': event.get('description', ''), 'connected': True})}\n\n"

        save_registry()

        # Final complete event with all printers
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

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@app.post("/api/printers/{name}/print")
async def api_print(name: str, req: PrintRequest):
    _validate_printer(name)

    print_type = req.type
    if print_type not in PRINT_HANDLERS:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown print type: {print_type}. Available: {list(PRINT_HANDLERS.keys())}",
        )

    params = req.model_dump()
    params.pop("printer", None)
    params.pop("type")

    if print_type == "raw":
        if not req.base64 and not req.hex:
            raise HTTPException(status_code=400, detail="Provide 'base64' or 'hex' field")
        if req.base64:
            params["data"] = base64.b64decode(req.base64)
        else:
            params["data"] = binascii.unhexlify(req.hex.strip())

    if print_type == "text" and not req.text:
        raise HTTPException(status_code=400, detail="'text' field is required for text type")

    if print_type == "qr" and not req.text:
        raise HTTPException(status_code=400, detail="'text' field is required for qr type")

    if print_type == "barcode" and not req.code:
        raise HTTPException(status_code=400, detail="'code' field is required for barcode type")

    if print_type == "receipt":
        params["items"] = [item.model_dump() for item in req.items]

    handler = PRINT_HANDLERS[print_type]
    _params = params.copy()
    _printer = name

    def execute():
        handler(_printer, _params)

    job_id = print_queue.submit(
        name,
        print_type,
        execute,
        {k: v for k, v in params.items() if k not in ("data", "execute_fn")},
    )
    return JSONResponse(
        status_code=202,
        content={
            "success": True,
            "job_id": job_id,
            "queued": True,
            "message": f"{print_type} print job queued for {name}",
            "printer": name,
        },
    )


# ─── Actions ─────────────────────────────────────────────────
# Actions are routed through the print queue so they:
# 1. Don't block the event loop (queue workers run in threads)
# 2. Are serialized per-printer (no spooler conflicts on Win32Raw)

def _action_beep(printer_name, params):
    logging.info(f"[ACTION] beep: connecting to {printer_name}")
    p = _connect_printer(printer_name)
    logging.info(f"[ACTION] beep: connected, sending init")
    try:
        _init_printer(p)
        c = max(1, min(9, params.get("count", 1)))
        d = max(1, min(9, params.get("duration", 1)))
        logging.info(f"[ACTION] beep: sending buzzer command (count={c}, duration={d})")
        try:
            p.buzzer(times=c, duration=d)
        except Exception:
            p._raw(b"\x1b\x42" + bytes([c]) + bytes([d]))
        logging.info(f"[ACTION] beep: closing connection")
        _close_if_job_based(printer_name, p)
        logging.info(f"[ACTION] beep: done")
    except Exception:
        logging.error(f"[ACTION] beep: failed on {printer_name}", exc_info=True)
        evict_printer_connection(printer_name)
        raise


def _action_cut(printer_name, params):
    logging.info(f"[ACTION] cut: connecting to {printer_name}")
    p = _connect_printer(printer_name)
    logging.info(f"[ACTION] cut: connected, sending init")
    try:
        _init_printer(p)
        cut_mode = "PART" if params.get("mode", "partial").lower() in ("partial", "part") else "FULL"
        feed_lines = params.get("lines_before", 0)
        if feed_lines <= 0:
            feed_lines = MIN_FEED_BEFORE_CUT
        logging.info(f"[ACTION] cut: sending cut command (mode={cut_mode}, feed={feed_lines})")
        p.text("\n" * feed_lines)
        p.cut(mode=cut_mode, feed=False)
        logging.info(f"[ACTION] cut: closing connection")
        _close_if_job_based(printer_name, p)
        logging.info(f"[ACTION] cut: done")
    except Exception:
        logging.error(f"[ACTION] cut: failed on {printer_name}", exc_info=True)
        evict_printer_connection(printer_name)
        raise


def _action_open_cash(printer_name, params):
    logging.info(f"[ACTION] openCash: connecting to {printer_name}")
    p = _connect_printer(printer_name)
    logging.info(f"[ACTION] openCash: connected, sending init")
    try:
        _init_printer(p)
        pin_val = 0 if params.get("pin", 0) == 0 else 1
        t1_val = max(0, min(255, params.get("t1", 100)))
        t2_val = max(0, min(255, params.get("t2", 100)))
        logging.info(f"[ACTION] openCash: sending pulse (pin={pin_val}, t1={t1_val}, t2={t2_val})")
        p._raw(b"\x1b\x70" + bytes([pin_val, t1_val, t2_val]))
        logging.info(f"[ACTION] openCash: closing connection")
        _close_if_job_based(printer_name, p)
        logging.info(f"[ACTION] openCash: done")
    except Exception:
        logging.error(f"[ACTION] openCash: failed on {printer_name}", exc_info=True)
        evict_printer_connection(printer_name)
        raise


@app.post("/api/printers/{name}/actions/beep")
async def action_beep(
    name: str,
    count: int = Query(1),
    duration: int = Query(1),
):
    _validate_printer(name)
    params = {"count": count, "duration": duration}

    def execute():
        _action_beep(name, params)

    job_id = print_queue.submit(name, "beep", execute, params)
    return JSONResponse(
        status_code=202,
        content={"success": True, "job_id": job_id, "queued": True, "message": f"Beep queued for {name}", "printer": name},
    )


@app.post("/api/printers/{name}/actions/cut")
async def action_cut(
    name: str,
    lines_before: int = Query(0),
    mode: str = Query("partial"),
):
    _validate_printer(name)
    params = {"lines_before": lines_before, "mode": mode}

    def execute():
        _action_cut(name, params)

    job_id = print_queue.submit(name, "cut", execute, params)
    return JSONResponse(
        status_code=202,
        content={"success": True, "job_id": job_id, "queued": True, "message": f"Cut queued for {name}", "printer": name},
    )


@app.post("/api/printers/{name}/actions/openCash")
async def action_open_cash(
    name: str,
    pin: int = Query(0),
    t1: int = Query(100),
    t2: int = Query(100),
):
    _validate_printer(name)
    params = {"pin": pin, "t1": t1, "t2": t2}

    def execute():
        _action_open_cash(name, params)

    job_id = print_queue.submit(name, "openCash", execute, params)
    return JSONResponse(
        status_code=202,
        content={"success": True, "job_id": job_id, "queued": True, "message": f"Cash drawer queued for {name}", "printer": name},
    )


@app.post("/api/printers/{name}/actions/printImage")
async def action_print_image(
    name: str,
    image: UploadFile,
    center: bool = Query(True),
    paper_width: int = Query(510),
    cut: bool = Query(True),
    lines_after: int = Query(0),
):
    _validate_printer(name)

    if not image.filename:
        raise HTTPException(status_code=400, detail="No image provided")
    if not allowed_file(image.filename):
        raise HTTPException(
            status_code=400, detail=f"Invalid image type. Allowed: {ALLOWED_EXTENSIONS}"
        )

    filename = secure_filename(image.filename)
    unique_filename = f"{uuid.uuid4()}_{filename}"
    filepath = os.path.join(UPLOAD_FOLDER, unique_filename)

    content = await image.read()
    if len(content) > MAX_CONTENT_LENGTH:
        raise HTTPException(status_code=413, detail="File too large")

    with open(filepath, "wb") as f:
        f.write(content)

    optimized_path = _prepare_image_for_thermal(filepath, paper_width)

    _printer = name
    _filepath = optimized_path
    _center = center
    _cut = cut
    _lines_after = lines_after

    def execute():
        try:
            p = _connect_printer(_printer)
            try:
                _init_printer(p)
                if _center:
                    p.set(align="center")
                p.image(_filepath)
                if _center:
                    p.set(align="left")
                feed_lines = _lines_after if _lines_after > 0 else MIN_FEED_BEFORE_CUT
                if _cut:
                    p.text("\n" * feed_lines)
                    p.cut(feed=False)
                elif _lines_after > 0:
                    p.text("\n" * _lines_after)
                _close_if_job_based(_printer, p)
            except Exception:
                evict_printer_connection(_printer)
                raise
        finally:
            if os.path.exists(_filepath):
                try:
                    os.remove(_filepath)
                except Exception:
                    pass

    job_id = print_queue.submit(
        name,
        "image",
        execute,
        {"filename": filename, "center": center, "cut": cut},
    )
    return JSONResponse(
        status_code=202,
        content={
            "success": True,
            "job_id": job_id,
            "queued": True,
            "message": f"Image print job queued for {name}",
            "printer": name,
            "filename": filename,
        },
    )


# ─── Job Queue Management ────────────────────────────────────

@app.get("/api/printers/{name}/jobs")
def list_jobs(name: str):
    _validate_printer(name)
    jobs = print_queue.get_queue(printer_name=name)
    return {"success": True, "jobs": jobs, "count": len(jobs)}


@app.get("/api/printers/{name}/jobs/{job_id}")
def get_job(name: str, job_id: str):
    _validate_printer(name)
    job = print_queue.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")
    if job.get("printer") != name:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found on {name}")
    return {"success": True, "job": job}


@app.delete("/api/printers/{name}/jobs/{job_id}")
def cancel_job(name: str, job_id: str):
    _validate_printer(name)
    job = print_queue.get_job(job_id)
    if job is None or job.get("printer") != name:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found on {name}")
    cancelled = print_queue.cancel_job(job_id)
    if not cancelled:
        raise HTTPException(
            status_code=400,
            detail=f"Job {job_id} cannot be cancelled (not pending)",
        )
    return {"success": True, "message": f"Job {job_id} cancelled"}


@app.get("/api/queue/status")
def queue_status():
    status = print_queue.get_status()
    return {"success": True, **status}


# ─── Main ────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn

    log_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.log")
    _hidden_mode = sys.stdout is None or not hasattr(sys.stdout, "write")
    if _hidden_mode:
        _log_fh = open(log_file, "a", encoding="utf-8", buffering=1)
        sys.stdout = _log_fh
        sys.stderr = _log_fh

    root_logger = logging.getLogger()
    for h in root_logger.handlers[:]:
        root_logger.removeHandler(h)

    log_handler = logging.StreamHandler(sys.stdout)
    log_handler.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    )
    root_logger.setLevel(logging.INFO)
    root_logger.addHandler(log_handler)

    if not _hidden_mode:
        file_handler = logging.FileHandler(log_file, encoding="utf-8")
        file_handler.setFormatter(
            logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
        )
        root_logger.addHandler(file_handler)

    print("=" * 50)
    print("Baraka Printer Server v2.0.0")
    print("=" * 50)

    # Load existing registry on startup (no network scan)
    load_registry()

    if PRINTERS:
        print(f"\nLoaded {len(PRINTERS)} printer(s) from registry:")
        for name, config in PRINTERS.items():
            print(f"  {name}: {config['host']}:{config['port']} (MAC: {config.get('mac', 'unknown')})")
    else:
        print("\nNo printers in registry. Use GET /api/printers to discover.")

    print(f"\nStarting server on {SERVER_HOST}:{SERVER_PORT}")
    print(f"  Health:    GET  /api/health")
    print(f"  Printers:  GET  /api/printers")
    print(f"  Print:     POST /api/print")
    print(f"  Actions:   POST /api/actions?type=beep|cut|openCash|printImage")
    print(f"  Jobs:      GET  /api/jobs")

    uvicorn.run(
        app,
        host=SERVER_HOST,
        port=SERVER_PORT,
        timeout_keep_alive=30,
        # h11 is pure-Python HTTP parser — more reliable on Windows than httptools
        http="h11",
    )
