from datetime import datetime

from settings.config import MIN_FEED_BEFORE_CUT
from services.connection import connect_printer, finish_job, evict_printer_connection, init_printer


def exec_text(printer_name, params):
    p = connect_printer(printer_name)
    try:
        init_printer(p)
        use_custom_size = params.get("width", 1) != 1 or params.get("height", 1) != 1
        p.set(
            align=params.get("align", "left"),
            bold=params.get("bold", False),
            underline=params.get("underline", 0),
            invert=params.get("invert", False),
            width=params.get("width", 1),
            height=params.get("height", 1),
            custom_size=use_custom_size,
        )
        text = params["text"]
        p.text(text)
        if not text.endswith("\n"):
            p.text("\n")
        p.set()
        feed_and_cut(p, params)
        finish_job(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def exec_receipt(printer_name, params):
    p = connect_printer(printer_name)
    try:
        init_printer(p)
        CHAR_WIDTH = 48

        p.set(align="center", bold=True, width=2, height=2, custom_size=True)
        p.text(f"{params.get('header', 'BARAKA')}\n")
        p.set()

        subheader = params.get("subheader")
        if subheader:
            p.set(align="center")
            p.text(f"{subheader}\n")
            p.set()

        p.text("-" * CHAR_WIDTH + "\n")

        items = params.get("items", [])
        if items:
            p.set(align="left")
            for item in items:
                name_part = f"{item['qty']}x {item['name']}"
                price_part = f"{item['price']:.2f}"
                padding = max(1, CHAR_WIDTH - len(name_part) - len(price_part))
                p.text(f"{name_part}{' ' * padding}{price_part}\n")
            p.set()

        p.text("-" * CHAR_WIDTH + "\n")

        def _total_line(label, value):
            val_str = f"{value:.2f}"
            pad = max(1, CHAR_WIDTH - len(label) - len(val_str))
            p.text(f"{label}{' ' * pad}{val_str}\n")

        if params.get("subtotal") is not None:
            _total_line("Subtotal:", params["subtotal"])
        if params.get("tax") is not None:
            _total_line("Tax:", params["tax"])
        if params.get("discount") is not None:
            _total_line("Discount:", -abs(params["discount"]))

        total = params.get("total")
        if total is not None:
            p.text("=" * CHAR_WIDTH + "\n")
            p.set(bold=True, width=2, height=1, custom_size=True)
            label = "TOTAL:"
            val_str = f"{total:.2f}"
            eff_width = CHAR_WIDTH // 2
            pad = max(1, eff_width - len(label) - len(val_str))
            p.text(f"{label}{' ' * pad}{val_str}\n")
            p.set()
            p.text("=" * CHAR_WIDTH + "\n")

        footer = params.get("footer")
        if footer:
            p.text("\n")
            p.set(align="center")
            p.text(f"{footer}\n")
            p.set()

        p.text("\n")
        p.set(align="center")
        p.text(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        p.set()

        feed_and_cut(p, params)
        finish_job(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def exec_qr(printer_name, params):
    p = connect_printer(printer_name)
    try:
        init_printer(p)
        center = params.get("center", True)
        if center:
            p.set(align="center")
        p.qr(params["text"], size=params.get("size", 3))
        if center:
            p.set(align="left")
        feed_and_cut(p, params)
        finish_job(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def exec_barcode(printer_name, params):
    p = connect_printer(printer_name)
    try:
        init_printer(p)
        center = params.get("center", True)
        if center:
            p.set(align="center")
        p.barcode(
            params["code"],
            params.get("barcode_type", "CODE39"),
            height=params.get("height", 64),
            width=params.get("width", 2),
            pos="BELOW",
            font="A",
        )
        if center:
            p.set(align="left")
        feed_and_cut(p, params)
        finish_job(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def exec_raw(printer_name, params):
    p = connect_printer(printer_name)
    try:
        p._raw(params["data"])
        finish_job(printer_name, p)
    except Exception:
        evict_printer_connection(printer_name)
        raise


def feed_and_cut(p, params):
    lines_after = params.get("lines_after", 0)
    cut = params.get("cut", True)
    feed_lines = lines_after if lines_after > 0 else MIN_FEED_BEFORE_CUT
    if cut:
        p.text("\n" * feed_lines)
        p.cut(feed=False)
    elif lines_after > 0:
        p.text("\n" * lines_after)


PRINT_HANDLERS = {
    "text": exec_text,
    "receipt": exec_receipt,
    "qr": exec_qr,
    "barcode": exec_barcode,
    "raw": exec_raw,
}
