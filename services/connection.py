import logging
import threading
from contextlib import contextmanager

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

_printer_connections = {}
_pool_lock = threading.Lock()


def init_printer(p):
    p._raw(_INIT_BYTES)


def _create_printer(config):
    conn_type = config.get("connection_type", "network")
    if conn_type == "network":
        return Network(config["host"], port=config["port"], timeout=10, profile="TM-T88III")
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


def _is_win32raw(printer_name: str) -> bool:
    config = PRINTERS.get(printer_name, {})
    return config.get("connection_type") == "win32raw"


def connect_printer(printer_name: str):
    """Get or create a printer connection. Thread-safe.
    Win32Raw: fresh connection each time (spooler needs open/close per job).
    All others: pooled — one persistent connection reused across jobs.
    """
    if printer_name not in PRINTERS:
        raise RuntimeError(f"Unknown printer: {printer_name}. Available: {list(PRINTERS.keys())}")

    config = PRINTERS[printer_name]

    # Win32Raw: always fresh (each open/close = one spooler job)
    if _is_win32raw(printer_name):
        try:
            printer = _create_printer(config)
            printer.open()
            return printer
        except Exception as e:
            raise RuntimeError(f"Cannot connect to {printer_name}: {e}")

    # All others: connection pool
    with _pool_lock:
        if printer_name in _printer_connections:
            conn = _printer_connections[printer_name]
            try:
                if conn.device is not None:
                    if hasattr(conn.device, "getpeername"):
                        conn.device.getpeername()
                    return conn
            except (OSError, AttributeError):
                pass
            # Connection is dead — remove and recreate
            try:
                conn.close()
            except Exception:
                pass
            _printer_connections.pop(printer_name, None)

        try:
            printer = _create_printer(config)
            printer.open()
            _printer_connections[printer_name] = printer
            return printer
        except Exception as e:
            _printer_connections.pop(printer_name, None)
            raise RuntimeError(f"Cannot connect to {printer_name}: {e}")


def finish_job(printer_name: str, printer):
    """Called after a job completes.
    Win32Raw: closes connection (flushes spooler job).
    All others: no-op (connection stays open in pool).
    """
    if printer is None:
        return
    if _is_win32raw(printer_name):
        try:
            printer.close()
        except Exception:
            pass


def evict_printer_connection(printer_name: str):
    """Remove a broken connection from the pool so the next job gets a fresh one."""
    with _pool_lock:
        conn = _printer_connections.pop(printer_name, None)
    if conn:
        try:
            conn.close()
        except Exception:
            pass


@contextmanager
def printer_session(printer_name):
    """Context manager that handles connect, init, and cleanup.
    On success: finishes the job (closes Win32Raw, keeps pool for others).
    On error: evicts the connection from pool so next job reconnects.
    """
    p = connect_printer(printer_name)
    try:
        init_printer(p)
        yield p
        finish_job(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def validate_printer(printer_name: str):
    if printer_name not in PRINTERS:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown printer: {printer_name}. Available: {list(PRINTERS.keys())}",
        )
