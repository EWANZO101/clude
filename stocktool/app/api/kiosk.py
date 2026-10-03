from datetime import datetime, timezone
from flask import Blueprint, request, jsonify, current_app
from flask_jwt_extended import create_access_token, jwt_required, current_user
from app.extensions import db
from app.models.barcode import Barcode
from app.models.audit_log import AuditAction
from app.utils.audit import log_action

api_kiosk_bp = Blueprint("api_kiosk", __name__, url_prefix="/api")


@api_kiosk_bp.route("/auth/kiosk-login", methods=["POST"])
def kiosk_login():
    """
    Badge-in for the shop-floor kiosk. No password — the scanned barcode
    IS the credential, same trust model as a physical door badge. Issues a
    short-lived token (see Config.KIOSK_TOKEN_EXPIRES) rather than the
    normal 8h API token.
    """
    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    device = data.get("device", "").strip() or "kiosk"

    if not code:
        return jsonify({"error": "code is required"}), 400

    bc = Barcode.query.filter_by(code=code).first()
    if not bc or not bc.user_id or not bc.user:
        return jsonify({"error": "Badge not recognised"}), 401

    user = bc.user
    if not user.is_active:
        return jsonify({"error": "This account is disabled"}), 401

    user.last_login = datetime.now(timezone.utc)
    db.session.commit()

    token = create_access_token(
        identity=str(user.id),
        additional_claims={"role": user.role, "kiosk": True},
        expires_delta=current_app.config["KIOSK_TOKEN_EXPIRES"],
    )
    log_action(AuditAction.KIOSK_LOGIN, "user", user.id, user.username,
               f"Kiosk badge login on {device}", user=user, device=device)
    db.session.commit()

    return jsonify({
        "access_token": token,
        "token_type": "Bearer",
        "expires_in_seconds": int(current_app.config["KIOSK_TOKEN_EXPIRES"].total_seconds()),
        "user": user.to_dict(),
    }), 200


@api_kiosk_bp.route("/lookup", methods=["POST"])
@jwt_required()
def lookup():
    """
    Generic barcode lookup — given any scanned code, identify what it is
    (user badge, item, tool, or project) and return its details. Used by
    the kiosk to figure out what just got scanned: a different badge
    (switch user), or an item/tool/project (start a stock action).
    """
    data = request.get_json(silent=True) or {}
    code = data.get("code", "").strip().upper()
    if not code:
        return jsonify({"error": "code is required"}), 400

    bc = Barcode.query.filter_by(code=code).first()
    if not bc:
        return jsonify({"error": f"No match for code '{code}'"}), 404

    entity = bc.user or bc.item or bc.tool or bc.project
    return jsonify({
        "entity_type": bc.entity_type,
        "code": bc.code,
        "entity": entity.to_dict() if entity else None,
    }), 200
