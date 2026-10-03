from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.user import User, Role
from app.models.tool import Tool
from app.models.tool_history import ToolHistory
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode

api_users_bp = Blueprint("api_users", __name__, url_prefix="/api/users")


def _active_admin_count(exclude_user_id=None):
    query = User.query.filter_by(role=Role.ADMIN, is_active=True)
    if exclude_user_id is not None:
        query = query.filter(User.id != exclude_user_id)
    return query.count()


@api_users_bp.route("/", methods=["GET"])
@jwt_required()
@admin_required
def list_users():
    search = request.args.get("q", "").strip()
    query = User.query
    if search:
        query = query.filter(User.username.ilike(f"%{search}%") | User.email.ilike(f"%{search}%"))
    users = query.order_by(User.created_at.desc()).all()
    return jsonify([u.to_dict() for u in users]), 200


@api_users_bp.route("/<int:user_id>", methods=["GET"])
@jwt_required()
@admin_required
def get_user(user_id):
    user = User.query.get_or_404(user_id)
    return jsonify(user.to_dict()), 200


@api_users_bp.route("/", methods=["POST"])
@jwt_required()
@admin_required
def create_user():
    data = request.get_json(silent=True) or {}
    username = data.get("username", "").strip()
    email = data.get("email", "").strip()
    password = data.get("password", "")
    role = data.get("role", Role.STOCK_USER)
    force_change = bool(data.get("force_password_change", False))
    badge_only = bool(data.get("badge_only", False))

    errors = []
    if not username:
        errors.append("Username is required.")
    if badge_only:
        # Badge-only accounts can never log into the admin site with a
        # password, so an admin role would be a dead end — force stock_user.
        role = Role.STOCK_USER
        force_change = False
    else:
        if not email:
            errors.append("Email is required.")
        if len(password) < 6:
            errors.append("Password must be at least 6 characters.")
        if role not in Role.ALL:
            errors.append("Invalid role.")
    if User.query.filter_by(username=username).first():
        errors.append(f"Username '{username}' already exists.")
    if email and User.query.filter_by(email=email).first():
        errors.append(f"Email '{email}' already exists.")
    if errors:
        return jsonify({"error": " ".join(errors)}), 400

    user = User(username=username, email=email or None, role=role,
                force_password_change=force_change)
    if badge_only:
        user.clear_password()
    else:
        user.set_password(password)
    db.session.add(user)
    db.session.flush()

    generate_barcode("user", user.id)

    detail = f"Badge-only user '{user.username}' created by {current_user.username}" if badge_only \
        else f"User '{user.username}' created by {current_user.username}"
    log_action(AuditAction.USER_CREATED, "user", user.id, user.username, detail, user=current_user)
    db.session.commit()
    return jsonify(user.to_dict()), 201


@api_users_bp.route("/<int:user_id>", methods=["PUT"])
@jwt_required()
@admin_required
def update_user(user_id):
    user = User.query.get_or_404(user_id)
    data = request.get_json(silent=True) or {}

    new_role = data.get("role", user.role)
    new_is_active = data.get("is_active", user.is_active)

    # Badge-only accounts are always forced to stock_user (an admin with
    # no password could never log into the admin site again) — resolve
    # that BEFORE the last-admin guard below.
    make_badge_only = data.get("badge_only")
    if make_badge_only is True:
        new_role = Role.STOCK_USER

    # Guard against locking the system out of all admin accounts by
    # demoting or deactivating the last remaining active admin.
    was_active_admin = user.role == Role.ADMIN and user.is_active
    will_stay_admin = new_role == Role.ADMIN and new_is_active
    if was_active_admin and not will_stay_admin and _active_admin_count(exclude_user_id=user.id) == 0:
        return jsonify({"error": "Cannot remove admin rights or disable the last remaining admin account."}), 409

    if "email" in data:
        user.email = data["email"].strip() or None

    # Switching TO badge-only clears any existing password. Switching AWAY
    # from badge-only requires setting a real password in the same request.
    password_already_set = False
    if make_badge_only is True:
        user.clear_password()
        user.force_password_change = False
    elif make_badge_only is False and not user.has_password:
        new_password = data.get("new_password", "").strip()
        if len(new_password) < 6:
            return jsonify({"error": "Set a password (min 6 characters) to turn this into a normal login."}), 400
        user.set_password(new_password)
        password_already_set = True

    if new_role in Role.ALL:
        user.role = new_role
    user.is_active = bool(new_is_active)
    if make_badge_only is not True:
        user.force_password_change = bool(data.get("force_password_change", user.force_password_change))

    new_password = data.get("new_password", "").strip()
    if new_password and user.has_password and make_badge_only is not True and not password_already_set:
        if len(new_password) < 6:
            return jsonify({"error": "Password must be at least 6 characters."}), 400
        user.set_password(new_password)

    log_action(AuditAction.USER_UPDATED, "user", user.id, user.username,
               f"User '{user.username}' updated by {current_user.username}", user=current_user)
    db.session.commit()
    return jsonify(user.to_dict()), 200


@api_users_bp.route("/<int:user_id>", methods=["DELETE"])
@jwt_required()
@admin_required
def delete_user(user_id):
    user = User.query.get_or_404(user_id)
    if user.id == current_user.id:
        return jsonify({"error": "You cannot delete your own account."}), 400

    if user.role == Role.ADMIN and user.is_active and _active_admin_count(exclude_user_id=user.id) == 0:
        return jsonify({"error": "Cannot delete the last remaining admin account."}), 409

    has_checked_out_tools = Tool.query.filter_by(checked_out_by_id=user.id).first() is not None
    if has_checked_out_tools:
        return jsonify({"error": "This user currently has tools checked out. Check the tools back in before deleting the account."}), 409

    has_history = ToolHistory.query.filter_by(user_id=user.id).first() is not None
    if has_history:
        user.is_active = False
        log_action(AuditAction.USER_UPDATED, "user", user.id, user.username,
                   f"User '{user.username}' deactivated (has history) by {current_user.username}", user=current_user)
        db.session.commit()
        return jsonify({"message": f"User '{user.username}' has activity history, so the account was disabled rather than deleted."}), 200

    log_action(AuditAction.USER_DELETED, "user", user.id, user.username,
               f"User '{user.username}' deleted by {current_user.username}", user=current_user)
    db.session.delete(user)
    db.session.commit()
    return jsonify({"message": f"User '{user.username}' deleted."}), 200
