import logging
import socket

from escpos.printer import Network
from fastapi import HTTPException

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

from settings.registry import PRINTERS

_INIT_BYTES = (
    b"\x1b\x40"
    b"\x1b\x45\x00"
    b"\x1b\x47\x00"
)


def init_printer(p):
    p._raw(_INIT_BYTES)


def _create_printer(config):
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
        return SerialPrinter(config["host"], baudrate=config.get("baudrate", 9600), profile="TM-T88III")
    else:
        raise RuntimeError(f"Unknown connection_type: {conn_type}")


def connect_printer(printer_name: str):
    """Create a fresh connection per job. No pooling — avoids stale sockets."""
    if printer_name not in PRINTERS:
        raise RuntimeError(f"Unknown printer: {printer_name}. Available: {list(PRINTERS.keys())}")

    config = PRINTERS[printer_name]
    try:
        printer = _create_printer(config)
        # Set a reasonable timeout for network printers (default is 60s — way too long)
        if hasattr(printer, 'device') and hasattr(printer, 'timeout'):
            printer.timeout = 10
        if hasattr(printer, 'open'):
            printer.open()
        return printer
    except Exception as e:
        raise RuntimeError(f"Cannot connect to {printer_name}: {e}")


def finish_job(printer_name: str, printer):
    """Close connection after a job."""
    if printer is None:
        return
    try:
        printer.close()
    except Exception:
        pass


def evict_printer_connection(printer_name: str):
    """Legacy — kept for compatibility. With per-job connections, this is a no-op."""
    pass


def validate_printer(printer_name: str):
    if printer_name not in PRINTERS:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown printer: {printer_name}. Available: {list(PRINTERS.keys())}",
        )
