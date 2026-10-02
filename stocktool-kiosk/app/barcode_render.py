"""
Renders a real, scannable Code128 barcode as SVG for a given code
string. Server-side generation (not a client-side JS library loaded
from a CDN) on purpose -- this kiosk is designed to run fully offline
(see main.py's docstring, backup_loop.py's "dormant until configured"
pattern, etc.), so pulling in a JS barcode library from a CDN at
runtime would silently break in the same offline scenario the rest of
this project is careful to support. python-barcode is a small, pure-
Python dependency that gets bundled directly into the frozen exe by
PyInstaller, same as everything else.

Code128 (not QR) because these codes are meant to be read by ordinary
handheld/fixed barcode scanners already common in warehouses and stock
rooms, not necessarily a smartphone camera -- Code128 is the standard
choice for that, and comfortably encodes the alphanumeric codes this
project already generates (see app/codes.py).
"""
import io

from barcode import Code128
from barcode.writer import SVGWriter


def generate_barcode_svg(code: str) -> str:
    """Returns raw SVG markup (a string) for the given code. Raises
    barcode.errors.BarcodeError (via the underlying library) if `code`
    contains characters Code128 can't encode -- in practice this never
    happens for codes this project generates itself (see app/codes.py's
    alphabet), but could happen for a hand-typed SKU used as a barcode
    value; callers should let that propagate to a normal error response
    rather than silently returning a blank image.

    Sizing was chosen empirically (generated, then actually measured the
    resulting SVG's width/height attributes) rather than guessed --
    these settings produce roughly a 2.45in x 1.36in barcode for an
    8-character code, comfortably above the ~1in minimum most handheld
    scanners need for a reliable read, especially on a budget printer
    where thin bars can blur together."""
    writer = SVGWriter()
    barcode_obj = Code128(code, writer=writer)
    buf = io.BytesIO()
    barcode_obj.write(buf, options={
        "write_text": True,     # print the code as text under the bars, not just the bars alone
        "module_width": 0.4,    # bar width (mm) -- thicker bars are more forgiving for scanners and printers
        "module_height": 25,    # bar height (mm) -- taller bars scan more reliably than the library's tiny default
        "quiet_zone": 6.5,      # margin (mm) on each side -- scanners need this to find the edges
        "font_size": 14,        # human-readable text under the bars, sized to still be legible when printed
        "text_distance": 6,     # gap (mm) between bars and the text, so they don't run together
    })
    return buf.getvalue().decode("utf-8")
