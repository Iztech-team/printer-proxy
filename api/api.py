import base64
import binascii
import os
import uuid

from fastapi import FastAPI, HTTPException, Query, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse, HTMLResponse
from werkzeug.utils import secure_filename

from settings.config import UPLOAD_FOLDER, MAX_CONTENT_LENGTH, ALLOWED_EXTENSIONS
from settings.registry import PRINTERS
from api.models import PrintRequest
from services.connection import validate_printer
from services.printer import PRINT_HANDLERS
from services.actions import action_beep, action_cut, action_open_cash, action_print_image
from services.image import allowed_file, prepare_image_for_thermal
from services.discovery_service import discovery_event_stream, register_usb_printers_windows
from services.errors import register_error_handlers
from services.connection import connect_printer, close_if_job_based, evict_printer_connection
from settings.config import QUEUE_MAX_RETRIES, QUEUE_RETRY_BASE_DELAY, QUEUE_JOB_HISTORY_SIZE
from print_queue import PrintQueue

print_queue = PrintQueue(
    max_retries=QUEUE_MAX_RETRIES,
    retry_base_delay=QUEUE_RETRY_BASE_DELAY,
    history_size=QUEUE_JOB_HISTORY_SIZE,
)

app = FastAPI(title="Baraka Printer Server", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs(UPLOAD_FOLDER, exist_ok=True)

register_error_handlers(app)


# ─── Endpoints ───────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
def serve_test_panel():
    html_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "test.html")
    with open(html_path, "r") as f:
        return f.read()


@app.get("/api/health")
def health():
    return {"ok": True, "status": "running", "version": "2.0.0", "printers": len(PRINTERS)}


@app.get("/api/test-error")
def test_error():
    """Triggers a fake unexpected error to test Discord webhook."""
    raise RuntimeError("Test error — verifying Discord webhook integration")


@app.post("/api/printers/register-usb")
def register_usb():
    return register_usb_printers_windows()


@app.get("/api/printers/{name}/check")
def check_printer(name: str):
    """Check if a specific printer is reachable. Works with printer name or IP."""
    from discovery import PrinterDiscovery

    # Check if it's an IP address (user passed IP directly)
    is_ip = all(part.isdigit() for part in name.split(".")) and len(name.split(".")) == 4

    if is_ip:
        # Direct IP check — test TCP connection on port 9100
        discovery = PrinterDiscovery()
        reachable = discovery.check_printer(name)
        return {"success": True, "printer": name, "reachable": reachable, "type": "network"}

    # It's a printer name — look it up in registry
    validate_printer(name)
    config = PRINTERS[name]
    conn_type = config.get("connection_type", "network")

    if conn_type == "network":
        discovery = PrinterDiscovery()
        reachable = discovery.check_printer(config["host"], config["port"])
        return {"success": True, "printer": name, "host": config["host"], "reachable": reachable, "type": "network"}

    # For USB/serial/file printers — try to connect
    try:
        p = connect_printer(name)
        close_if_job_based(name, p)
        return {"success": True, "printer": name, "device": config["host"], "reachable": True, "type": conn_type}
    except Exception as e:
        return {"success": True, "printer": name, "device": config["host"], "reachable": False, "type": conn_type, "error": str(e)}


@app.get("/api/printers")
def get_printers():
    return StreamingResponse(discovery_event_stream(), media_type="text/event-stream")


@app.post("/api/printers/{name}/print")
async def api_print(name: str, req: PrintRequest):
    validate_printer(name)

    print_type = req.type
    if print_type not in PRINT_HANDLERS:
        raise HTTPException(status_code=400, detail=f"Unknown print type: {print_type}. Available: {list(PRINT_HANDLERS.keys())}")

    params = req.model_dump()
    params.pop("printer", None)
    params.pop("type")

    if print_type == "raw":
        if not req.base64 and not req.hex:
            raise HTTPException(status_code=400, detail="Provide 'base64' or 'hex' field")
        params["data"] = base64.b64decode(req.base64) if req.base64 else binascii.unhexlify(req.hex.strip())

    if print_type == "text" and not req.text:
        raise HTTPException(status_code=400, detail="'text' field is required for text type")
    if print_type == "qr" and not req.text:
        raise HTTPException(status_code=400, detail="'text' field is required for qr type")
    if print_type == "barcode" and not req.code:
        raise HTTPException(status_code=400, detail="'code' field is required for barcode type")
    if print_type == "receipt":
        params["items"] = [item.model_dump() for item in req.items]

    handler = PRINT_HANDLERS[print_type]
    _params = params.copy()
    _name = name

    def execute():
        handler(_name, _params)

    job_id = print_queue.submit(name, print_type, execute, {k: v for k, v in params.items() if k not in ("data", "execute_fn")})
    return JSONResponse(status_code=202, content={"success": True, "job_id": job_id, "queued": True, "message": f"{print_type} print job queued for {name}", "printer": name})


@app.post("/api/printers/{name}/actions/beep")
async def beep(name: str, count: int = Query(1), duration: int = Query(1)):
    validate_printer(name)
    params = {"count": count, "duration": duration}

    def execute():
        action_beep(name, params)

    job_id = print_queue.submit(name, "beep", execute, params)
    return JSONResponse(status_code=202, content={"success": True, "job_id": job_id, "queued": True, "message": f"Beep queued for {name}", "printer": name})


@app.post("/api/printers/{name}/actions/cut")
async def cut(name: str, lines_before: int = Query(0), mode: str = Query("partial")):
    validate_printer(name)
    params = {"lines_before": lines_before, "mode": mode}

    def execute():
        action_cut(name, params)

    job_id = print_queue.submit(name, "cut", execute, params)
    return JSONResponse(status_code=202, content={"success": True, "job_id": job_id, "queued": True, "message": f"Cut queued for {name}", "printer": name})


@app.post("/api/printers/{name}/actions/openCash")
async def open_cash(name: str, pin: int = Query(0), t1: int = Query(100), t2: int = Query(100)):
    validate_printer(name)
    params = {"pin": pin, "t1": t1, "t2": t2}

    def execute():
        action_open_cash(name, params)

    job_id = print_queue.submit(name, "openCash", execute, params)
    return JSONResponse(status_code=202, content={"success": True, "job_id": job_id, "queued": True, "message": f"Cash drawer queued for {name}", "printer": name})


@app.post("/api/printers/{name}/actions/printImage")
async def print_image(name: str, image: UploadFile, center: bool = Query(True), paper_width: int = Query(510), cut: bool = Query(True), lines_after: int = Query(0)):
    validate_printer(name)

    if not image.filename:
        raise HTTPException(status_code=400, detail="No image provided")
    if not allowed_file(image.filename):
        raise HTTPException(status_code=400, detail=f"Invalid image type. Allowed: {ALLOWED_EXTENSIONS}")

    filename = secure_filename(image.filename)
    unique_filename = f"{uuid.uuid4()}_{filename}"
    filepath = os.path.join(UPLOAD_FOLDER, unique_filename)

    content = await image.read()
    if len(content) > MAX_CONTENT_LENGTH:
        raise HTTPException(status_code=413, detail="File too large")

    with open(filepath, "wb") as f:
        f.write(content)

    optimized_path = prepare_image_for_thermal(filepath, paper_width)
    _name, _fp, _center, _cut, _la = name, optimized_path, center, cut, lines_after

    def execute():
        action_print_image(_name, _fp, _center, _cut, _la)

    job_id = print_queue.submit(name, "image", execute, {"filename": filename, "center": center, "cut": cut})
    return JSONResponse(status_code=202, content={"success": True, "job_id": job_id, "queued": True, "message": f"Image print job queued for {name}", "printer": name, "filename": filename})


# ─── Job Queue ───────────────────────────────────────────────

@app.get("/api/printers/{name}/jobs")
def list_jobs(name: str):
    validate_printer(name)
    jobs = print_queue.get_queue(printer_name=name)
    return {"success": True, "jobs": jobs, "count": len(jobs)}


@app.get("/api/printers/{name}/jobs/{job_id}")
def get_job(name: str, job_id: str):
    validate_printer(name)
    job = print_queue.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")
    if job.get("printer") != name:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found on {name}")
    return {"success": True, "job": job}


@app.delete("/api/printers/{name}/jobs/{job_id}")
def cancel_job(name: str, job_id: str):
    validate_printer(name)
    job = print_queue.get_job(job_id)
    if job is None or job.get("printer") != name:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found on {name}")
    cancelled = print_queue.cancel_job(job_id)
    if not cancelled:
        raise HTTPException(status_code=400, detail=f"Job {job_id} cannot be cancelled (not pending)")
    return {"success": True, "message": f"Job {job_id} cancelled"}


@app.get("/api/queue/status")
def queue_status():
    return {"success": True, **print_queue.get_status()}
