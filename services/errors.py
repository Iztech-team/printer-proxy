import json
import logging
import subprocess
import threading
import traceback
from datetime import datetime, timezone

from fastapi import HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from settings.config import DISCORD_WEBHOOK_URL

logger = logging.getLogger(__name__)


class AppError(HTTPException):
    """Expected error raised by our code for wrong usage (bad input, printer not found, etc.)."""

    def __init__(self, status_code: int = 400, detail: str = "Bad request"):
        super().__init__(status_code=status_code, detail=detail)


class ErrorHandlingMiddleware(BaseHTTPMiddleware):
    """
    Global try/catch for the entire system.
    Catches unexpected errors, returns clean JSON, and sends to Discord.
    """

    async def dispatch(self, request: Request, call_next):
        try:
            response = await call_next(request)
            return response
        except Exception as exc:
            # Let known types pass through to FastAPI's exception handlers
            if isinstance(exc, (HTTPException, RequestValidationError)):
                raise

            tb = traceback.format_exc()
            error_id = datetime.now().strftime("%Y%m%d%H%M%S")
            logger.error(f"[{error_id}] Unexpected error: {type(exc).__name__}: {exc}\n{tb}")

            method = request.method
            path = request.url.path
            error_type = type(exc).__name__
            error_msg = str(exc)[:200]
            threading.Thread(
                target=_send_to_discord,
                args=(method, path, error_type, error_msg, error_id, tb),
                daemon=True,
            ).start()

            return JSONResponse(
                status_code=500,
                content={"success": False, "error": "Internal server error", "error_id": error_id},
            )


def register_error_handlers(app):
    """Register exception handlers + error middleware on the FastAPI app."""

    # Middleware catches unexpected errors at ASGI level
    app.add_middleware(ErrorHandlingMiddleware)

    @app.exception_handler(AppError)
    async def app_error_handler(request: Request, exc: AppError):
        return JSONResponse(
            status_code=exc.status_code,
            content={"success": False, "error": exc.detail},
        )

    @app.exception_handler(HTTPException)
    async def http_exception_handler(request: Request, exc: HTTPException):
        return JSONResponse(
            status_code=exc.status_code,
            content={"success": False, "error": exc.detail},
        )

    @app.exception_handler(RequestValidationError)
    async def validation_handler(request: Request, exc: RequestValidationError):
        errors = []
        for err in exc.errors():
            clean = {k: v for k, v in err.items() if k != "ctx"}
            clean["msg"] = str(err.get("msg", ""))
            errors.append(clean)
        return JSONResponse(
            status_code=422,
            content={"success": False, "error": "Validation error", "detail": errors},
        )


def _send_to_discord(method: str, path: str, error_type: str, error_msg: str, error_id: str, tb: str):
    """Send unexpected error details to Discord webhook (runs in background thread)."""
    if not DISCORD_WEBHOOK_URL:
        return

    try:
        # Extract just the last few relevant lines from traceback
        tb_lines = tb.strip().splitlines()
        # Get the last 10 lines max (the most relevant part)
        tb_short = "\n".join(tb_lines[-10:]) if len(tb_lines) > 10 else tb.strip()
        # Truncate to stay under Discord's 1024 char field limit
        if len(tb_short) > 900:
            tb_short = tb_short[-900:]

        payload = {
            "embeds": [{
                "title": f"Server Error [{error_id}]",
                "color": 16711680,
                "description": f"**{error_type}**: {error_msg}",
                "fields": [
                    {"name": "Endpoint", "value": f"{method} {path}", "inline": True},
                    {"name": "Timestamp", "value": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"), "inline": True},
                    {"name": "Traceback", "value": tb_short, "inline": False},
                ],
            }]
        }

        data = json.dumps(payload)
        result = subprocess.run(
            ["curl", "-s", "-X", "POST", DISCORD_WEBHOOK_URL,
             "-H", "Content-Type: application/json",
             "-d", data],
            timeout=10,
            capture_output=True,
        )
        if result.returncode != 0:
            logger.warning(f"Discord curl failed: {result.stderr.decode()}")
    except Exception as e:
        logger.warning(f"Failed to send error to Discord: {e}")
