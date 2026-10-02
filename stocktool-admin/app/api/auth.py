from datetime import datetime, timezone, timedelta
from flask import Blueprint, request, jsonify, current_app
from flask_jwt_extended import create_access_token, jwt_required, current_user
from app.extensions import db
from app.models.user import User
from app.models.barcode import Barcode
from app.models.audit_log import AuditAction
from app.models.settings import Settings
from app.utils.audit import log_action

api_auth_bp = Blueprint("api_auth", __name__, url_prefix="/api/auth")


@api_auth_bp.route("/login", methods=["POST"])
def login():
    """Username/password login — used by the admin frontend."""
    data = request.get_json(silent=True) or {}
    username = data.get("username", "").strip()
    password = data.get("password", "")
    device = data.get("device", "").strip() or "admin-web"

    if not username or not password:
        return jsonify({"error": "username and password required"}), 400

    user = User.query.filter_by(username=username).first()
    if not user or not user.check_password(password) or not user.is_active:
        return jsonify({"error": "Invalid credentials"}), 401

    user.last_login = datetime.now(timezone.utc)
    db.session.commit()

    token = create_access_token(identity=str(user.id),
                                 additional_claims={"role": user.role})
    log_action(AuditAction.USER_LOGIN, "user", user.id, user.username,
               f"Login from {request.remote_addr}", user=user, device=device)
    db.session.commit()

    return jsonify({
        "access_token": token,
        "token_type": "Bearer",
        "user": user.to_dict()
    }), 200


@api_auth_bp.route("/kiosk-login", methods=["POST"])
def kiosk_login():
    """
    Badge-scan login — no password, the scanned barcode IS the credential
    (same trust model as a physical door badge). Used by the kiosk
    touch-UI, and available to any other authorised client that wants
    barcode-based login (e.g. the admin frontend, if you wire up a "scan
    to log in" option there later). Issues a shorter-lived token than a
    normal password login.
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

    expires_delta = timedelta(minutes=Settings.get().kiosk_token_expires_minutes)
    token = create_access_token(
        identity=str(user.id),
        additional_claims={"role": user.role, "badge_login": True},
        expires_delta=expires_delta,
    )
    log_action(AuditAction.KIOSK_LOGIN, "user", user.id, user.username,
               f"Badge login on {device}", user=user, device=device)
    db.session.commit()

    return jsonify({
        "access_token": token,
        "token_type": "Bearer",
        "expires_in_seconds": int(expires_delta.total_seconds()),
        "user": user.to_dict(),
    }), 200


@api_auth_bp.route("/me", methods=["GET"])
@jwt_required()
def me():
    return jsonify(current_user.to_dict()), 200


@api_auth_bp.route("/change-password", methods=["POST"])
@jwt_required()
def change_password():
    data = request.get_json(silent=True) or {}
    current_pw = data.get("current_password", "")
    new_pw = data.get("new_password", "")

    if not current_user.check_password(current_pw):
        return jsonify({"error": "Current password is incorrect"}), 400
    if len(new_pw) < 6:
        return jsonify({"error": "Password must be at least 6 characters"}), 400

    current_user.set_password(new_pw)
    current_user.force_password_change = False
    log_action(AuditAction.USER_PASSWORD_CHANGED, "user", current_user.id, current_user.username,
               "Password changed via API", user=current_user)
    db.session.commit()
    return jsonify({"message": "Password updated"}), 200


@api_auth_bp.route("/logout", methods=["POST"])
@jwt_required()
def logout():
    """
    JWTs here are stateless (no server-side revocation list), so this
    doesn't invalidate the token early — it just logs the event. The
    calling app (admin frontend / kiosk) is responsible for discarding the
    token client-side, and tokens are short-lived enough (8h admin / 15m
    badge) that this is an acceptable tradeoff for an internal tool.
    """
    log_action(AuditAction.USER_LOGOUT, "user", current_user.id, current_user.username,
               "Logged out", user=current_user)
    db.session.commit()
    return jsonify({"message": "Logged out"}), 200
