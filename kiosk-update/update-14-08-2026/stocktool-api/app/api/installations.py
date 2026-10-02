import uuid
from flask import Blueprint, request, jsonify, g
from flask_jwt_extended import jwt_required
from app.extensions import db
from app.models import Installation
from app.utils.decorators import admin_required
from app.utils.install_auth import install_token_required

api_installations_bp = Blueprint("api_installations", __name__, url_prefix="/api/installations")


@api_installations_bp.route("/register", methods=["POST"])
def register():
    """
    First-run registration for a kiosk-v2 desktop install. Returns an
    installation_id + a plaintext token shown exactly once — the desktop
    app stores the token locally and sends it as a Bearer token on every
    subsequent sync/config/update-check request.

    No login/admin auth required to call this — an install has no
    credentials yet at this point. In production this should be paired
    with a short-lived one-time registration code shown during setup
    (Part 6, alongside the Cloudflare Tunnel provisioning) so registration
    can't be spammed by an arbitrary caller; that gate isn't in place yet
    in this part.
    """
    data = request.get_json(silent=True) or {}
    device_name = (data.get("device_name") or "").strip()[:120] or "Unnamed Kiosk"
    app_version = (data.get("app_version") or "").strip()[:32] or None

    installation_id = str(uuid.uuid4())
    inst, token = Installation.create_with_token(installation_id, device_name, app_version)
    db.session.commit()

    return jsonify({
        "installation_id": installation_id,
        "token": token,
        "message": "Store this token locally — it will not be shown again.",
    }), 201


@api_installations_bp.route("/heartbeat", methods=["POST"])
@install_token_required
def heartbeat():
    """Lightweight check-in — the desktop app calls this periodically so
    admins can see which kiosks are online and on what version."""
    data = request.get_json(silent=True) or {}
    app_version = (data.get("app_version") or "").strip()[:32]
    if app_version:
        g.installation.app_version = app_version
    g.installation.touch()
    db.session.commit()
    return jsonify({"ok": True, "server_time": _utcnow_iso()}), 200


@api_installations_bp.route("", methods=["GET"])
@jwt_required()
@admin_required
def list_installations():
    """Admin visibility into registered kiosks — which devices exist,
    what version they're on, when they last checked in."""
    installations = Installation.query.order_by(Installation.created_at.desc()).all()
    return jsonify([i.to_dict() for i in installations]), 200


@api_installations_bp.route("/<installation_id>", methods=["DELETE"])
@jwt_required()
@admin_required
def deactivate_installation(installation_id):
    """Revoke an installation's token (e.g. a kiosk device was
    decommissioned or lost) — it can no longer sync/pull config."""
    inst = Installation.query.filter_by(installation_id=installation_id).first()
    if not inst:
        return jsonify({"error": "Installation not found."}), 404
    inst.is_active = False
    db.session.commit()
    return jsonify({"message": "Installation deactivated."}), 200


def _utcnow_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()
