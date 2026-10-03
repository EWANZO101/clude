import base64
import io

import barcode
from barcode.writer import SVGWriter

# The Part 2 barcode-view templates promised "scannable barcode rendering
# (Code128) ships with the printable-sheet feature in a later part" —
# this is that later part. Uses the real python-barcode library rather
# than hand-rolling Code128's symbol/checksum table: a transcription
# error in a hand-rolled encoder produces a barcode that *looks* right
# but silently fails to scan, and there's no decoder available in this
# environment to catch that kind of mistake before it ships. A tested
# library removes that risk entirely.


def code128_data_uri(code: str) -> str:
    """Renders `code` as a Code128 barcode and returns it as a data: URI
    SVG image, ready to drop straight into an <img src="...">. Always
    black-on-white regardless of the kiosk's dark theme — that's what
    actually makes a printed label scannable, not a style choice.
    Returns None on any encoding failure (e.g. a character outside
    Code128B's set) rather than raising, so a barcode view page degrades
    to text-only instead of crashing — every barcode this app currently
    generates itself (ITEM/TOOL/PROJ/WIRE/BADGE + hex) is safely within
    Code128B's charset, so this is a defensive fallback, not an expected
    path."""
    try:
        bc = barcode.get("code128", code, writer=SVGWriter())
        buf = io.BytesIO()
        bc.write(buf, options={"write_text": False, "quiet_zone": 2, "module_height": 12})
        encoded = base64.b64encode(buf.getvalue()).decode("ascii")
        return f"data:image/svg+xml;base64,{encoded}"
    except Exception:
        return None


def qr_data_uri(code: str) -> str:
    """Renders `code` as a QR code and returns it as a data: URI SVG image
    — printed alongside the Code128 barcode above, not instead of it. A
    phone camera (any phone camera, including its default camera app with
    no scanning app installed at all) reads a QR code far more reliably
    than a small 1D barcode at a normal handheld distance or angle, so
    shipping both on the same label means whichever a given device or
    scanner handles best still resolves to the exact same code. Imported
    lazily, unlike `barcode` above (already load-bearing since Part 2):
    this is a new dependency, and a machine where it failed to install
    must not take barcode rendering — or the app itself — down over it.
    See kiosk_app/app/blueprints/items.py::export_item_pdf's own lazy
    import for the real incident (2026-09-11) this exact pattern already
    fixed once."""
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
