import base64
import io

# Both `barcode` and `qrcode` are imported lazily (function-local), not at
# module level — unlike kiosk_app's version of this file, where `barcode` is
# a load-bearing top-level import. Here the whole label feature is an
# optional, admin-toggleable setting (Settings.barcode_enabled), so a machine
# that never turns it on — or where these two packages simply aren't
# installed — must still be able to import this module and run the rest of
# the app. See kiosk_app/app/barcode_render.py's own docstring for the real
# 2026-09-11 incident (a module-level import of a new dependency took the
# whole kiosk down) this pattern exists to avoid repeating.


def code128_data_uri(code: str) -> str:
    """Renders `code` as a Code128 barcode and returns it as a data: URI SVG
    image, ready to drop straight into an <img src="...">. Returns None on
    any failure (missing dependency, or a character outside Code128B's
    charset) rather than raising, so a label view degrades to text-only
    instead of taking the page down with it."""
    try:
        import barcode
        from barcode.writer import SVGWriter
    except ImportError:
        return None
    try:
        bc = barcode.get("code128", code, writer=SVGWriter())
        buf = io.BytesIO()
        bc.write(buf, options={"write_text": False, "quiet_zone": 2, "module_height": 12})
        encoded = base64.b64encode(buf.getvalue()).decode("ascii")
        return f"data:image/svg+xml;base64,{encoded}"
    except Exception:
        return None


def qr_data_uri(code: str) -> str:
    """Renders `code` as a QR code and returns it as a data: URI SVG image —
    printed alongside the Code128 barcode above, not instead of it. Same
    lazy-import/never-raise convention as code128_data_uri above."""
    try:
        import qrcode
        import qrcode.image.svg
    except ImportError:
        return None
    try:
        img = qrcode.make(code, image_factory=qrcode.image.svg.SvgPathImage, box_size=6, border=2)
        buf = io.BytesIO()
        img.save(buf)
        encoded = base64.b64encode(buf.getvalue()).decode("ascii")
        return f"data:image/svg+xml;base64,{encoded}"
    except Exception:
        return None
