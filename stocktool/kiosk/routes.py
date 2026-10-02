from flask import Blueprint, render_template, request, jsonify, session, current_app
from app.extensions import db
from app.models import User, Item, Barcode, AuditAction
from app.utils.audit import log_action

kiosk_bp = Blueprint("kiosk", __name__)


# ── Screen rendering ─────────────────────────────────────────────────────

@kiosk_bp.route("/")
def index():
    user = _current_user()
    if not user:
        return render_template("idle.html")
    return render_template(
        "dashboard.html",
        kiosk_user=user,
        idle_timeout=current_app.config["IDLE_TIMEOUT_SECONDS"],
    )


# ── Helpers ───────────────────────────────────────────────────────────────

def _current_user():
    user_id = session.get("user_id")
    if not user_id:
        return None
    user = db.session.get(User, user_id)
    if not user or not user.is_active:
        session.clear()
        return None
    return user


def _login_badge(code: str, device: str):
    """Look up a scanned code as a user badge and log the kiosk in as that
    user. Returns (user, error_message)."""
    bc = Barcode.query.filter_by(code=code).first()
    if not bc or not bc.user_id or not bc.user:
        return None, "Badge not recognised."
    user = bc.user
    if not user.is_active:
        return None, "This account is disabled."

    session.clear()
    session.permanent = True
    session["user_id"] = user.id

    log_action(AuditAction.KIOSK_LOGIN, "user", user.id, user.username,
               f"Kiosk badge login on {device}", user=user, device=device)
    db.session.commit()
    return user, None


# ── API used by the kiosk UI (fetch() calls from kiosk.js) ─────────────────

@kiosk_bp.route("/api/scan-badge", methods=["POST"])
def scan_badge():
    """Idle screen: scan a badge to log in."""
    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    device = current_app.config["KIOSK_NAME"]

    if not code:
        return jsonify({"ok": False, "error": "No code provided."}), 400

    user, error = _login_badge(code, device)
    if error:
        return jsonify({"ok": False, "error": error}), 401

    return jsonify({
        "ok": True,
        "user": {"id": user.id, "username": user.username, "role": user.role},
        "idle_timeout": current_app.config["IDLE_TIMEOUT_SECONDS"],
    }), 200


@kiosk_bp.route("/api/scan-code", methods=["POST"])
def scan_code():
    """
    Dashboard screen: scan an item, project, tool, or a different badge.
    A badge here means "switch user" instantly, no logout step needed.
    An item returns its info so the UI can prompt for a remove quantity.
    Tools/projects are identified but read-only from the kiosk in Phase 1.
    """
    user = _current_user()
    if not user:
        return jsonify({"ok": False, "error": "Not logged in."}), 401

    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    device = current_app.config["KIOSK_NAME"]

    if not code:
        return jsonify({"ok": False, "error": "No code provided."}), 400

    bc = Barcode.query.filter_by(code=code).first()
    if not bc:
        return jsonify({"ok": False, "error": f"No match for code '{code}'."}), 404

    # Different badge scanned mid-session → instant switch, no separate
    # logout step (matches the shop-floor "next person just badges in" flow).
    if bc.entity_type == "user":
        new_user, error = _login_badge(code, device)
        if error:
            return jsonify({"ok": False, "error": error}), 401
        return jsonify({
            "ok": True,
            "type": "user_switch",
            "user": {"id": new_user.id, "username": new_user.username, "role": new_user.role},
        }), 200

    if bc.entity_type == "item" and bc.item:
        item = bc.item
        return jsonify({
            "ok": True,
            "type": "item",
            "item": {
                "id": item.id, "name": item.name, "quantity": item.quantity,
                "unit": item.unit, "sku": item.sku,
            },
        }), 200

    if bc.entity_type == "tool" and bc.tool:
        return jsonify({
            "ok": True, "type": "tool",
            "message": f"'{bc.tool.name}' is a tool — checkout/checkin isn't available "
                       f"on this kiosk yet. Use the admin panel.",
        }), 200

    if bc.entity_type == "project" and bc.project:
        return jsonify({
            "ok": True, "type": "project",
            "message": f"'{bc.project.name}' is a project. No kiosk action for projects yet.",
        }), 200

    return jsonify({"ok": False, "error": "Barcode isn't linked to anything usable here."}), 404


@kiosk_bp.route("/api/quick-remove", methods=["POST"])
def quick_remove():
    """One-scan stock removal. Always subtracts — additions still go
    through the full admin panel, on purpose (see stocktool-admin's
    /api/items/<id>/quick-remove docstring for why)."""
    user = _current_user()
    if not user:
        return jsonify({"ok": False, "error": "Not logged in."}), 401

    data = request.get_json(silent=True) or {}
    item_id = data.get("item_id")
    quantity = int(data.get("quantity", 0) or 0)
    device = current_app.config["KIOSK_NAME"]

    if quantity <= 0:
        return jsonify({"ok": False, "error": "Enter a quantity greater than zero."}), 400

    item = db.session.get(Item, item_id) if item_id else None
    if not item:
        return jsonify({"ok": False, "error": "Item not found."}), 404

    old_qty = item.quantity
    item.adjust_stock(-quantity)
    log_action(AuditAction.KIOSK_QUICK_REMOVE, "item", item.id, item.name,
               f"Kiosk quick-remove {quantity} ({old_qty} → {item.quantity}) "
               f"by {user.username} on {device}",
               user=user, quantity_delta=-quantity, device=device)
    db.session.commit()

    return jsonify({
        "ok": True,
        "item": {"id": item.id, "name": item.name, "quantity": item.quantity},
    }), 200


@kiosk_bp.route("/api/logout", methods=["POST"])
def logout():
    """Manual 'Done' button — the same effect the 60s idle timer produces."""
    session.clear()
    return jsonify({"ok": True}), 200
