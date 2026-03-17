# Architecture

**Analysis Date:** 2026-03-17

## Pattern Overview

**Overall:** Modular, event-driven API server with pluggable printer backends

**Key Characteristics:**
- Monolithic FastAPI application with separate concerns isolated into modules
- Job queue replaces CUPS spooler for thread-safe, per-printer job sequencing
- Connection pooling for TCP socket reuse (critical for resource-constrained Windows)
- Multi-strategy printer discovery (TCP scan + MAC resolution via HTTP/SNMP/ARP)
- WSA bridge provides localhost forwarding for Android app integration

## Layers

**API/HTTP Layer (`printer_server.py`):**
- Purpose: Handle all HTTP requests, parameter validation, response formatting
- Location: `printer_server.py` (lines 330-959)
- Contains: 15+ endpoints covering text, image, receipt, QR, barcode, control commands
- Depends on: FastAPI, Pydantic, python-escpos, Pillow, print_queue, printer_discovery
- Used by: External clients (curl, mobile apps, POS systems)

**Printer Connection Pool (`printer_server.py`):**
- Purpose: Manage persistent TCP connections to thermal printers, prevent socket leaks
- Location: `printer_server.py` (lines 65-68, 200-251)
- Contains: Thread-safe cache with health checks, connection eviction on failure
- Depends on: python-escpos Network class, threading.Lock
- Used by: All print endpoints

**Print Job Queue (`print_queue.py`):**
- Purpose: Replace CUPS spooler - serialize jobs per printer, handle retries, track status
- Location: `print_queue.py` (all 242 lines)
- Contains: Per-printer worker threads, exponential backoff retry logic, job history
- Depends on: Python threading, queue module, UUID
- Used by: All print endpoints (text, image, receipt, QR, barcode, raw)

**Printer Discovery (`printer_discovery.py`):**
- Purpose: Network scan for thermal printers on port 9100, resolve MAC addresses
- Location: `printer_discovery.py` (all 491 lines)
- Contains: Parallel TCP scan (50 workers), 4-strategy MAC resolution, gateway filtering
- Depends on: socket, subprocess, concurrent.futures
- Used by: Server startup, `/printers/discover` endpoint

**WSA Bridge (`wsa_bridge.py`):**
- Purpose: Set up adb reverse tunnel for Android Subsystem for Windows access
- Location: `wsa_bridge.py` (all 242 lines)
- Contains: ADB connection management, tunnel monitoring, auto-reconnect
- Depends on: subprocess, adb executable
- Used by: Server startup (optional, disabled if ADB missing)

**Configuration & Persistence (`printer_server.py`):**
- Purpose: Load/save printer registry, environment variable handling
- Location: `printer_server.py` (lines 46-61, 77-140)
- Contains: Registry JSON file handling, PRINTERS dict, config parsing
- Used by: Startup sequence, discovery merge logic

## Data Flow

**On Server Startup:**
1. Load environment variables from `.env`
2. If `SCAN_ON_STARTUP=true`: Clear registry → Scan network → Merge results → Save registry
3. Else: Load printers from `printer_registry.json`
4. If `WSA_BRIDGE_ENABLED=true`: Set up adb reverse tunnel
5. If `TEST_PRINT_ON_STARTUP=true`: Print test receipt on each printer

**On Print Request (e.g., `/print/text`):**
1. Validate printer exists in PRINTERS dict
2. Create closure capturing print parameters
3. Submit closure to PrintQueue for printer_name
4. PrintQueue: Enqueue job, ensure worker thread exists, return job_id immediately
5. Worker thread: Dequeue job, mark PRINTING, execute closure, mark DONE or retry
6. Closure execution: Get/create pooled connection → Send ESC/POS commands → Release
7. On error: Evict connection, throw RuntimeError (caught by queue for retry)

**State Management:**
- **PRINTERS dict**: Master list of configured printers (dict[str, dict])
  - Keyed by "printer_1", "printer_2", etc.
  - Values: {"host": str, "port": int, "mac": str}
  - Sourced from: Discovery scan or registry JSON
  - Protected by: Loaded during startup (not modified after)

- **_printer_connections dict**: Active TCP connections to printers
  - Keyed by printer name
  - Values: Network objects (python-escpos)
  - Protected by: `_pool_lock` (threading.Lock)
  - Lifecycle: Created on first use, health-checked on reuse, evicted on error

- **print_queue**: Per-printer job queue with worker threads
  - Maintains: Dict of Queue objects (one per printer)
  - Job states: PENDING → PRINTING → (DONE/FAILED/CANCELLED) → HISTORY
  - Workers: Daemon threads, auto-spawn per printer, exit when idle
  - Retries: Exponential backoff (2^n * base_delay)

- **printer_registry.json**: Persistent storage (auto-generated)
  - Format: Dict mapping printer_1 → {"name", "last_ip", "port", "mac", "last_seen"}
  - Refreshed: On discovery scan or explicit `/printers/discover`
  - Consumed: On startup if `SCAN_ON_STARTUP=false`

## Key Abstractions

**PrinterDiscovery:**
- Purpose: Abstract network scanning details
- Examples: `printer_discovery.py` (PrinterDiscovery class)
- Pattern: Stateless scanner with 4-method MAC resolution pipeline
  - Strategy 1: HTTP web interface scraping (JK-E02 modules on port 80)
  - Strategy 2: SNMP OID 1.3.6.1.2.1.2.2.1.6 (raw packet, no pysnmp)
  - Strategy 3: ARP cache (after ping), with gateway MAC filtering
  - Strategy 4: None (fallback when all fail)

**PrintQueue:**
- Purpose: Abstract job management and retry logic
- Examples: `print_queue.py` (PrintQueue class)
- Pattern: Thread-pool pattern - one worker per printer, each pulls from its own Queue
  - Job submission returns immediately (async)
  - Retry on RuntimeError with exponential backoff
  - Permanent failure after max_retries exceeded

**Network Connection (python-escpos):**
- Purpose: Abstract ESC/POS printer protocol
- Examples: `from escpos.printer import Network`
- Pattern: Pooled TCP client - reused across requests, health-checked on use
  - Lazy initialization: Created only when first needed
  - Health check: Try to get socket peer name on reuse
  - Closure pattern: Each print endpoint creates closure capturing local vars

**Image Optimization Pipeline (Pillow):**
- Purpose: Convert any image format to 1-bit dithered for thermal printer
- Examples: `printer_server.py` (_prepare_image_for_thermal function, lines 253-297)
- Pattern: Sequential transformation - RGBA → RGB → resize → contrast → gamma → dither

**ESC/POS Initialization:**
- Purpose: Clear printer state before each job
- Examples: `printer_server.py` (_init_printer function, lines 193-197)
- Pattern: Send hardware reset bytes before any print operation

## Entry Points

**HTTP Server:**
- Location: `printer_server.py` (line 1170)
- Triggers: `python printer_server.py` or scheduled task
- Responsibilities: Listen on SERVER_HOST:SERVER_PORT, handle all API requests

**Print Endpoints:**
- Locations: `printer_server.py` (lines 440-913)
- Triggers: POST/GET from external clients
- Responsibilities: Validate input, submit to queue, return job_id

**Discovery Endpoint:**
- Location: `printer_server.py` (lines 418-435)
- Triggers: POST to `/printers/discover`
- Responsibilities: Scan network, merge results, save registry

**Job Queue Workers:**
- Location: `print_queue.py` (_worker_loop, lines 156-229)
- Triggers: Auto-spawned per printer on first job
- Responsibilities: Dequeue jobs, execute, retry or move to history

**Network Scan:**
- Location: `printer_discovery.py` (scan method, lines 44-86)
- Triggers: On server startup (if SCAN_ON_STARTUP=true) or via endpoint
- Responsibilities: Parallel TCP scan, MAC resolution, return found printers dict

## Error Handling

**Strategy:** Defensive - multiple exception handlers, connection eviction, job retry

**Patterns:**

1. **HTTP-level exceptions** (`printer_server.py` lines 157-186):
   - Global handler catches any unhandled Exception → 500 + JSON error response
   - Escpos-specific handler → 500 + "Printer error" message
   - Validation handler → 422 + validation details
   - HTTP handler → propagates status code

2. **Connection errors** (`printer_server.py` lines 200-231):
   - `_connect_printer` raises RuntimeError on connection failure
   - HTTP wrapper `get_printer` converts RuntimeError → HTTPException 500
   - Closure catches exception, calls `evict_printer_connection`, re-raises
   - Queue catches RuntimeError, retries exponentially

3. **Scan errors** (`printer_discovery.py` lines 82-83):
   - Individual host scans log debug messages on failure
   - Timeouts/OSErrors suppressed (logged as info if MAC lookup fails)
   - Scan continues even if some hosts fail

4. **Job failure** (`print_queue.py` lines 200-225):
   - Closure exception caught in worker loop
   - Retry count incremented, exponential delay applied
   - After max_retries, moved to history with STATUS_FAILED + error message

## Cross-Cutting Concerns

**Logging:** Python stdlib logging module
- Handler: StreamHandler (console) + FileHandler (`server.log`)
- Format: `%(asctime)s [%(levelname)s] %(message)s`
- Levels: INFO for normal, DEBUG for scanner, WARNING for failures
- Special: Hidden mode (pythonw.exe) redirects stdout/stderr to file

**Validation:** Pydantic models for receipt endpoint, Query string parsing for others
- ReceiptRequest: `printer_server.py` (lines 568-584)
- Query params: FastAPI Query objects with descriptions
- Custom: Manual validation in endpoints (printer name existence check)

**Authentication:** None (requires network isolation or reverse proxy for security)
- No auth tokens, API keys, or session management
- Assumption: Server runs on local network or behind firewall
- Note: CORS enabled for all origins (no cross-origin restrictions)

**Rate Limiting:** None (relies on print queue worker throughput)
- Queue size: Unbounded (limited by memory)
- Worker concurrency: 1 per printer (sequential jobs)
- Timeout: Network socket timeout (3s for scanner, 10s for HTTP)

**Image Processing:** Pillow-based, synchronous
- Format handling: PNG, JPG, JPEG, BMP, GIF (validated on upload)
- Size limit: 20MB (configurable via MAX_CONTENT_LENGTH)
- Processing: Blocking call in print endpoint (submitted to queue immediately after)
- Cleanup: File deleted after print in finally block or on error

---

*Architecture analysis: 2026-03-17*
