import os

from settings.config import MIN_FEED_BEFORE_CUT
from services.connection import printer_session, connect_printer, finish_job
from services.printer import feed_and_cut


def action_beep(printer_name, params):
    with printer_session(printer_name) as p:
        c = max(1, min(9, params.get("count", 1)))
        d = max(1, min(9, params.get("duration", 1)))
        try:
            p.buzzer(times=c, duration=d)
        except Exception:
            p._raw(b"\x1b\x42" + bytes([c]) + bytes([d]))


def action_cut(printer_name, params):
    with printer_session(printer_name) as p:
        cut_mode = "PART" if params.get("mode", "partial").lower() in ("partial", "part") else "FULL"
        feed_lines = params.get("lines_before", 0)
        if feed_lines <= 0:
            feed_lines = MIN_FEED_BEFORE_CUT
        p.text("\n" * feed_lines)
        p.cut(mode=cut_mode, feed=False)


def action_open_cash(printer_name, params):
    with printer_session(printer_name) as p:
        pin_val = 0 if params.get("pin", 0) == 0 else 1
        t1_val = max(0, min(255, params.get("t1", 100)))
        t2_val = max(0, min(255, params.get("t2", 100)))
        p._raw(b"\x1b\x70" + bytes([pin_val, t1_val, t2_val]))


def action_print_image(printer_name, filepath, center, cut, lines_after):
    try:
        with printer_session(printer_name) as p:
            if center:
                p.set(align="center")
            p.image(filepath)
            if center:
                p.set(align="left")
            feed_and_cut(p, {"cut": cut, "lines_after": lines_after})
    finally:
        if os.path.exists(filepath):
            try:
                os.remove(filepath)
            except Exception:
                pass
