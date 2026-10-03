from flask import Blueprint, request, jsonify, g
from app.models import LocalUser, RolePermission
from app.auth import create_session, login_required

auth_bp = Blueprint("auth", __name__, url_prefix="/api/auth")


@auth_bp.route("/login", methods=["POST"])
def login():
    """
    Login by badge code OR username -- one input field, no password.
    Tries an exact badge match first (case-insensitive, since badges
    are always stored/shown uppercase), then falls back to an exact
    username match (case-sensitive, as typed) if nothing matched as a
    badge. No client-side guessing between the two: the previous
    version of this route was badge-only, and before that had a
    client-side regex trying to guess badge-vs-username, which broke
    for any auto-generated badge containing letters outside a-f (the
    regex assumed hex-only). This version can't have that bug -- the
    server just tries both, in order, and the frontend always sends
    whatever was typed under the same field either way.

    Checks TWO independent gates on top of finding a matching account:
    the account's own is_active (per-PERSON), and RolePermission's
    login_enabled for that account's role (per-ROLE -- see
    app/models.py's RolePermission for why this is a separate concept,
    e.g. disabling every stock_user login at once for an audit without
    touching individual accounts).
    """
    data = request.get_json(silent=True) or {}
    raw = (data.get("badge_code") or "").strip()

    if not raw:
        return jsonify({"error": "Scan or enter a badge code, or type a username."}), 400

    user = LocalUser.query.filter_by(badge_code=raw.upper()).first()
    if not user:
        user = LocalUser.query.filter_by(username=raw).first()

    if not user or not user.is_active:
        return jsonify({"error": "Not recognised."}), 401

    if not RolePermission.is_login_enabled(user.role):
        return jsonify({"error": "Logins are currently disabled for your role. Ask an admin."}), 403

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
