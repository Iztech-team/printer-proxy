# Coding Conventions

**Analysis Date:** 2026-03-17

## Naming Patterns

**Files:**
- Lowercase with underscores: `printer_server.py`, `printer_discovery.py`, `print_queue.py`, `wsa_bridge.py`
- Descriptive names that reflect the module's primary responsibility

**Functions and Methods:**
- Lowercase with underscores (snake_case): `_connect_printer()`, `load_registry()`, `_get_real_mac()`
- Private functions prefixed with single underscore: `_init_printer()`, `_prepare_image_for_thermal()`, `_detect_subnet()`
- Public methods (no underscore prefix): `scan()`, `submit()`, `get_job()`, `check_printer()`
- Async functions use `async def` with same naming: `async def print_text()`, `async def print_image()`

**Variables:**
- Lowercase with underscores for normal variables: `job_id`, `printer_name`, `found_mac`, `local_ip`
- Uppercase with underscores for constants/class attributes: `PRINTER_PORT`, `SCAN_TIMEOUT`, `MAX_WORKERS`, `STATUS_PENDING`
- Underscore prefix for internal/protected attributes: `_gateway_mac`, `_queues`, `_workers`, `_lock`

**Types:**
- Use Pydantic BaseModel for request/response schemas: `ReceiptItem`, `ReceiptRequest`
- Type hints throughout: `def _connect_printer(printer_name: str) -> Network:`, `def get_job(self, job_id: str) -> dict | None:`
- Union types use pipe syntax (Python 3.10+): `dict | None`

**Classes:**
- PascalCase: `PrinterDiscovery`, `PrintQueue`, `WSABridge`
- One class per module (with rare exceptions)

## Code Style

**Formatting:**
- No explicit formatter configured (no `.prettierrc` or linter config files detected)
- Visual inspection shows:
  - 4-space indentation (Python standard)
  - Line length typically under 100 characters
  - Blank lines between logical sections (see section dividers like `# ─── Configuration ───`)

**Linting:**
- No `.pylintrc`, `.flake8`, or `eslint` config detected
- No linter dependencies in `requirements.txt`

**Code Organization:**
- Section dividers with visual separators: `# ─── Configuration ─────────────────────────────────────────`
- Related functions/classes grouped together
- Module-level globals at top (after imports), followed by functions, then classes
- Constants defined at module level as all-caps: `UPLOAD_FOLDER`, `MAX_CONTENT_LENGTH`

## Import Organization

**Order:**
1. Standard library imports: `os`, `sys`, `uuid`, `base64`, `binascii`, `json`, `socket`, `time`, `logging`, `threading`
2. Standard library classes/functions: `from typing import Optional, List`, `from datetime import datetime`, `from queue import Queue, Empty`
3. Third-party imports: `from pydantic import BaseModel, Field`, `from fastapi import FastAPI, ...`, `from PIL import Image, ...`, `from escpos.printer import Network`
4. Local imports: `from printer_discovery import PrinterDiscovery`, `from wsa_bridge import WSABridge`, `from print_queue import PrintQueue`

**Path Aliases:**
- Not used; imports use relative module names for local files

**Patterns:**
- Each import statement on its own line (no star imports)
- Grouped by category with blank lines between groups
- Comments between import groups are optional (observed in `printer_server.py`)

## Error Handling

**Patterns:**
- Exception handlers are explicit and typed: `except Exception as e:`, `except RuntimeError as e:`, `except (socket.timeout, OSError):`
- Bare `except Exception` used only at top-level handlers (FastAPI exception handlers, worker loops)
- Silent failures with `pass` in cleanup blocks (acceptable pattern):
  ```python
  try:
      conn.close()
  except Exception:
      pass
  ```
- Exceptions raised with descriptive messages:
  ```python
  raise RuntimeError(f"Cannot connect to {printer_name} ({config['host']}:{config['port']}): {e}")
  raise HTTPException(status_code=400, detail=f"Unknown printer: {printer}. Available: {list(PRINTERS.keys())}")
  ```

**Custom Exception Handling:**
- Uses framework exceptions (FastAPI's `HTTPException`, Pydantic's validation errors)
- Wraps business logic exceptions (RuntimeError) for distinction between layer concerns
- Printer-specific exception handler: catches `EscposError` from escpos library and converts to HTTP 500

**Logging Patterns:**
- Uses Python's built-in `logging` module: `logger = logging.getLogger(__name__)`
- `logging.info()` for success events: `logging.info(f"Found printer: {ip} (MAC: {mac or 'unknown'})")`
- `logging.warning()` for recoverable issues: `logging.warning(f"Could not load registry: {e}")`
- `logging.error()` for unrecoverable errors: `logging.error(f"  adb reverse failed: {result.stderr.strip()}")`
- `logging.debug()` for diagnostic details: `logger.debug(f"  Error scanning {ip}: {e}")`

## Comments and Documentation

**When to Comment:**
- Complex algorithms: MAC address detection multi-strategy approach (HTTP, SNMP, ARP)
- Non-obvious workarounds: WSA Hyper-V subnet filtering, GPIO factory reset for thermal printers
- Cross-cutting concerns: Thread safety with `_pool_lock`, connection pool eviction strategy
- Business logic: Printer matching by MAC first, then IP (handles DHCP changes)

**Module Documentation:**
- All modules have module-level docstrings:
  ```python
  """
  Baraka POS Printer Server - Windows Edition
  =============================================
  Drop-in replacement for the Raspberry Pi server.py.
  Uses FastAPI + python-escpos + Pillow for thermal printing.

  Auto-discovers printers on startup (fresh scan each time).
  Adds WSA bridge (adb reverse) for Android access.
  Prints test receipt on each printer at startup.
  """
  ```

**Function/Method Documentation:**
- Brief one-liner docstrings for simple functions: `"""Load printer registry from file, renumbering from printer_1."""`
- Multi-line docstrings for complex functions, parameters in plain English (not formatted):
  ```python
  """
  Get or create a printer connection. Thread-safe via _pool_lock.
  Raises RuntimeError on failure (safe for worker threads — the print
  queue catches RuntimeError and retries).
  """
  ```
- No explicit parameter/return documentation (no Sphinx/Google style)

**Inline Comments:**
- Strategic comments for non-obvious code blocks:
  ```python
  # ESC @ -- hardware reset to factory defaults
  p._raw(b'\x1b\x40')
  # Filter out WSA Hyper-V subnet and broadcast/network addresses
  if not ip.startswith("172.30.") and not ip.endswith(".255") and not ip.endswith(".0"):
  ```

## Function Design

**Size:**
- Small to medium functions (5-50 lines typical)
- Larger functions allowed for sequential workflows (e.g., `_prepare_image_for_thermal()` at 45 lines)
- Worker loops can be longer (~70 lines) when they encapsulate a coherent unit

**Parameters:**
- Use type hints: `def _connect_printer(printer_name: str) -> Network:`
- Keyword-only for API endpoints: `printer: str = Query("printer_1")` with default values
- Config passed via closures (captured variables) in queue execution:
  ```python
  _text, _printer, _cut = text, printer, cut
  def execute():
      # Uses _text, _printer, _cut
  ```

**Return Values:**
- Single return types with clear intent: `-> Network`, `-> str`, `-> dict | None`
- Optional returns use `| None` pattern, checked with `if result is None:`
- Returns in loops/workers exit early with `return` or `break`

## Module Design

**Exports:**
- All public classes and functions are module-level
- Convention: Internal/private items prefixed with `_`
- No explicit `__all__` lists

**Barrel Files:**
- Not used; each module is imported directly by name

**Initialization:**
- Module-level setup at bottom: logging configuration, FastAPI app setup
- `if __name__ == "__main__":` block for standalone testing (seen in `printer_discovery.py`, `wsa_bridge.py`)

## Threading and Concurrency

**Thread Safety:**
- Protected shared state with `threading.Lock()`: `with _pool_lock:` (see `printer_server.py:124`)
- Global state accessed only under lock: `_printer_connections`, `PRINTERS`
- Per-printer queues are thread-safe (`Queue` class)

**Worker Threads:**
- Daemon threads for background work: `daemon=True` (print queue workers, WSA bridge monitor)
- Shutdown signals via `threading.Event()`: `_shutdown.set()` for graceful termination
- Named threads for debugging: `name=f"print-worker-{printer_name}"`

## Type Annotations

**Pattern:**
- Used throughout codebase (Python 3.10+)
- Builtin generics: `dict[str, Queue]`, `list[dict]` instead of `Dict[str, Queue]`
- Union types: `dict | None` instead of `Optional[dict]`
- Pydantic models for HTTP validation:
  ```python
  class ReceiptRequest(BaseModel):
      header: str = "BARAKA"
      items: List[ReceiptItem] = []
  ```

---

*Convention analysis: 2026-03-17*
