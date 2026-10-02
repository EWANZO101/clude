from datetime import datetime, timezone
from flask import Blueprint, request, jsonify
from flask_jwt_extended import create_access_token, jwt_required, current_user
from app.extensions import db
from app.models.user import User
from app.models.audit_log import AuditAction
from app.utils.audit import log_action

api_auth_bp = Blueprint("api_auth", __name__, url_prefix="/api/auth")


@api_auth_bp.route("/login", methods=["POST"])
def login():
    data = request.get_json(silent=True) or {}
    username = data.get("username", "").strip()
    password = data.get("password", "")

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
               f"API login from {request.remote_addr}", user=user)
    db.session.commit()

    return jsonify({
        "access_token": token,
        "token_type": "Bearer",
        "user": user.to_dict()
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
