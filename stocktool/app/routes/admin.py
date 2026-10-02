from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_required, current_user
from app.extensions import db
from app.models.user import User, Role
from app.models.tool import Tool
from app.models.tool_history import ToolHistory
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action
from app.utils.barcode_helper import generate_barcode

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")


def _active_admin_count(exclude_user_id=None):
    query = User.query.filter_by(role=Role.ADMIN, is_active=True)
    if exclude_user_id is not None:
        query = query.filter(User.id != exclude_user_id)
    return query.count()


@admin_bp.route("/")
@login_required
@admin_required
def index():
    users = User.query.order_by(User.created_at.desc()).all()
    return render_template("admin/index.html", users=users)


@admin_bp.route("/users/add", methods=["GET", "POST"])
@login_required
@admin_required
def add_user():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        email = request.form.get("email", "").strip()
        password = request.form.get("password", "")
        role = request.form.get("role", Role.STOCK_USER)
        force_change = request.form.get("force_password_change") == "on"

        errors = []
        if not username:
            errors.append("Username is required.")
        if not email:
            errors.append("Email is required.")
        if len(password) < 6:
            errors.append("Password must be at least 6 characters.")
        if role not in Role.ALL:
            errors.append("Invalid role.")
        if User.query.filter_by(username=username).first():
            errors.append(f"Username '{username}' already exists.")
        if User.query.filter_by(email=email).first():
            errors.append(f"Email '{email}' already exists.")

        if errors:
            for e in errors:
                flash(e, "danger")
            return render_template("admin/user_form.html", user=None,
                                   action="Add", Role=Role)

        user = User(username=username, email=email, role=role,
                    force_password_change=force_change)
        user.set_password(password)
        db.session.add(user)
        db.session.flush()

        generate_barcode("user", user.id)

        log_action(AuditAction.USER_CREATED, "user", user.id, user.username,
                   f"User '{user.username}' created by {current_user.username}")
        db.session.commit()
        flash(f"User '{username}' created.", "success")
        return redirect(url_for("admin.index"))

    return render_template("admin/user_form.html", user=None, action="Add", Role=Role)


@admin_bp.route("/users/<int:user_id>/edit", methods=["GET", "POST"])
@login_required
@admin_required
def edit_user(user_id):
    user = User.query.get_or_404(user_id)

    if request.method == "POST":
        new_role = request.form.get("role", user.role)
        new_is_active = request.form.get("is_active") == "on"

        # Guard against locking the system out of all admin accounts by
        # demoting or deactivating the last remaining active admin.
        was_active_admin = user.role == Role.ADMIN and user.is_active
        will_stay_admin = new_role == Role.ADMIN and new_is_active
        if was_active_admin and not will_stay_admin and _active_admin_count(exclude_user_id=user.id) == 0:
            flash("Cannot remove admin rights or disable the last remaining admin account.", "danger")
            return render_template("admin/user_form.html", user=user, action="Edit", Role=Role)

        user.email = request.form.get("email", user.email).strip()
        if new_role in Role.ALL:
            user.role = new_role
        user.is_active = new_is_active
        user.force_password_change = request.form.get("force_password_change") == "on"

        new_password = request.form.get("new_password", "").strip()
        if new_password:
            if len(new_password) < 6:
                flash("Password must be at least 6 characters.", "danger")
                return render_template("admin/user_form.html", user=user,
                                       action="Edit", Role=Role)
            user.set_password(new_password)

        log_action(AuditAction.USER_UPDATED, "user", user.id, user.username,
                   f"User '{user.username}' updated by {current_user.username}")
        db.session.commit()
        flash(f"User '{user.username}' updated.", "success")
        return redirect(url_for("admin.index"))

    return render_template("admin/user_form.html", user=user, action="Edit", Role=Role)


@admin_bp.route("/users/<int:user_id>/delete", methods=["POST"])
@login_required
@admin_required
def delete_user(user_id):
    user = User.query.get_or_404(user_id)
    if user.id == current_user.id:
        flash("You cannot delete your own account.", "danger")
        return redirect(url_for("admin.index"))

    if user.role == Role.ADMIN and user.is_active and _active_admin_count(exclude_user_id=user.id) == 0:
        flash("Cannot delete the last remaining admin account.", "danger")
        return redirect(url_for("admin.index"))

    has_checked_out_tools = Tool.query.filter_by(checked_out_by_id=user.id).first() is not None
    if has_checked_out_tools:
        flash("This user currently has tools checked out. Check the tools back in before deleting the account.", "danger")
        return redirect(url_for("admin.index"))

    # If this user has existing tool-history or audit-log entries, hard
    # deleting the row would leave those records pointing at a user that no
    # longer exists (a dangling foreign key) and break pages that display
    # who performed a given action. Deactivate instead so the audit trail
    # stays intact; only remove the row outright when there's no history.
    has_history = ToolHistory.query.filter_by(user_id=user.id).first() is not None

    if has_history:
        user.is_active = False
        log_action(AuditAction.USER_UPDATED, "user", user.id, user.username,
                   f"User '{user.username}' deactivated (has history) by {current_user.username}")
        db.session.commit()
        flash(f"User '{user.username}' has activity history, so the account was disabled rather than deleted.", "info")
        return redirect(url_for("admin.index"))

    log_action(AuditAction.USER_DELETED, "user", user.id, user.username,
               f"User '{user.username}' deleted by {current_user.username}")
    db.session.delete(user)
    db.session.commit()
    flash(f"User '{user.username}' deleted.", "info")
    return redirect(url_for("admin.index"))
