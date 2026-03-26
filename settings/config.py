import os

UPLOAD_FOLDER = os.getenv("UPLOAD_FOLDER", "uploads")
ALLOWED_EXTENSIONS = {"png", "jpg", "jpeg", "bmp", "gif"}
MAX_CONTENT_LENGTH = int(os.getenv("MAX_UPLOAD_SIZE_MB", "20")) * 1024 * 1024
SERVER_HOST = os.getenv("SERVER_HOST", "0.0.0.0")
SERVER_PORT = int(os.getenv("SERVER_PORT", "3006"))
REGISTRY_FILE = os.getenv("PRINTER_REGISTRY", "registry.json")
MIN_FEED_BEFORE_CUT = int(os.getenv("MIN_FEED_BEFORE_CUT", "4"))
QUEUE_MAX_RETRIES = int(os.getenv("QUEUE_MAX_RETRIES", "3"))
QUEUE_RETRY_BASE_DELAY = float(os.getenv("QUEUE_RETRY_BASE_DELAY", "1.0"))
QUEUE_JOB_HISTORY_SIZE = int(os.getenv("QUEUE_JOB_HISTORY_SIZE", "100"))
DISCORD_WEBHOOK_URL = os.getenv("DISCORD_WEBHOOK_URL", "")
