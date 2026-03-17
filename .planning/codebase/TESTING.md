# Testing Patterns

**Analysis Date:** 2026-03-17

## Test Framework

**Status:**
- No automated testing framework configured (pytest, unittest, etc. not in `requirements.txt`)
- No test files found in codebase
- No test runner config (`pytest.ini`, `setup.cfg`, `tox.ini`, `pyproject.toml`)

**Current Testing Approach:**
- Manual testing via HTTP endpoints
- Standalone test blocks in modules (see `if __name__ == "__main__":` blocks)
- Print test receipts on startup: `TEST_PRINT_ON_STARTUP` environment variable

## Standalone Testing

**PrinterDiscovery Module:**
Location: `printer_discovery.py:481-490`

```python
if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    d = PrinterDiscovery()
    printers = d.scan()
    if printers:
        print(f"\nFound {len(printers)} printer(s):")
        for ip, info in printers.items():
            print(f"  {ip}:{info['port']} (MAC: {info.get('mac', 'unknown')})")
    else:
        print("\nNo printers found on this network.")
```

**WSABridge Module:**
Location: `wsa_bridge.py:230-241`

```python
if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG, format="%(message)s")
    bridge = WSABridge(server_port=3006)
    if bridge.setup():
        print("\nWSA bridge is active. Press Ctrl+C to stop.")
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            bridge.teardown()
    else:
        print("\nWSA bridge setup failed. Check the logs above.")
```

## Integration Testing

**Test Print on Startup:**
Location: `printer_server.py:963-1001`

The server includes a built-in integration test:

```python
def print_test_receipts():
    """Print a test receipt on every discovered printer (uses connection pool)."""
    local_ip = get_local_ip()
    for name, config in PRINTERS.items():
        print(f"  Sending test print to {name} @ {config['host']}...")
        # ... generates image, sends to printer, handles errors
```

Triggered by: `TEST_PRINT_ON_STARTUP=true` (default)

Verifies:
- Network connectivity to each printer
- Image generation and optimization pipeline
- ESC/POS command execution
- Connection pool functionality

## Manual API Testing Patterns

**Test Endpoints:**
Location: `README.md`

Example curl commands provided for each endpoint:

```bash
# Text printing
curl -X POST "http://localhost:3006/print/text?text=Hello+from+Baraka!&printer=printer_1&bold=true"

# Receipt printing
curl -X POST http://localhost:3006/print/receipt \
  -H "Content-Type: application/json" \
  -d '{
    "header": "BARAKA CAFE",
    "items": [{"name": "Cappuccino", "qty": 2, "price": 4.50}],
    "total": 13.80
  }'

# Image upload
curl -X POST "http://localhost:3006/print/image?printer=printer_1" \
  -F "image=@receipt.png"

# Health check
curl http://localhost:3006/health
```

## Error Handling Testing

**Validation Errors:**
Location: `printer_server.py:175-180`

Framework catches validation errors automatically:

```python
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(status_code=422, content={
        "success": False, "error": "Validation error",
        "detail": exc.errors(), "type": "ValidationError"
    })
```

**Printer Connection Errors:**
Location: `printer_server.py:200-239`

Tests error handling through connection pool:

```python
def _connect_printer(printer_name: str) -> Network:
    # Raises RuntimeError on connection failure
    # Workers catch and retry with exponential backoff
```

**Escpos Errors:**
Location: `printer_server.py:167-173`

Device-level errors caught and converted to HTTP 500:

```python
@app.exception_handler(EscposError)
async def escpos_exception_handler(request: Request, exc: EscposError):
    return JSONResponse(status_code=500, content={
        "success": False, "error": "Printer error",
        "detail": str(exc), "type": "PrinterError"
    })
```

## Queue Testing

**Job Lifecycle:**
Location: `print_queue.py:44-228`

PrintQueue includes built-in state management for testing:

**Submitting a job:**
```python
job_id = print_queue.submit("printer_1", "text", execute_fn, {"text": "Hello"})
# Returns immediately with job_id
```

**Checking status:**
```python
job = print_queue.get_job(job_id)
# Returns: {"status": "done", "retries": 0, ...} or None if completed
```

**Listing all jobs:**
```python
jobs = print_queue.get_queue(printer_name="printer_1")
# Returns active + recent jobs for printer
```

**Checking queue health:**
```python
status = print_queue.get_status()
# Returns: {"printers": {"printer_1": {"pending": 0, "printing": 0, "worker_alive": True}}}
```

## Retry Testing

**Automatic Retry on Failure:**
Location: `print_queue.py:156-227`

Worker loop implements retry logic:

```python
# Configuration
max_retries = 3  # from QUEUE_MAX_RETRIES env var
retry_base_delay = 1.0  # from QUEUE_RETRY_BASE_DELAY env var

# On failure, job is re-queued with exponential backoff
delay = retry_base_delay * (2 ** (retry_count - 1))
# Retry 1: 1s delay
# Retry 2: 2s delay
# Retry 3: 4s delay
```

Can be tested by:
1. Simulating printer failure (disconnect printer)
2. Submit job
3. Observe job retrying in logs: `[QUEUE] Job ... failed (attempt 1/3), retrying in 1.0s`
4. Reconnect printer
5. Job completes successfully

## Logging for Debugging

**Logger Setup:**
Location: `printer_server.py:1108-1120`

```python
log_handler = logging.StreamHandler(sys.stdout)
log_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
root_logger.setLevel(logging.INFO)
```

**Queue Logging:**
Location: `print_queue.py:19`

Uses module-level logger: `logger = logging.getLogger(__name__)`

Logged events:
- Job submission: `[QUEUE] Job {job_id[:8]} queued for {printer_name}`
- Job start: (status change tracked, not logged)
- Job completion: `[QUEUE] Job {job_id[:8]} completed on {printer_name}`
- Retry attempts: `[QUEUE] Job {job_id[:8]} failed (attempt {retry_count}/{max_retries}), retrying in {delay}s: {e}`
- Final failure: `[QUEUE] Job {job_id[:8]} failed permanently after {max_retries} retries: {e}`

**Discovery Logging:**
Location: `printer_discovery.py:23`

Module-level logger: `logger = logging.getLogger(__name__)`

Logged events:
- Network scan start: `Scanning {subnet}.0/24 on port {port}...`
- Printer found: `Found printer: {ip} (MAC: {mac or 'unknown'})`
- MAC resolution per strategy: `{ip}: got real MAC via HTTP web interface: {http_mac}`
- Scan completion: `Scan complete. Found {len(found)} printer(s).`

## Performance Testing

**Queue Benchmarking:**
The queue includes per-job timing:

```python
job = {
    "created_at": datetime.now().isoformat(),
    "started_at": None,      # Set when worker starts
    "completed_at": None,    # Set when complete or failed
}
```

Can calculate:
- Queue wait time: `started_at - created_at`
- Execution time: `completed_at - started_at`
- Total job time: `completed_at - created_at`

**Network Discovery Benchmarking:**
Location: `printer_discovery.py:44-86`

Uses `ThreadPoolExecutor(max_workers=50)` for parallel scanning:

- Each host timeout: `SCAN_TIMEOUT = 3` seconds
- Full subnet scan: ~6 seconds for 254 addresses in parallel
- MAC resolution adds network requests (HTTP, SNMP, ARP)

## Test Data and Fixtures

**No Fixture System:**
- No fixture library or factory pattern implemented
- Test data generated on-the-fly in standalone scripts

**Example Data:**
Location: `printer_server.py:1004-1090`

`generate_test_image()` creates a professional test receipt as PIL Image:

```python
def generate_test_image(server_ip, server_port, printer_name, printer_ip, printer_mac):
    img = Image.new("RGB", (576, 900), "white")
    # Draws: title, server info, printer info, timestamp
    # Uses system fonts (Arial, Calibri, DejaVu)
```

## Current Test Gaps

**Critical Gaps:**
- No unit tests for image processing pipeline (`_prepare_image_for_thermal()`)
- No tests for MAC address parsing (HTTP, SNMP, ARP resolution)
- No tests for printer registry persistence/loading
- No tests for concurrent job submission
- No tests for thread-safe access to connection pool
- No tests for escpos command generation (text, image, receipt, QR, barcode)

**Medium Priority:**
- No API contract tests (validate request/response schemas)
- No timeout/resilience tests
- No large image handling tests
- No malformed input tests (corrupted images, invalid JSON)

**Low Priority:**
- No performance benchmarks
- No stress tests (high-volume print requests)
- No cleanup/resource leak tests

## Recommended Test Strategy

**Phase 1 - Unit Tests:**
Create `tests/` directory with pytest:

```
tests/
├── test_printer_discovery.py      # MAC resolution strategies
├── test_image_preparation.py      # Pillow pipeline
├── test_print_queue.py            # Thread safety, retry logic
├── test_printer_server.py         # API validation, error handlers
└── conftest.py                    # Fixtures
```

**Phase 2 - Integration Tests:**
- Spoof printer on localhost:9100
- Test full request → queue → execution flow
- Test connection pool behavior

**Phase 3 - E2E Tests:**
- Test with real printers
- Test WSA bridge setup/teardown
- Test startup/shutdown sequences

---

*Testing analysis: 2026-03-17*
