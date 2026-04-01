import json
import logging
import os
import threading
from datetime import datetime

from settings.config import REGISTRY_FILE

PRINTERS = {}
_printers_lock = threading.Lock()


def _registry_path():
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), REGISTRY_FILE)


def load_registry():
    global PRINTERS
    reg_path = _registry_path()
    if not os.path.exists(reg_path):
        return
    try:
        with open(reg_path, "r") as f:
            data = json.load(f)
        with _printers_lock:
            for name, info in data.items():
                host = info.get("last_ip", info.get("host", ""))
                if isinstance(host, str) and host.startswith("usb:"):
                    logging.warning(f"Skipping legacy USB entry: {host}")
                    continue
                PRINTERS[name] = {
                    "host": host,
                    "port": info.get("port", 9100),
                    "mac": info.get("mac", "unknown"),
                    "connection_type": info.get("connection_type", "network"),
                    "baudrate": info.get("baudrate", 9600),
                }
        logging.info(f"Loaded {len(PRINTERS)} printer(s) from registry")
    except Exception as e:
        logging.warning(f"Could not load registry: {e}")


def save_registry():
    reg_path = _registry_path()
    with _printers_lock:
        data = {}
        for name, config in PRINTERS.items():
            data[name] = {
                "name": name,
                "connection_type": config.get("connection_type", "network"),
                "last_ip": config["host"],
                "port": config["port"],
                "mac": config.get("mac", "unknown"),
                "baudrate": config.get("baudrate", 9600),
                "last_seen": datetime.now().isoformat(),
            }
    try:
        # Write to temp file then rename for atomicity
        tmp_path = reg_path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp_path, reg_path)
    except Exception as e:
        logging.warning(f"Could not save registry: {e}")
