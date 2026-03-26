import logging
import threading
import traceback
from datetime import datetime, timezone
from urllib.request import urlopen, Request as UrlRequest
import json

from fastapi import HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from settings.config import DISCORD_WEBHOOK_URL

logger = logging.getLogger(__name__)


class AppError(HTTPException):
    """Expected error raised by our code for wrong usage (bad input, printer not found, etc.)."""

    def __init__(self, status_code: int = 400, detail: str = "Bad request"):
        super().__init__(status_code=status_code, detail=detail)


def register_error_handlers(app):
    """Register all exception handlers on the FastAPI app."""

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

    @app.exception_handler(Exception)
    async def unexpected_error_handler(request: Request, exc: Exception):
        # Don't re-handle known types
        if isinstance(exc, (HTTPException, RequestValidationError)):
            raise exc

        tb = traceback.format_exc()
        error_id = datetime.now().strftime("%Y%m%d%H%M%S")
        logger.error(f"[{error_id}] Unexpected error: {type(exc).__name__}: {exc}\n{tb}")

        threading.Thread(target=_send_to_discord, args=(request, exc, error_id, tb), daemon=True).start()

        return JSONResponse(
            status_code=500,
            content={
                "success": False,
                "error": "Internal server error",
                "error_id": error_id,
            },
        )


def _send_to_discord(request: Request, exc: Exception, error_id: str, tb: str):
    """Send unexpected error details to Discord webhook (non-blocking best-effort)."""
    if not DISCORD_WEBHOOK_URL:
        return

    try:
        # Truncate traceback for Discord's 2000 char limit
        tb_short = tb[-1500:] if len(tb) > 1500 else tb

        payload = {
            "embeds": [{
                "title": f"Server Error [{error_id}]",
                "color": 16711680,  # red
                "fields": [
                    {"name": "Endpoint", "value": f"`{request.method} {request.url.path}`", "inline": True},
                    {"name": "Error", "value": f"`{type(exc).__name__}: {str(exc)[:200]}`", "inline": True},
                    {"name": "Traceback", "value": f"```\n{tb_short}\n```", "inline": False},
                ],
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }]
        }

        data = json.dumps(payload).encode("utf-8")
        req = UrlRequest(DISCORD_WEBHOOK_URL, data=data, headers={"Content-Type": "application/json"})
        urlopen(req, timeout=5)
    except Exception as e:
        logger.warning(f"Failed to send error to Discord: {e}")
