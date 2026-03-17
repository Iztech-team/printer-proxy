# Codebase Structure

**Analysis Date:** 2026-03-17

## Directory Layout

```
baraka/
├── printer_server.py          # Main FastAPI app, HTTP endpoints, pool management
├── print_queue.py             # Thread-safe print job queue with per-printer workers
├── printer_discovery.py       # Network scanner for port 9100 printers
├── wsa_bridge.py              # ADB reverse tunnel manager for WSA
├── windows_setup.ps1          # PowerShell setup script (auto-installs everything)
├── setup.bat                  # Shortcut to run setup as Admin
├── start_server_hidden.vbs    # VBScript to launch server silently
├── requirements.txt           # Python dependencies
├── README.md                  # Project documentation
├── printer_registry.json      # Auto-generated, persisted printer database (created after first discovery)
├── server.log                 # Auto-generated, running logs (created on startup)
├── uploads/                   # Temporary directory for multipart file uploads
│   └── (transient image files)
└── (other directories from git/wsa/apk are not part of codebase structure)
```

## Directory Purposes

**Project Root:**
- Purpose: Standalone executable Python server with single-file entry point
- Contains: All source code, config, startup scripts
- Key files: `printer_server.py`, dependencies in `requirements.txt`

**uploads/ Directory:**
- Purpose: Temporary storage for uploaded image files
- Contains: UUID-prefixed PNG/JPG/BMP/GIF files
- Auto-created: On first image print request (mkdir in `printer_server.py` line 153)
- Cleanup: Files deleted after print (finally block in execute closure)
- Note: Not committed to git (listed in .gitignore, implied)

## Key File Locations

**Entry Points:**
- `printer_server.py` (lines 1093-1170): Server startup, initialization, uvicorn.run()
  - Loads environment config
  - Loads/scans printers
  - Sets up WSA bridge
  - Starts FastAPI server

**Configuration:**
- `.env`: Runtime configuration (not in repo, copy from .env.example)
  - Contains: SERVER_HOST, SERVER_PORT, SCAN_ON_STARTUP, WSA_BRIDGE_ENABLED, queue settings
- `printer_registry.json`: Auto-generated printer database
  - Created by: `save_registry()` after discovery
  - Loaded by: `load_registry()` if SCAN_ON_STARTUP=false

**Core Logic:**

**HTTP API Layer:**
- `printer_server.py` (lines 330-959): All 15+ endpoints
  - `/` and `/health`: Server status
  - `/printers` and `/printers/discover`: Printer discovery
  - `/print/text`, `/print/image`, `/print/receipt`, `/print/qr`, `/print/barcode`: Print operations
  - `/print-raw`: Raw ESC/POS bytes
  - `/cut`, `/beep`, `/drawer`, `/feed`: Printer control
  - `/jobs`, `/jobs/{job_id}`, `/queue/status`: Job management

**Print Queue Logic:**
- `print_queue.py` (all 242 lines): PrintQueue class
  - `submit()`: Enqueue job, return job_id (lines 44-69)
  - `_worker_loop()`: Per-printer worker thread (lines 156-229)
  - `get_job()`, `get_queue()`: Query job status (lines 71-93)
  - `cancel_job()`: Cancel pending job (lines 95-105)
  - `get_status()`: Queue health metrics (lines 107-136)

**Printer Discovery:**
- `printer_discovery.py` (all 491 lines): PrinterDiscovery class
  - `scan()`: Network scan for printers (lines 44-86)
  - `_get_real_mac()`: Multi-strategy MAC resolution (lines 167-199)
  - `_get_mac_http()`: HTTP web interface scraping (lines 203-249)
  - `_get_mac_snmp()`: Raw SNMP OID query (lines 279-305)
  - `_get_arp_mac()`: ARP cache lookup (lines 402-426)

**WSA Bridge:**
- `wsa_bridge.py` (all 242 lines): WSABridge class
  - `setup()`: Initialize adb tunnel (lines 42-79)
  - `_adb_connect()`: Connect to WSA ADB (lines 120-151)
  - `_adb_reverse()`: Set up port forwarding (lines 153-190)
  - `_monitor_loop()`: Periodic tunnel health check (lines 203-226)

**Support Functions:**

**Image Processing:**
- `printer_server.py` (_prepare_image_for_thermal, lines 253-297):
  - RGBA → RGB conversion
  - Resize to paper width
  - Gamma correction, contrast enhancement
  - Floyd-Steinberg 1-bit dithering

**Printer Connection Pool:**
- `printer_server.py` (_connect_printer, lines 200-231): Get/create pooled connection
- `printer_server.py` (evict_printer_connection, lines 242-250): Remove broken connection

**Receipt Formatting:**
- `printer_server.py` (print_receipt endpoint, lines 586-691):
  - Pydantic model for validation (ReceiptRequest, lines 573-584)
  - Dynamic padding for right-aligned prices
  - Bold/enlarged total line

**Test Utility:**
- `printer_server.py` (generate_test_image, lines 1004-1090):
  - Creates test receipt image with server/printer info
  - Uses PIL ImageDraw for text layout
  - Fallback font loading (Windows, Linux paths)

## Naming Conventions

**Files:**
- `printer_server.py`: Main server (snake_case)
- `printer_discovery.py`: Network discovery module (snake_case)
- `print_queue.py`: Job queue module (snake_case)
- `wsa_bridge.py`: Android bridge module (snake_case)
- `start_server_hidden.vbs`: Windows script (snake_case)
- `printer_registry.json`: Data file (snake_case, .json)
- `server.log`: Log file (lowercase, descriptive)

**Python Classes:**
- `PrinterDiscovery`: CamelCase (noun phrase)
- `PrintQueue`: CamelCase (noun phrase)
- `WSABridge`: CamelCase with acronym (WSA = Windows Subsystem for Android)
- `ReceiptRequest`: CamelCase (Pydantic BaseModel)
- `ReceiptItem`: CamelCase (Pydantic BaseModel)

**Python Functions:**
- `scan()`, `setup()`, `submit()`: Present tense imperative (actions)
- `load_registry()`, `save_registry()`: Past participle + object (state changes)
- `_connect_printer()`: Leading underscore indicates internal (not meant for direct HTTP use)
- `_prepare_image_for_thermal()`: Underscore + gerund (internal transformation)
- `allowed_file()`: Boolean predicate
- `get_local_ip()`: Getter function

**Environment Variables:**
- `SERVER_HOST`, `SERVER_PORT`: UPPERCASE_SNAKE_CASE
- `SCAN_ON_STARTUP`: Boolean flags (UPPERCASE)
- `QUEUE_MAX_RETRIES`, `QUEUE_RETRY_BASE_DELAY`: Feature group prefixed (QUEUE_*)
- `PRINTER_REGISTRY`: Config-related (UPPERCASE)
- `UPLOAD_FOLDER`, `MAX_CONTENT_LENGTH`: Resource-related (UPPERCASE)

**Global State:**
- `PRINTERS`: Dict of configured printers (UPPERCASE, immutable after startup)
- `_printer_connections`: Private connection pool (underscore prefix)
- `_pool_lock`: Threading lock (underscore prefix)
- `print_queue`: PrintQueue instance (lowercase, singleton)

**API Routes:**
- `/` and `/health`: Health checks (root paths)
- `/printers`: Printer management
- `/printers/discover`: One-word verb route
- `/print/text`, `/print/image`, `/print/receipt`, `/print/qr`, `/print/barcode`: Hierarchical noun/noun
- `/print-raw`: Hyphenated alternative name
- `/cut`, `/beep`, `/drawer`, `/feed`: Simple imperative verbs
- `/jobs`: Job listing and management
- `/jobs/{job_id}`: RESTful ID parameter
- `/queue/status`: Hierarchical status endpoint

**Job IDs:**
- UUID format: `str(uuid.uuid4())` → "550e8400-e29b-41d4-a716-446655440000"
- Truncated in logs: `job_id[:8]` → "550e8400"

**Printer Names:**
- `printer_1`, `printer_2`, etc.: Consistent numbering from discovery merge
- Format: "printer_" prefix + integer (1-indexed)
- Auto-assigned: Matching by MAC first, then IP, else new number

## Where to Add New Code

**New Print Job Type (e.g., new barcode format):**
- Primary code: `printer_server.py` (new endpoint function, ~50-80 lines after `/print/barcode`)
- Job submission: Call `print_queue.submit(printer, "job_type", execute, params_dict)`
- Closure: Capture print parameters, call `_connect_printer()`, send ESC/POS commands, handle errors

**New Printer Discovery Strategy (e.g., DHCP client list):**
- Implementation: Add method to PrinterDiscovery class in `printer_discovery.py`
- Integration: Call new method from `_get_real_mac()` pipeline (around line 176)
- Order: Insert before ARP (fallback) but after HTTP/SNMP

**New Configuration Option:**
- Definition: Add line in `printer_server.py` lines 46-61 (os.getenv call)
- Usage: Reference as global constant in endpoints/startup
- Documentation: Add to README.md configuration section

**New API Endpoint:**
- File: `printer_server.py` (add after similar endpoint group)
- Decorator: `@app.get()`, `@app.post()`, or `@app.api_route()` for multi-method
- Pattern: Query/body validation → error checks → print_queue.submit() or direct action
- Return: JSONResponse with status_code and JSON body

**Utility Functions:**
- Shared helpers: `printer_server.py` (add near similar functions, e.g., near `allowed_file()`)
- Connection-related: Add near `_connect_printer()` and `evict_printer_connection()`
- Image-related: Add near `_prepare_image_for_thermal()`

**Logging:**
- Use: `logging.getLogger(__name__).info()`, `.warning()`, `.error()`, `.debug()`
- Format: Already configured globally (format string in `printer_server.py` lines 1112-1113)
- Prefix: Use `[TAG]` in message for categorization (e.g., `[QUEUE]`, `[PRINTER]`)

## Special Directories

**uploads/ Directory:**
- Purpose: Temporary image file storage
- Generated: Yes (created if missing)
- Committed: No (git-ignored)
- Lifetime: Files created by `/print/image`, deleted after print in finally block
- Cleanup: Automatic per-file; directory remains persistent

**WSA_2311... Directory:**
- Purpose: Windows Subsystem for Android installation (not part of Python codebase)
- Generated: By Windows or setup script
- Committed: No (too large)
- Note: Referenced by windows_setup.ps1 but separate from server code

**.planning/ Directory:**
- Purpose: GSD documentation (architecture, structure, testing, etc.)
- Generated: By GSD commands
- Committed: Yes
- Contains: ARCHITECTURE.md, STRUCTURE.md, CONVENTIONS.md, TESTING.md, CONCERNS.md

**.git/ Directory:**
- Purpose: Version control (not part of logical codebase)
- Generated: Yes
- Committed: No (git internal)

## File Size and Complexity

**printer_server.py:** 1171 lines
- Largest file
- Contains: API app, endpoints, connection pool, initialization, image processing
- Entry point for server startup

**printer_discovery.py:** 491 lines
- Network scanning and MAC resolution
- Multi-platform support (Windows/Linux/macOS)
- SNMP packet building from scratch (no external SNMP lib)

**print_queue.py:** 242 lines
- Focused job queue implementation
- Per-printer worker pattern
- Retry logic and history management

**wsa_bridge.py:** 242 lines
- ADB tunnel management
- Auto-reconnect monitoring
- Windows-specific path handling

**Total Python:** ~2146 lines (implementation + comments)

---

*Structure analysis: 2026-03-17*
