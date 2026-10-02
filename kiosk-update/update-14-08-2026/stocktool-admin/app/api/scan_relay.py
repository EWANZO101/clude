"""
scan_relay.py — a generic "scan this with your phone" utility, independent
of the kiosk's login-bound pairing. Any page anywhere (the admin frontend,
mainly) can ask for a QR code, show it, and get back whatever a phone
scans — no login, no terminal, just "here's a barcode value, do something
with it". Used as a backup when a ZEBEX scanner isn't available.

Deliberately unauthenticated and CORS-open on the two endpoints a
cross-origin browser page needs (`/api/scan-relay/new` and
`/api/scan-relay/stream/<id>`) — a relay_id is an unguessable random
token, and the payload is just a barcode string, no more sensitive than
the barcode image endpoint already is.
"""
import secrets
import time
import json
import io
import threading
import queue
from flask import Blueprint, jsonify, request, Response, send_file, render_template, url_for, abort
import qrcode

scan_relay_bp = Blueprint("scan_relay", __name__)

_lock = threading.Lock()
RELAYS = {}          # relay_id -> {"queue": Queue, "expires_at": ts}
RELAY_TTL_SECONDS = 300  # 5 minutes — long enough to walk over, pull out a phone, scan


def _cleanup():
    now = time.time()
    with _lock:
        for rid in [r for r, v in RELAYS.items() if v["expires_at"] < now]:
            del RELAYS[rid]


@scan_relay_bp.route("/api/scan-relay/new", methods=["GET"])
def new_relay():
    _cleanup()
    relay_id = secrets.token_urlsafe(12)
    with _lock:
        RELAYS[relay_id] = {"queue": queue.Queue(), "expires_at": time.time() + RELAY_TTL_SECONDS}
    return jsonify({
        "relay_id": relay_id,
        "expires_in": RELAY_TTL_SECONDS,
        "qr_image_url": url_for("scan_relay.relay_qr_image", relay_id=relay_id),
    })


@scan_relay_bp.route("/api/scan-relay/qr/<relay_id>.png")
def relay_qr_image(relay_id):
    with _lock:
        exists = relay_id in RELAYS
    if not exists:
        abort(404)
    scan_url = url_for("scan_relay.relay_scan_page", relay_id=relay_id, _external=True)
    img = qrcode.make(scan_url, box_size=8, border=2)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return send_file(buf, mimetype="image/png")


@scan_relay_bp.route("/scan-relay/<relay_id>")
def relay_scan_page(relay_id):
    with _lock:
        exists = relay_id in RELAYS
    if not exists:
        return render_template("mobile_expired.html"), 410
    return render_template("mobile_scan_relay.html", relay_id=relay_id)


@scan_relay_bp.route("/api/scan-relay/<relay_id>/scan", methods=["POST"])
def relay_scan(relay_id):
    with _lock:
        relay = RELAYS.get(relay_id)
    if not relay:
        return jsonify({"ok": False, "error": "This scan session has expired."}), 410

    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    if not code:
        return jsonify({"ok": False, "error": "No code provided."}), 400

    relay["queue"].put(code)
    return jsonify({"ok": True}), 200


@scan_relay_bp.route("/api/scan-relay/stream/<relay_id>")
def relay_stream(relay_id):
    with _lock:
        relay = RELAYS.get(relay_id)
    if not relay:
        abort(404)

    def gen():
        q = relay["queue"]
        yield "event: ready\ndata: {}\n\n"
        last_heartbeat = time.time()
        while True:
            try:
                code = q.get(timeout=15)
                yield f"event: scan\ndata: {json.dumps({'code': code})}\n\n"
            except Exception:
                pass
            if time.time() - last_heartbeat > 15:
                last_heartbeat = time.time()
                yield ": heartbeat\n\n"

    resp = Response(gen(), mimetype="text/event-stream")
    resp.headers["Cache-Control"] = "no-cache"
    resp.headers["X-Accel-Buffering"] = "no"
    return resp


@scan_relay_bp.after_request
def add_cors(response):
    # Only these two endpoints are ever called cross-origin (the admin
    # frontend's browser JS, on a different host/port than this API). The
    # phone always loads /scan-relay/<id> from THIS same origin, so its
    # own POST back to /api/scan-relay/<id>/scan never needs CORS.
    if request.path == "/api/scan-relay/new" or request.path.startswith("/api/scan-relay/stream/"):
        response.headers["Access-Control-Allow-Origin"] = "*"
    return response
