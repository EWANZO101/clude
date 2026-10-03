import secrets
import time
import json
import io
from flask import (
    Blueprint, render_template, request, jsonify, current_app,
    make_response, Response, url_for, abort, send_file
)
import qrcode

from app.extensions import db
from app.models import User, Item, Barcode, AuditAction, Settings, Category, Tool, DashboardLayout
from app.utils.audit import log_action
from app.kiosk import state
from app.api.barcodes import looks_like_url

kiosk_bp = Blueprint(
    "kiosk", __name__,
    url_prefix="/kiosk",
    template_folder="templates",
    static_folder="static",
)

_COOKIE = "terminal_id"


def _terminal_id_from_request() -> str:
    return request.cookies.get(_COOKIE) or ""


def _ensure_terminal_cookie(response, terminal_id: str, is_new: bool):
    if is_new:
        response.set_cookie(_COOKIE, terminal_id, max_age=60 * 60 * 24 * 365,
                             httponly=True, samesite="Lax")
    return response


def _get_terminal():
    """Returns (terminal_id, terminal_dict, is_new_cookie)."""
    tid = _terminal_id_from_request()
    is_new = not tid
    if is_new:
        tid = secrets.token_urlsafe(16)

    requested_device = request.args.get("device", "").strip()
    default_device = requested_device or current_app.config["KIOSK_NAME"]
    terminal = state.get_or_create_terminal(tid, default_device)
    if requested_device:
        terminal["device"] = requested_device
    return tid, terminal, is_new


def _current_user_for(terminal: dict):
    if not terminal.get("user_id"):
        return None
    user = db.session.get(User, terminal["user_id"])
    if not user or not user.is_active:
        terminal["user_id"] = None
        terminal["username"] = None
        terminal["role"] = None
        return None
    return user


def _login_badge(terminal: dict, code: str, device: str):
    bc = Barcode.query.filter_by(code=code).first()
    if not bc or not bc.user_id or not bc.user:
        return None, "Badge not recognised."
    user = bc.user
    if not user.is_active:
        return None, "This account is disabled."

    terminal["user_id"] = user.id
    terminal["username"] = user.username
    terminal["role"] = user.role

    log_action(AuditAction.KIOSK_LOGIN, "user", user.id, user.username,
               f"Kiosk badge login on {device}", user=user, device=device)
    db.session.commit()
    return user, None


# ── Screen rendering ─────────────────────────────────────────────────────

@kiosk_bp.route("/")
def index():
    tid, terminal, is_new = _get_terminal()
    user = _current_user_for(terminal)
    settings = Settings.get()

    if not user:
        resp = make_response(render_template("idle.html", device=terminal["device"]))
    elif settings.kiosk_home_screen == "browse":
        resp = make_response(render_template(
            "browse.html", kiosk_user=user, device=terminal["device"],
            idle_timeout=settings.kiosk_idle_timeout_seconds, preview=False,
        ))
    else:
        resp = make_response(render_template(
            "dashboard.html",
            kiosk_user=user,
            device=terminal["device"],
            idle_timeout=settings.kiosk_idle_timeout_seconds,
        ))
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/scan")
def scan_screen():
    """Explicit route to the classic scan-to-remove screen, reachable from
    the browse dashboard's 'Scan' link regardless of the configured home
    screen."""
    tid, terminal, is_new = _get_terminal()
    user = _current_user_for(terminal)
    settings = Settings.get()
    if not user:
        resp = make_response(render_template("idle.html", device=terminal["device"]))
    else:
        resp = make_response(render_template(
            "dashboard.html", kiosk_user=user, device=terminal["device"],
            idle_timeout=settings.kiosk_idle_timeout_seconds,
        ))
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/browse")
def browse_screen():
    """Explicit route to the Builder-Mode-driven dashboard, reachable from
    the scan screen's 'Browse' link regardless of the configured home
    screen."""
    tid, terminal, is_new = _get_terminal()
    user = _current_user_for(terminal)
    settings = Settings.get()
    if not user:
        resp = make_response(render_template("idle.html", device=terminal["device"]))
    else:
        resp = make_response(render_template(
            "browse.html", kiosk_user=user, device=terminal["device"],
            idle_timeout=settings.kiosk_idle_timeout_seconds, preview=False,
        ))
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/preview/<token>")
def preview(token):
    """Read-only render of a layout DRAFT for Builder Mode's live-preview
    iframe. Gated by a short-lived token (see state.create_preview_token),
    not by kiosk login — an admin previewing a layout isn't badged into
    any terminal. Stock-affecting actions are disabled in this mode; see
    browse.js's `preview` flag."""
    layout_id = state.get_preview_layout_id(token)
    if not layout_id:
        return render_template("mobile_expired.html"), 410  # reuse: "this link has expired" messaging fits here too
    layout = db.session.get(DashboardLayout, layout_id)
    if not layout:
        abort(404)
    settings = Settings.get()
    return render_template(
        "browse.html", kiosk_user=None, device="Preview",
        idle_timeout=settings.kiosk_idle_timeout_seconds,
        preview=True, preview_layout_id=layout.id,
    )


# ── Builder-Mode-driven dashboard data (category grid / item grid / etc.) ──

@kiosk_bp.route("/api/layout")
def api_layout():
    """Resolved layout for THIS terminal (by device name), or for a
    specific layout id when in preview mode (?preview_layout_id=)."""
    preview_layout_id = request.args.get("preview_layout_id", type=int)
    if preview_layout_id:
        layout = db.session.get(DashboardLayout, preview_layout_id)
        if not layout:
            return jsonify({"components": []}), 200
        return jsonify({"components": layout.draft, "preview": True}), 200

    tid, terminal, is_new = _get_terminal()
    device = terminal["device"]
    layout = DashboardLayout.query.filter_by(target_device=device).filter(
        DashboardLayout.published_components.isnot(None)
    ).first()
    if not layout:
        layout = DashboardLayout.query.filter_by(is_default=True).filter(
            DashboardLayout.published_components.isnot(None)
        ).first()
    resp = jsonify({"components": layout.published if layout else [], "layout_id": layout.id if layout else None})
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/api/categories")
def api_categories():
    categories = Category.query.order_by(Category.sort_order, Category.name).all()
    return jsonify([{
        "id": c.id, "name": c.name, "slug": c.slug, "icon": c.icon, "color": c.color,
        "item_count": sum(1 for i in c.items if i.is_active),
        "tool_count": sum(1 for t in c.tools if t.is_active),
    } for c in categories]), 200


@kiosk_bp.route("/api/categories/<int:category_id>/items")
def api_category_items(category_id):
    category = db.session.get(Category, category_id)
    if not category:
        abort(404)
    items = [i for i in category.items if i.is_active]
    return jsonify([i.to_dict() for i in items]), 200


@kiosk_bp.route("/api/categories/<int:category_id>/tools")
def api_category_tools(category_id):
    category = db.session.get(Category, category_id)
    if not category:
        abort(404)
    tools = [t for t in category.tools if t.is_active]
    return jsonify([t.to_dict() for t in tools]), 200


@kiosk_bp.route("/api/items")
def api_items_all():
    """All active items, unfiltered — used by an item_grid component with
    no category_ids configured ('show everything')."""
    items = Item.query.filter_by(is_active=True).order_by(Item.name).all()
    return jsonify([i.to_dict() for i in items]), 200


@kiosk_bp.route("/api/tools")
def api_tools_all():
    tools = Tool.query.filter_by(is_active=True).order_by(Tool.name).all()
    return jsonify([t.to_dict() for t in tools]), 200


@kiosk_bp.route("/api/summary")
def api_summary():
    """Backs the stock_summary component."""
    total_items = Item.query.filter_by(is_active=True).count()
    low_stock = Item.query.filter(
        Item.is_active == True, Item.measurement_type == "count",
        Item.quantity <= Item.low_stock_threshold, Item.quantity > 0,
    ).count()
    out_of_stock = Item.query.filter(
        Item.is_active == True, Item.measurement_type == "count", Item.quantity == 0,
    ).count()
    return jsonify({
        "total_items": total_items, "low_stock": low_stock, "out_of_stock": out_of_stock,
    }), 200


# ── Local scan API (physical scanner / manual entry at the terminal) ──────

@kiosk_bp.route("/api/scan-badge", methods=["POST"])
def scan_badge():
    tid, terminal, is_new = _get_terminal()
    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()

    if not code:
        resp = jsonify({"ok": False, "error": "No code provided."})
        return _ensure_terminal_cookie(resp, tid, is_new), 400

    if looks_like_url(code):
        resp = jsonify({"ok": False, "error": "That's a phone-pairing QR code, not a badge — "
                                               "scan it with a phone's camera, not the handheld scanner."})
        return _ensure_terminal_cookie(resp, tid, is_new), 400

    user, error = _login_badge(terminal, code, terminal["device"])
    if error:
        resp = jsonify({"ok": False, "error": error})
        return _ensure_terminal_cookie(resp, tid, is_new), 401

    resp = jsonify({"ok": True, "user": {"id": user.id, "username": user.username, "role": user.role}})
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/api/scan-code", methods=["POST"])
def scan_code():
    tid, terminal, is_new = _get_terminal()
    user = _current_user_for(terminal)
    if not user:
        resp = jsonify({"ok": False, "error": "Not logged in."})
        return _ensure_terminal_cookie(resp, tid, is_new), 401

    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    if not code:
        resp = jsonify({"ok": False, "error": "No code provided."})
        return _ensure_terminal_cookie(resp, tid, is_new), 400

    result, status = _resolve_scan(terminal, code, terminal["device"])
    resp = jsonify(result)
    return _ensure_terminal_cookie(resp, tid, is_new), status


def _resolve_scan(terminal: dict, code: str, device: str):
    """Shared by the local scan-code endpoint AND the phone relay endpoint
    — a scanned code means the same thing regardless of which camera saw
    it."""
    if looks_like_url(code):
        return {"ok": False, "error": "That's a phone-pairing QR code, not an item/tool/badge "
                                       "barcode — scan it with a phone's camera, not the "
                                       "handheld scanner."}, 400

    bc = Barcode.query.filter_by(code=code).first()
    if not bc:
        return {"ok": False, "error": f"No match for code '{code}'."}, 404

    if bc.entity_type == "user":
        new_user, error = _login_badge(terminal, code, device)
        if error:
            return {"ok": False, "error": error}, 401
        return {
            "ok": True, "type": "user_switch",
            "user": {"id": new_user.id, "username": new_user.username, "role": new_user.role},
        }, 200

    if bc.entity_type == "item" and bc.item:
        item = bc.item
        return {
            "ok": True, "type": "item",
            "item": {"id": item.id, "name": item.name, "quantity": item.quantity,
                      "unit": item.unit, "sku": item.sku},
        }, 200

    if bc.entity_type == "tool" and bc.tool:
        return {
            "ok": True, "type": "tool",
            "message": f"'{bc.tool.name}' is a tool — checkout/checkin isn't available "
                       f"on this kiosk yet. Use the admin panel.",
        }, 200

    if bc.entity_type == "project" and bc.project:
        return {
            "ok": True, "type": "project",
            "message": f"'{bc.project.name}' is a project. No kiosk action for projects yet.",
        }, 200

    return {"ok": False, "error": "Barcode isn't linked to anything usable here."}, 404


@kiosk_bp.route("/api/quick-remove", methods=["POST"])
def quick_remove():
    tid, terminal, is_new = _get_terminal()
    user = _current_user_for(terminal)
    if not user:
        resp = jsonify({"ok": False, "error": "Not logged in."})
        return _ensure_terminal_cookie(resp, tid, is_new), 401

    data = request.get_json(silent=True) or {}
    item_id = data.get("item_id")
    quantity = int(data.get("quantity", 0) or 0)
    device = terminal["device"]

    if quantity <= 0:
        resp = jsonify({"ok": False, "error": "Enter a quantity greater than zero."})
        return _ensure_terminal_cookie(resp, tid, is_new), 400

    item = db.session.get(Item, item_id) if item_id else None
    if not item:
        resp = jsonify({"ok": False, "error": "Item not found."})
        return _ensure_terminal_cookie(resp, tid, is_new), 404

    old_qty = item.quantity
    item.adjust_stock(-quantity)
    log_action(AuditAction.KIOSK_QUICK_REMOVE, "item", item.id, item.name,
               f"Kiosk quick-remove {quantity} ({old_qty} → {item.quantity}) "
               f"by {user.username} on {device}",
               user=user, quantity_delta=-quantity, device=device)
    db.session.commit()

    resp = jsonify({"ok": True, "item": {"id": item.id, "name": item.name, "quantity": item.quantity}})
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/api/quick-add", methods=["POST"])
def quick_add():
    """
    Counterpart to quick-remove — used by the triple-scan-to-add gesture
    (see kiosk.js: three scans of the same item within the debounce
    window means 'add stock' instead of the default single-scan
    'remove stock').
    """
    tid, terminal, is_new = _get_terminal()
    user = _current_user_for(terminal)
    if not user:
        resp = jsonify({"ok": False, "error": "Not logged in."})
        return _ensure_terminal_cookie(resp, tid, is_new), 401

    data = request.get_json(silent=True) or {}
    item_id = data.get("item_id")
    quantity = int(data.get("quantity", 0) or 0)
    device = terminal["device"]

    if quantity <= 0:
        resp = jsonify({"ok": False, "error": "Enter a quantity greater than zero."})
        return _ensure_terminal_cookie(resp, tid, is_new), 400

    item = db.session.get(Item, item_id) if item_id else None
    if not item:
        resp = jsonify({"ok": False, "error": "Item not found."})
        return _ensure_terminal_cookie(resp, tid, is_new), 404

    old_qty = item.quantity
    item.adjust_stock(quantity)
    log_action(AuditAction.KIOSK_QUICK_ADD, "item", item.id, item.name,
               f"Kiosk quick-add {quantity} ({old_qty} → {item.quantity}) "
               f"by {user.username} on {device}",
               user=user, quantity_delta=quantity, device=device)
    db.session.commit()

    resp = jsonify({"ok": True, "item": {"id": item.id, "name": item.name, "quantity": item.quantity}})
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/api/quick-adjust-amount", methods=["POST"])
def quick_adjust_amount():
    """Counterpart to quick-add/quick-remove for weight/volume/length-
    tracked items, used by the Browse dashboard's item cards."""
    tid, terminal, is_new = _get_terminal()
    user = _current_user_for(terminal)
    if not user:
        resp = jsonify({"ok": False, "error": "Not logged in."})
        return _ensure_terminal_cookie(resp, tid, is_new), 401

    data = request.get_json(silent=True) or {}
    item_id = data.get("item_id")
    delta = data.get("delta")
    device = terminal["device"]

    item = db.session.get(Item, item_id) if item_id else None
    if not item:
        resp = jsonify({"ok": False, "error": "Item not found."})
        return _ensure_terminal_cookie(resp, tid, is_new), 404
    if item.measurement_type == "count" or delta is None:
        resp = jsonify({"ok": False, "error": "This item isn't tracked by amount."})
        return _ensure_terminal_cookie(resp, tid, is_new), 400

    delta = float(delta)
    old = item.stock_amount or 0
    item.stock_amount = max(0.0, old + delta)
    direction = "increased" if delta > 0 else "decreased"
    log_action(AuditAction.KIOSK_QUICK_REMOVE if delta < 0 else AuditAction.KIOSK_QUICK_ADD,
               "item", item.id, item.name,
               f"Kiosk {direction} by {abs(delta):g}{item.unit or ''} "
               f"({old:g} → {item.stock_amount:g}) by {user.username} on {device}",
               user=user, device=device)
    db.session.commit()

    resp = jsonify({"ok": True, "item": item.to_dict()})
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/api/logout", methods=["POST"])
def logout():
    tid, terminal, is_new = _get_terminal()
    terminal["user_id"] = None
    terminal["username"] = None
    terminal["role"] = None
    resp = jsonify({"ok": True})
    return _ensure_terminal_cookie(resp, tid, is_new)


# ── Phase 2: phone as backup scanner ────────────────────────────────────
#
# A phone pairs to ONE terminal by scanning a rotating QR code shown on
# that terminal's screen. Once paired, whatever the phone scans (a badge
# to log in/switch user, or an item to remove stock) is relayed to the
# SAME terminal state as if it had been scanned locally — the quantity
# keypad still appears, and gets confirmed, on the physical touchscreen;
# the phone is only ever an extra camera, never a second independent
# session. Live updates reach the terminal over Server-Sent Events.

@kiosk_bp.route("/api/pairing/new", methods=["GET"])
def pairing_new():
    tid, terminal, is_new = _get_terminal()
    pairing = state.create_pairing(tid)
    pair_url = url_for("kiosk.mobile_pair_page", pairing_id=pairing["pairing_id"], _external=True)
    resp = jsonify({
        "pairing_id": pairing["pairing_id"],
        "expires_in": state.PAIRING_TTL_SECONDS,
        "qr_image_url": url_for("kiosk.pairing_qr_image", pairing_id=pairing["pairing_id"]),
        "pair_url": pair_url,
    })
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/api/pairing/qr/<pairing_id>.png")
def pairing_qr_image(pairing_id):
    pairing = state.get_pairing(pairing_id)
    if not pairing:
        abort(404)
    pair_url = url_for("kiosk.mobile_pair_page", pairing_id=pairing_id, _external=True)
    img = qrcode.make(pair_url, box_size=8, border=2)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return send_file(buf, mimetype="image/png")


@kiosk_bp.route("/api/stream")
def stream():
    """
    Server-Sent Events — the terminal opens exactly one of these on page
    load and keeps it open for as long as the idle/dashboard screen is
    showing, so a phone pairing or a phone-relayed scan can update the
    screen live without polling.

    Note for deployment: this holds a worker thread open for its whole
    duration. waitress's thread pool (see run.py) needs at least one spare
    thread per kiosk terminal that's currently displayed — fine for a
    small number of kiosks, but bump `threads=` in run.py if you deploy
    many terminals at once.
    """
    tid, terminal, is_new = _get_terminal()

    def gen():
        q = terminal["queue"]
        last_heartbeat = time.time()
        yield "event: ready\ndata: {}\n\n"
        while True:
            try:
                item = q.get(timeout=15)
                yield f"event: {item['event']}\ndata: {json.dumps(item['data'])}\n\n"
            except Exception:
                pass
            if time.time() - last_heartbeat > 15:
                last_heartbeat = time.time()
                yield ": heartbeat\n\n"

    resp = Response(gen(), mimetype="text/event-stream")
    resp.headers["Cache-Control"] = "no-cache"
    resp.headers["X-Accel-Buffering"] = "no"  # don't let nginx buffer SSE if it sits in front
    return _ensure_terminal_cookie(resp, tid, is_new)


@kiosk_bp.route("/mobile/<pairing_id>")
def mobile_pair_page(pairing_id):
    pairing = state.get_pairing(pairing_id)
    if not pairing or pairing["status"] == "expired":
        return render_template("mobile_expired.html"), 410
    terminal = state.TERMINALS.get(pairing["terminal_id"])
    device = terminal["device"] if terminal else "this kiosk"
    already_paired = pairing["status"] == "paired"
    return render_template(
        "mobile_pair.html",
        pairing_id=pairing_id, device=device, already_paired=already_paired,
        phone_username=pairing.get("phone_username"),
    )


@kiosk_bp.route("/mobile/<pairing_id>/login", methods=["POST"])
def mobile_login(pairing_id):
    pairing = state.get_pairing(pairing_id)
    if not pairing or pairing["status"] == "expired":
        return jsonify({"ok": False, "error": "This pairing link has expired. Go back to the kiosk for a fresh QR code."}), 410

    terminal = state.TERMINALS.get(pairing["terminal_id"])
    if not terminal:
        return jsonify({"ok": False, "error": "That kiosk terminal is no longer active."}), 410

    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    if not code:
        return jsonify({"ok": False, "error": "No code provided."}), 400

    user, error = _login_badge(terminal, code, "mobile")
    if error:
        return jsonify({"ok": False, "error": error}), 401

    state.mark_paired(pairing_id, user.username)
    state.push_event(pairing["terminal_id"], "login", {"username": user.username})

    return jsonify({"ok": True, "user": {"username": user.username}}), 200


@kiosk_bp.route("/mobile/<pairing_id>/scan", methods=["POST"])
def mobile_scan(pairing_id):
    pairing = state.get_pairing(pairing_id)
    if not pairing or pairing["status"] != "paired":
        return jsonify({"ok": False, "error": "Not paired yet — scan your badge first."}), 401

    terminal = state.TERMINALS.get(pairing["terminal_id"])
    if not terminal:
        return jsonify({"ok": False, "error": "That kiosk terminal is no longer active."}), 410

    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    if not code:
        return jsonify({"ok": False, "error": "No code provided."}), 400

    result, status = _resolve_scan(terminal, code, "mobile")

    # Push a live update to the terminal's screen so the shop-floor person
    # watching it sees what the phone just saw.
    if result.get("ok"):
        if result.get("type") == "user_switch":
            state.push_event(pairing["terminal_id"], "login", {"username": result["user"]["username"]})
        elif result.get("type") == "item":
            state.push_event(pairing["terminal_id"], "item_scan", {"item": result["item"]})
        else:
            state.push_event(pairing["terminal_id"], "message", {"message": result.get("message", "Scanned.")})

    return jsonify(result), status
