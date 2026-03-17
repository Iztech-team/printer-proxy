# External Integrations

**Analysis Date:** 2026-03-17

## APIs & External Services

**None currently integrated** - This is a self-contained local-network printer server with no external SaaS dependencies.

**Potential integration points:**
- Print job webhook callbacks (not currently implemented)
- Remote monitoring/logging services
- Cloud-based receipt storage

## Data Storage

**Databases:**
- None - Printer registry stored as local JSON file only
  - File: `printer_registry.json`
  - Format: JSON key-value store with printer metadata
  - Persistence: Manual `load_registry()` / `save_registry()` calls
  - Replaces CUPS spool database

**File Storage:**
- Local filesystem only (`uploads/` directory)
  - Temporary image files for print preprocessing
  - Test receipt images during startup
  - Automatic cleanup after printing

**Caching:**
- In-memory connection pooling via `_printer_connections` dict
  - Thread-safe via `_pool_lock`
  - Reuses TCP connections to printers to avoid reconnection overhead
  - Eviction on connection failure

**Offline-first:**
- Completely offline capable
- No cloud synchronization
- No dependency on external services

## Authentication & Identity

**Auth Provider:**
- Custom: None implemented
- All endpoints accessible without authentication (LAN-only assumption)
- CORS enabled for all origins (`allow_origins=["*"]`)

**Security Model:**
- Network isolation: Accessible only on LAN
- No API keys or bearer tokens
- No user management
- File upload restrictions: whitelist extensions (PNG, JPG, JPEG, BMP, GIF)

## Monitoring & Observability

**Error Tracking:**
- None (no external service)
- Local exception handlers in `printer_server.py` lines 157-186
- Error details returned in JSON responses

**Logs:**
- Console output (or file when run via pythonw.exe - hidden mode)
- Log file: `server.log` (auto-created in server directory)
- Standard Python logging module with StreamHandler + FileHandler
- Format: `%(asctime)s [%(levelname)s] %(message)s`
- Level: Configurable via LOG_LEVEL env var (default: INFO)

**Audit Trail:**
- Job history maintained in memory (deque with maxlen=100 by default)
- Job history: `PrintQueue._history` in `print_queue.py`
- Each job tracked with: id, status, timestamps, error messages, retry count

## CI/CD & Deployment

**Hosting:**
- Windows 10/11 local machine
- No cloud hosting
- Single-machine deployment via PowerShell setup script

**CI Pipeline:**
- None automated
- Manual setup via `windows_setup.ps1`
- Automated features in setup:
  - Python 3.12 installation
  - Dependency installation via pip
  - Network printer discovery scan
  - Windows Scheduled Task for auto-start
  - Firewall rule configuration
  - WSA bridge auto-configuration

**Package Distribution:**
- GitHub repository: Iztech-team/windows-py-server
- Setup script downloads latest files from raw GitHub URLs
- No Docker, no containers

## Environment Configuration

**Required env vars:**
- SERVER_HOST (default: 0.0.0.0)
- SERVER_PORT (default: 3006)
- SCAN_ON_STARTUP (default: true)
- TEST_PRINT_ON_STARTUP (default: true)
- WSA_BRIDGE_ENABLED (default: true)
- WSA_ADB_PORT (default: 58526)
- LOG_LEVEL (default: INFO)
- QUEUE_MAX_RETRIES (default: 3)
- QUEUE_RETRY_BASE_DELAY (default: 1.0)
- QUEUE_JOB_HISTORY_SIZE (default: 100)
- UPLOAD_FOLDER (default: uploads)
- MAX_UPLOAD_SIZE_MB (default: 20)
- PRINTER_REGISTRY (default: printer_registry.json)
- MIN_FEED_BEFORE_CUT (default: 4)

**Secrets location:**
- None - No API keys, passwords, or secrets required
- .env file stores configuration only (no sensitive data)

## Network Communication

**Inbound:**
- HTTP (REST API) on `SERVER_PORT` (default 3006)
- CORS enabled for all origins
- No authentication required

**Outbound:**
- TCP port 9100 to network printers (ESC/POS binary protocol)
- TCP port 80 to printers (HTTP web interface for MAC address discovery)
- UDP port 161 to printers (SNMP MAC address lookup)
- TCP port 58526 to WSA ADB daemon (Android bridge - optional)

**Network Discovery:**
- Active network scan on `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x` subnets
- TCP connection probing on port 9100 (parallel scan, 50 workers max)
- ICMP ping for ARP cache population (via `ipconfig`/`ip` commands)

## Webhooks & Callbacks

**Incoming:**
- None implemented

**Outgoing:**
- None implemented

**Print Job Status:**
- Status queryable via `/jobs/{job_id}` endpoint
- No push notifications or webhooks to external systems

## Android Integration (WSA)

**Windows Subsystem for Android (WSA):**
- Optional integration via `wsa_bridge.py`
- Uses ADB (Android Debug Bridge) for port forwarding
- Sets up: `adb reverse tcp:3006 tcp:3006`
- Allows WSA-hosted Android app to reach printer server at `localhost:3006`
- Auto-reconnect monitor: checks tunnel every 30 seconds

**ADB Requirements:**
- Android Platform Tools (separate download)
- ADB executable in PATH or known installation directories:
  - `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`
  - `%USERPROFILE%\AppData\Local\Android\Sdk\platform-tools\adb.exe`
  - `C:\platform-tools\adb.exe`
  - `C:\Android\platform-tools\adb.exe`

**WSA Developer Mode:**
- Must be enabled in WSA Settings for ADB connectivity
- Setup script attempts auto-configuration

## Third-Party Tools Used

**Not integrated, but required for operation:**
- ADB (Android Debug Bridge) - WSA connectivity only
- ipconfig/ip command - Subnet detection for printer discovery
- ping command - ARP cache population
- arp command - MAC address resolution (Windows: `arp -a`, Linux: `arp -n`)
- SNMP (raw UDP) - Fallback MAC resolution (no pysnmp dependency)

---

*Integration audit: 2026-03-17*
