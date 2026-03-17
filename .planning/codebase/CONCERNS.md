# Codebase Concerns

**Analysis Date:** 2026-03-17

## Tech Debt

**Global mutable state in printer_server.py:**
- Issue: `PRINTERS` dict and `_printer_connections` dict are global module-level state accessed and modified by multiple request handlers and worker threads without clear encapsulation
- Files: `printer_server.py` (lines 63-68)
- Impact: Makes code harder to test, refactor, and reason about; potential race conditions despite `_pool_lock`
- Fix approach: Encapsulate printer registry and connection pool into a dedicated `PrinterManager` class with thread-safe methods

**Connection pool health check is crude:**
- Issue: `_connect_printer()` (lines 200-231) checks connection viability by calling `getpeername()`, but this doesn't verify the printer is actually responsive; a dead network connection might still have an open socket
- Files: `printer_server.py` (lines 212-215)
- Impact: May reuse stale connections to unresponsive printers; prints fail unnecessarily and retry
- Fix approach: Add an optional "test ping" (send minimal ESC/POS command) before reusing pooled connections; or add a max connection age to force refresh

**Printer discovery runs during startup with no timeout config:**
- Issue: `PrinterDiscovery.scan()` has a hardcoded `SCAN_TIMEOUT = 3` seconds, but scanning 254 hosts with 50 workers can still take 30-60+ seconds on slow networks
- Files: `printer_discovery.py` (lines 36, 56)
- Impact: Server startup is blocked; users see no feedback during long discovery scans; if discovery hangs, entire server startup hangs
- Fix approach: Make `SCAN_TIMEOUT` and `MAX_WORKERS` configurable via .env; add startup progress logging; run discovery in a background thread if timeout is exceeded

**Incomplete error recovery in worker threads:**
- Issue: `print_queue.py` worker loop (lines 156-227) catches all exceptions and retries, but some errors are unrecoverable (e.g., bad base64 data, image format error). Worker thread may die silently if an unexpected exception occurs outside the main try block
- Files: `print_queue.py` (lines 156-227)
- Impact: Failed jobs may hang forever if the worker thread crashes; no monitoring of worker thread health
- Fix approach: Add explicit checks for unrecoverable errors; add worker thread heartbeat monitoring; log worker thread crashes

**Image optimization modifies files in-place:**
- Issue: `_prepare_image_for_thermal()` (lines 253-297) modifies the image file directly using `img.save(filepath, "PNG")`, then uploads it. If two requests process the same image file, one overwrites the other's optimization
- Files: `printer_server.py` (lines 253-297, 516)
- Impact: Concurrent requests with identical filenames may corrupt uploaded image data; race condition in `uploads/` folder
- Fix approach: Never modify original uploaded file; create a separate temp file path for optimization; use secure temp directory with process/thread IDs in filename

**No validation of barcode data format:**
- Issue: `print_barcode()` endpoint (lines 741-782) accepts any barcode data without validating format for the specified barcode type (e.g., CODE39, EAN13 have different valid character sets)
- Files: `printer_server.py` (lines 741-782)
- Impact: Invalid barcodes fail at print time with generic escpos error; no helpful error message to client
- Fix approach: Pre-validate barcode data format before queueing job; return 400 with specific format error

**Test image generation crashes on missing fonts:**
- Issue: `generate_test_image()` (lines 1004-1090) tries multiple hardcoded font paths, but falls back to `ImageFont.load_default()` which may render poorly. No handling of text overflow if font is too small
- Files: `printer_server.py` (lines 1004-1090)
- Impact: Test receipt may render unreadably; no error handling if text is too large for image
- Fix approach: Use a font that's guaranteed to exist (Pillow's default or ship a bundled font); add text wrapping for long lines

**No cleanup of stale uploaded images:**
- Issue: Images uploaded via `/print/image` are saved to disk (line 524) and deleted after printing (line 552), but if printing fails or server crashes, orphaned image files may accumulate in `uploads/` folder
- Files: `printer_server.py` (lines 519-562)
- Impact: Disk space fills up over time; potential information leak if sensitive images are left
- Fix approach: Implement a periodic cleanup task that removes files older than 1 hour from `uploads/`; log cleanup actions

---

## Known Bugs

**Paper cut feed line calculation inconsistency:**
- Symptoms: Different endpoints calculate feed lines before cut differently; some use `MAX(feed_lines, MIN_FEED_BEFORE_CUT)`, others don't
- Files: `printer_server.py` (lines 474, 540, 672, 719, 766, 837)
- Trigger: Print text/image with `lines_after=0` and `cut=true`; observe some printers feed too little/too much
- Workaround: Manually set `lines_after` to match printer's needs instead of relying on `MIN_FEED_BEFORE_CUT`

**ARP MAC detection breaks behind NAT/secondary router:**
- Symptoms: Gateway MAC filtering in `_get_real_mac()` (line 193) treats printers behind secondary router as unreachable; MAC is lost
- Files: `printer_discovery.py` (lines 188-197)
- Trigger: Printer is on a secondary router with different gateway MAC than host; `_get_real_mac()` returns None
- Workaround: Use HTTP web interface or SNMP for MAC resolution (first two strategies do work)

**WSA bridge monitor thread never logs reconnection failures:**
- Symptoms: `_monitor_loop()` (lines 203-226) silently catches all exceptions and continues; if adb is uninstalled, user won't know bridge is broken
- Files: `wsa_bridge.py` (lines 225-226)
- Trigger: Uninstall ADB while server is running; check logs
- Workaround: Monitor logs manually; restart server to force setup() to run again

---

## Security Considerations

**CORS policy is wide open:**
- Risk: `allow_origins=["*"]` (line 147) allows any website to make requests to the printer server; malicious site could trigger prints
- Files: `printer_server.py` (lines 145-150)
- Current mitigation: Server is assumed to be on trusted local network only; no auth layer
- Recommendations:
  - Add `ALLOWED_ORIGINS` env var (whitelist localhost, LAN subnet)
  - Add optional API key authentication (Bearer token or API key header)
  - Document that server should only run on trusted networks

**No rate limiting:**
- Risk: Attacker can spam `/print/*` endpoints to exhaust printer, paper, or disk space (uploads folder)
- Files: `printer_server.py` (print endpoints)
- Current mitigation: Print queue has max_retries, but no per-client rate limit
- Recommendations:
  - Add per-IP rate limiting (FastAPI-Limiter or similar)
  - Add quota per printer (max N jobs per minute)
  - Add total upload size limit per time period

**Unvalidated file extension check:**
- Risk: `allowed_file()` (line 191) checks extension only; attacker could upload `.png` file with executable payload
- Files: `printer_server.py` (lines 190-191)
- Current mitigation: Pillow will fail to open non-image files, raising exception
- Recommendations:
  - Add MIME type validation (check file magic bytes, not extension)
  - Consider running image validation in a sandbox or using strict file format parser

**Subprocess execution without shell=False validation:**
- Risk: `PrinterDiscovery._get_gateway_ip()` and other subprocess calls use `subprocess.run()` safely (no shell=True), but parent process error handling is weak
- Files: `printer_discovery.py` (lines 136-153)
- Current mitigation: subprocess calls don't take user input directly; commands are hardcoded
- Recommendations:
  - Continue using hardcoded commands
  - Add subprocess timeout validation in more places (some are missing)

---

## Performance Bottlenecks

**Printer discovery scans all 254 IPs every startup:**
- Problem: Full /24 subnet scan is slow; even with 50 workers and 3s timeout, takes 30-60+ seconds if many IPs are unresponsive
- Files: `printer_discovery.py` (lines 44-86)
- Cause: Brute-force TCP connect scan with no optimization; no caching of known printers between restarts
- Improvement path:
  - Load cached printer list from `printer_registry.json` on startup (already done, but full scan still runs if `SCAN_ON_STARTUP=true`)
  - Add incremental discovery: scan only new IP ranges or recently offline printers
  - Increase `SCAN_TIMEOUT` if network is known to be slow; reduce `MAX_WORKERS` if system is resource-constrained

**Image optimization runs on main thread in print job:**
- Problem: `_prepare_image_for_thermal()` is CPU-intensive (image processing) and runs during print job execution, blocking the worker thread
- Files: `printer_server.py` (lines 526-527)
- Cause: Image prep is done before queueing job, so it blocks the HTTP response
- Improvement path:
  - Move image prep to upload endpoint (optimize immediately when file arrives)
  - Cache optimized images by hash to reuse across prints

**SNMP MAC resolution times out slowly:**
- Problem: `_get_mac_snmp()` (lines 279-305) has a 2-second timeout per printer, multiplied across 254 hosts = 8+ minutes worst case
- Files: `printer_discovery.py` (lines 289-290)
- Cause: SNMP is tried on every IP even if HTTP already succeeded
- Improvement path:
  - Skip SNMP if HTTP MAC was already found (already doing this)
  - Reduce SNMP timeout to 1 second if discovery time is critical

---

## Fragile Areas

**Print queue worker thread startup race:**
- Files: `print_queue.py` (lines 142-154)
- Why fragile: `_ensure_worker()` checks if worker is alive, but there's a race where `is_alive()` returns False right before thread actually starts. Two calls might create two workers for the same printer
- Safe modification: Lock check + creation together in `_ensure_worker()` (already using `_lock`, but logic is subtle)
- Test coverage: No test for concurrent submit() calls to same printer at same time
- Recommendation: Add integration test for parallel job submission

**Printer connection reuse and eviction:**
- Files: `printer_server.py` (lines 200-250)
- Why fragile: Connection pool assumes escpos `Network.close()` always succeeds; if close() hangs, the entire `_pool_lock` is held and server freezes
- Safe modification: Add timeout to `conn.close()` call using signal or thread; or remove connection from pool before closing
- Test coverage: No test for slow/hanging printer connections
- Recommendation: Test with a printer that's powered off or disconnected

**Global `PRINTERS` dict renumbering in `load_registry()`:**
- Files: `printer_server.py` (lines 82-99)
- Why fragile: Registry renumbers printers (printer_1, printer_2) on every load, breaking client references to printer names between restarts if printer order changes
- Safe modification: Use stable identifiers (MAC address, hostname) or consistent numbering based on MAC
- Test coverage: No test for registry load/save round-trip
- Recommendation: Add registry format versioning; use MAC as primary key internally

**WSA bridge auto-reconnect monitor silently fails:**
- Files: `wsa_bridge.py` (lines 203-226)
- Why fragile: `_monitor_loop()` has bare `except Exception` with pass; any error is silently ignored
- Safe modification: Log all exceptions; add a "connection state" flag and expose via health endpoint
- Test coverage: No test for monitor loop recovery
- Recommendation: Add `/wsa-bridge/status` endpoint to check bridge health

---

## Scaling Limits

**Print queue history is bounded but unbounded in memory:**
- Current capacity: `QUEUE_JOB_HISTORY_SIZE=100` (default, configurable)
- Limit: Each job dict stores all parameters and results; 100 jobs with 50KB each = 5MB; not huge, but no limit on active jobs
- Scaling path: Implement persistence layer (SQLite, Redis) for job history instead of in-memory deque; add disk cleanup policy

**Printer discovery network scan is single-threaded per subnet:**
- Current capacity: 50 concurrent workers per /24 subnet
- Limit: Breaks down if network has >500 total devices (reduces effectiveness of parallelism)
- Scaling path: Implement hierarchical scanning (scan /16, then /24 for found subnets); use Shodan or mDNS for vendor-specific discovery

**Upload folder has no quota:**
- Current capacity: Limited only by disk space; no garbage collection
- Limit: Long-running server with many image prints will fill disk
- Scaling path: Implement file quota (e.g., max 1GB in uploads/); add TTL-based cleanup; use S3 or cloud storage instead

**Connection pool size is unbounded:**
- Current capacity: One connection per printer in `_printer_connections`
- Limit: If 100 printers exist, pool stores 100 connections; no max connection limit per printer
- Scaling path: Add configurable pool size limit; implement LRU eviction

---

## Dependencies at Risk

**python-escpos 3.0+ may have breaking changes:**
- Risk: Currently pinned to `python-escpos>=3.0,<4.0.0`; major version upgrades often break APIs
- Impact: If escpos 4.0 releases, code may need updates (e.g., method signatures, exception types)
- Migration plan:
  - Monitor escpos releases and test with beta versions early
  - Create abstractions over escpos calls (e.g., `EscposWrapper` class) to simplify future migrations
  - Pin to specific minor version once API is stable

**python-dotenv version range is loose:**
- Risk: `python-dotenv>=1.0.0,<2.0.0`; if 2.0 API changes, code breaks at import
- Impact: Environment loading could fail, leaving all config at defaults
- Migration plan: Pin to specific minor version; test on each minor release

**Pillow 10.0+ has deprecated APIs:**
- Risk: `Image.Resampling.LANCZOS` (line 277) replaced old `Image.LANCZOS` in Pillow 10; code would break on Pillow <10
- Impact: Dependency resolution might downgrade to Pillow 9.x by accident if another package requires it
- Migration plan: Add explicit test for Pillow 10+ on each release; consider using try/except for deprecated APIs

---

## Missing Critical Features

**No printer status query:**
- Problem: Cannot query if printer is online, out of paper, or in error state before printing
- Blocks: Retry logic is blind; client can't make intelligent decisions about which printer to use
- Recommendation: Add `/printers/{name}/status` endpoint that sends a test command and reports printer responsiveness

**No authentication or access control:**
- Problem: Anyone on the network can trigger unlimited prints
- Blocks: Using server in untrusted environments; multi-user scenarios
- Recommendation: Add optional API key support; document in .env

**No observability (metrics, tracing):**
- Problem: Cannot measure print success rate, latency, or bottleneck identification
- Blocks: Performance optimization, SLA monitoring, debugging production issues
- Recommendation: Add Prometheus-compatible metrics endpoint (`/metrics`); track job latency, error rates per printer

**No webhook/callback for job completion:**
- Problem: Client must poll `/jobs/{job_id}` to know when job is done
- Blocks: Real-time integration with POS systems
- Recommendation: Add optional webhook callback mechanism

---

## Test Coverage Gaps

**Network discovery not tested:**
- What's not tested: `PrinterDiscovery.scan()`, MAC address resolution strategies (HTTP, SNMP, ARP)
- Files: `printer_discovery.py` (entire module)
- Risk: Discovery bugs only surface in production when actual network changes
- Priority: High
- Recommendation: Add unit tests with mock sockets; integration test with a fake printer on loopback

**Print queue retry logic not tested:**
- What's not tested: Exception handling, retry delay calculation, worker thread behavior
- Files: `print_queue.py` (lines 156-227)
- Risk: Retry logic may not work as designed; worker threads might deadlock or crash silently
- Priority: High
- Recommendation: Add unit tests for job retry; simulate printer failures

**Connection pool eviction not tested:**
- What's not tested: Broken connection detection, reconnection logic, concurrent access to pool
- Files: `printer_server.py` (lines 200-250)
- Risk: Pool may reuse broken connections; race conditions in pool lock
- Priority: Medium
- Recommendation: Add integration test with a printer that disconnects

**Image optimization not tested:**
- What's not tested: Gamma correction, dithering, transparency handling, format conversion
- Files: `printer_server.py` (lines 253-297)
- Risk: Optimized images may render poorly or cause escpos errors
- Priority: Medium
- Recommendation: Add test with sample images (logo, photo, text); visual comparison

**WSA bridge monitor thread not tested:**
- What's not tested: Reconnection logic, connection loss detection, concurrent access
- Files: `wsa_bridge.py` (lines 192-226)
- Risk: Bridge may fail to reconnect if ADB becomes unavailable
- Priority: Low (WSA-specific feature)
- Recommendation: Mock adb subprocess; test failure scenarios

**Endpoint validation not tested:**
- What's not tested: Query parameter validation, file upload validation, error responses
- Files: `printer_server.py` (endpoints)
- Risk: Invalid input may cause crashes instead of 400/422 errors
- Priority: Medium
- Recommendation: Add pytest tests for boundary conditions (empty text, huge file, invalid printer name)

---

*Concerns audit: 2026-03-17*
