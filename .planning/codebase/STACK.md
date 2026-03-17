# Technology Stack

**Analysis Date:** 2026-03-17

## Languages

**Primary:**
- Python 3.12+ - All server logic, printer discovery, queue management, WSA bridge
- PowerShell - Windows setup automation script

**Secondary:**
- ESC/POS (binary protocol) - Direct thermal printer communication

## Runtime

**Environment:**
- Python 3.12+ (Windows native)
- Windows 10/11 (host OS)
- Windows Subsystem for Android (WSA) - Optional Android app container

**Package Manager:**
- pip (Python package manager)
- Lockfile: `requirements.txt` - Version constraints specified

## Frameworks

**Core:**
- FastAPI 0.100.0+ - REST API framework for print server
- Uvicorn 0.23.0+ - ASGI web server for FastAPI

**Image Processing:**
- Pillow 10.0.0+ to <13.0.0 - Image optimization, thermal print preparation, test receipt generation

**Printer Control:**
- python-escpos 3.0+ to <4.0.0 - ESC/POS thermal printer communication via Network class

**Utilities:**
- python-dotenv 1.0.0+ - Environment variable management (.env files)
- werkzeug 3.0+ - Secure filename handling for file uploads
- python-multipart 0.0.6+ - Multipart form data parsing for image uploads

## Key Dependencies

**Critical:**
- python-escpos - Provides Network class for TCP connection to port 9100 printers. Essential for all printing operations
- FastAPI - REST API framework handling HTTP endpoints and request validation
- Pillow - Image dithering and preprocessing for thermal output quality

**Infrastructure:**
- No external databases required
- No external APIs required (standalone network printer control)
- Platform-specific tools: ADB (Android Debug Bridge), WSA (Windows Subsystem for Android)

## Configuration

**Environment:**
- Configuration via `.env` file (copy from template)
- Key settings include:
  - SERVER_HOST=0.0.0.0
  - SERVER_PORT=3006
  - SCAN_ON_STARTUP=true
  - TEST_PRINT_ON_STARTUP=true
  - WSA_BRIDGE_ENABLED=true
  - WSA_ADB_PORT=58526
  - LOG_LEVEL=INFO
  - Queue settings (QUEUE_MAX_RETRIES, QUEUE_RETRY_BASE_DELAY, QUEUE_JOB_HISTORY_SIZE)
  - Printer registry location: printer_registry.json

**Build:**
- No build step required
- Direct Python execution: `python printer_server.py`
- PowerShell setup script handles all provisioning

## Platform Requirements

**Development:**
- Windows 10/11 with Administrator access (for setup, WSA, firewall rules)
- Python 3.12+ installed and in PATH
- ADB (Android Platform Tools) - for WSA bridge connectivity
- WSA installed (optional, for Android app support)

**Production:**
- Deployment target: Windows 10/11 local server
- Network access to thermal printers on port 9100 (ESC/POS)
- LAN connectivity only (no public internet access)
- Hyper-V for WSA (built into Windows Pro/Enterprise)

---

*Stack analysis: 2026-03-17*
