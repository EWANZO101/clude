from flask import Blueprint, request, jsonify, g
from app.models import LocalUser
from app.auth import create_session, login_required

auth_bp = Blueprint("auth", __name__, url_prefix="/api/auth")


@auth_bp.route("/login", methods=["POST"])
def login():
    """
    Badge-scan login (primary path) or username fallback. No password
    here by design — passwords are managed in the cloud admin app;
    this device only ever sees a synced, read-mostly mirror of users.
    """
    data = request.get_json(silent=True) or {}
    badge_code = (data.get("badge_code") or "").strip().upper()
    username = (data.get("username") or "").strip()

    user = None
    if badge_code:
        user = LocalUser.query.filter_by(badge_code=badge_code).first()
    elif username:
        user = LocalUser.query.filter_by(username=username).first()

    if not user or not user.is_active:
        return jsonify({"error": "User not recognised."}), 401

    token = create_session(user)
    return jsonify({"token": token, "user": user.to_dict()}), 200


@auth_bp.route("/me", methods=["GET"])
@login_required
def me():
    return jsonify({
        "user_id": g.session["user_id"],
        "username": g.session["username"],
        "role": g.session["role"],
    }), 200
