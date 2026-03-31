import logging
import os
import sys

from dotenv import load_dotenv

load_dotenv()

from settings.config import SERVER_HOST, SERVER_PORT
from settings.registry import PRINTERS, load_registry
from api.api import app  # noqa: F401 — needed for uvicorn

def _disable_quickedit_windows():
    """Disable QuickEdit Mode on Windows console.
    Without this, clicking the terminal window pauses the entire process
    until Enter is pressed — freezing all printer jobs.
    """
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-10)  # STD_INPUT_HANDLE
        mode = ctypes.c_ulong()
        kernel32.GetConsoleMode(handle, ctypes.byref(mode))
        # Disable ENABLE_QUICK_EDIT_MODE (0x0040) and ENABLE_INSERT_MODE (0x0020)
        mode.value &= ~0x0040
        mode.value &= ~0x0020
        # Enable ENABLE_EXTENDED_FLAGS (0x0080) — required for the above to take effect
        mode.value |= 0x0080
        kernel32.SetConsoleMode(handle, mode)
    except Exception:
        pass  # Not on Windows or no console


if __name__ == "__main__":
    import platform
    import uvicorn

    if platform.system() == "Windows":
        _disable_quickedit_windows()

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
    log_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    root_logger.setLevel(logging.INFO)
    root_logger.addHandler(log_handler)

    if not _hidden_mode:
        file_handler = logging.FileHandler(log_file, encoding="utf-8")
        file_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
        root_logger.addHandler(file_handler)

    print("=" * 50)
    print("Baraka Printer Server v2.0.0")
    print("=" * 50)

    load_registry()

    if PRINTERS:
        print(f"\nLoaded {len(PRINTERS)} printer(s) from registry:")
        for name, config in PRINTERS.items():
            print(f"  {name}: {config['host']}:{config['port']} ({config.get('connection_type', 'network')})")
    else:
        print("\nNo printers in registry. Use GET /api/printers to discover.")

    print(f"\nStarting server on {SERVER_HOST}:{SERVER_PORT}")
    print(f"  Health:    GET  /api/health")
    print(f"  Printers:  GET  /api/printers")
    print(f"  Print:     POST /api/printers/{{name}}/print")
    print(f"  Actions:   POST /api/printers/{{name}}/actions/beep|cut|openCash|printImage")
    print(f"  Jobs:      GET  /api/printers/{{name}}/jobs")

    uvicorn.run(
        app,
        host=SERVER_HOST,
        port=SERVER_PORT,
        timeout_keep_alive=30,
        http="h11",
    )
