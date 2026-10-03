"""Public, no-login mini scanner app — a phone camera or a physical USB/
Bluetooth barcode scanner (which just "types" the scanned code + Enter,
same as a keyboard, so the page needs no special hardware support beyond
a focused text input) can look up an item/tool on one specific instance
by its barcode_code. Gated entirely by a ScanToken (see models.py) — no
Flask-Login session involved at all, since the whole point is "hand
someone a link or a QR code, they scan, they're done", no account needed.

Deliberately read-only: this can never create, edit, or delete anything —
just looks up an already-synced InstanceEquipmentItem by barcode.
"""
import io
from datetime import datetime

from flask import Blueprint, render_template, jsonify, abort, request, url_for, Response

from app.extensions import db
from app.models import ScanToken, InstanceEquipmentItem

bp = Blueprint("scan_portal", __name__, url_prefix="/scan")


def _get_token_or_404(token):
    t = ScanToken.query.filter_by(token=token).first()
    if t is None or not t.is_valid():
        # 404, not 403 — a revoked/unknown token should look exactly like
        # a URL that was never valid, never confirm "this token existed".
        abort(404)
    return t


@bp.route("/<token>")
def scan_app(token):
    t = _get_token_or_404(token)
    return render_template("scan_portal/scan.html", scan_token=t, instance=t.instance)


@bp.route("/<token>/manifest.webmanifest")
def manifest(token):
    """Web app manifest, scoped to this one token's URL — lets Android
    Chrome/Edge treat this as a real installable app (fires
    beforeinstallprompt, opens full-screen with no browser chrome) rather
    than just a bookmark. iOS Safari ignores this file entirely and relies
    on the apple-mobile-web-app-* meta tags in scan.html instead — there's
    no iOS equivalent of this manifest."""
    t = _get_token_or_404(token)
    scoped_url = url_for("scan_portal.scan_app", token=token)
    return jsonify({
        "name": f"OpsLab Scan — {t.instance.display_name()}",
        "short_name": "OpsLab Scan",
        "start_url": scoped_url,
        "scope": scoped_url,
        "display": "standalone",
        "background_color": "#0a0d17",
        "theme_color": "#0a0d17",
        "icons": [
            {"src": url_for("scan_portal.icon"), "sizes": "512x512", "type": "image/png", "purpose": "any maskable"},
        ],
    })


@bp.route("/icon-512.png")
def icon():
    """Home-screen icon — generated on the fly rather than shipped as a
    static asset, so there's nothing to remember to keep in sync with the
    brand mark elsewhere (base.html's ".mark" — accent-to-#4d3fc4 gradient,
    a viewfinder-bracket motif here instead of the "O" since a barcode
    scanner icon reads better tiny than a single letter does)."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        abort(503)

    size = 512
    img = Image.new("RGB", (size, size), "#0a0d17")
    draw = ImageDraw.Draw(img)

    def lerp(a, b, t):
        return int(a + (b - a) * t)

    top = (124, 108, 246)     # --accent
    bottom = (77, 63, 196)    # #4d3fc4
    for y in range(size):
        t = y / size
        row_color = (lerp(top[0], bottom[0], t), lerp(top[1], bottom[1], t), lerp(top[2], bottom[2], t))
        draw.line([(0, y), (size, y)], fill=row_color)

    # Rounded-square mask (iOS/Android both clip/round icons themselves,
    # but a soft rounded edge here avoids a harsh square flash before that
    # clipping kicks in on platforms that don't mask it at all).
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=90, fill=255)
    bg = Image.new("RGB", (size, size), "#0a0d17")
    img = Image.composite(img, bg, mask)
    draw = ImageDraw.Draw(img)

    # Four corner brackets — a viewfinder/scan-target motif, legible at
    # any size without needing a font.
    m, L, w = 132, 92, 22
    corners = [
        (m, m, [((0, L), (0, 0)), ((0, 0), (L, 0))]),
        (size - m, m, [((0, L), (0, 0)), ((0, 0), (-L, 0))]),
        (m, size - m, [((0, -L), (0, 0)), ((0, 0), (L, 0))]),
        (size - m, size - m, [((0, -L), (0, 0)), ((0, 0), (-L, 0))]),
    ]
    for cx, cy, segments in corners:
        for (dx1, dy1), (dx2, dy2) in segments:
            draw.line([(cx + dx1, cy + dy1), (cx + dx2, cy + dy2)], fill="#ffffff", width=w)

    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return Response(buf.getvalue(), mimetype="image/png")


@bp.route("/<token>/lookup")
def lookup(token):
    t = _get_token_or_404(token)
    code = (request.args.get("code") or "").strip()
    if not code:
        return jsonify({"found": False, "error": "empty_code"}), 400

    item = InstanceEquipmentItem.query.filter_by(
        instance_id=t.instance_id, barcode_code=code, deleted_at=None,
    ).first()

    t.use_count += 1
    t.last_used_at = datetime.utcnow()
    db.session.commit()

    if item is None:
        return jsonify({"found": False, "code": code})

    return jsonify({
        "found": True,
        "code": code,
        "item": {
            "kind": item.kind,
            "name": item.name,
            "description": item.description,
            "status": item.status,
            "category": item.category,
            "sku": item.sku,
            "quantity": item.quantity,
            "unit": item.unit,
            "tool_status": item.tool_status,
            "checked_out_by_name": item.checked_out_by_name,
            "current_project": item.current_project,
        },
    })
