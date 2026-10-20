from flask import Blueprint, abort, current_app, g, redirect, render_template, request, url_for
from flask_login import current_user

from . import tenancy
from .audit import log_audit
from .extensions import db
from .models import AuditLog, Community, Settings, User

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")


@admin_bp.before_request
def require_admin():
    if not current_user.is_authenticated:
        return redirect(url_for("auth.login", next=request.path))
    if not current_user.is_admin:
        abort(403)
    if g.tenant is not None:
        return redirect(url_for("views.dashboard"))


@admin_bp.route("/settings", methods=["GET", "POST"])
def settings():
    row = Settings.get()
    saved = False
    if request.method == "POST":
        mode = request.form.get("signup_mode")
        if mode in ("open", "invite", "approval"):
            row.signup_mode = mode
        row.invite_code = (request.form.get("invite_code") or "").strip()[:128]
        row.discord_webhook_url = (request.form.get("discord_webhook_url") or "").strip()[:512]
        row.discord_notify_evidence = bool(request.form.get("discord_notify_evidence"))
        row.discord_notify_alerts = bool(request.form.get("discord_notify_alerts"))
        row.discord_notify_bolos = bool(request.form.get("discord_notify_bolos"))
        log_audit("settings.update", f"signup_mode={row.signup_mode}")
        db.session.commit()
        saved = True
    return render_template("admin_settings.html", settings=row, saved=saved)


@admin_bp.route("/users")
def users():
    all_users = User.query.order_by(User.created_at.asc()).all()
    return render_template("admin_users.html", users=all_users)


@admin_bp.route("/users/<int:user_id>/approve", methods=["POST"])
def approve_user(user_id):
    user = User.query.get_or_404(user_id)
    user.is_active_account = True
    log_audit("user.approve", f"approved {user.username}")
    db.session.commit()
    return redirect(url_for("admin.users"))


@admin_bp.route("/users/<int:user_id>/toggle-active", methods=["POST"])
def toggle_active(user_id):
    user = User.query.get_or_404(user_id)
    if user.id == current_user.id:
        abort(400)
    user.is_active_account = not user.is_active_account
    log_audit("user.toggle_active", f"{'enabled' if user.is_active_account else 'disabled'} {user.username}")
    db.session.commit()
    return redirect(url_for("admin.users"))


@admin_bp.route("/users/<int:user_id>/role", methods=["POST"])
def change_role(user_id):
    user = User.query.get_or_404(user_id)
    if user.id == current_user.id:
        abort(400)
    new_role = request.form.get("role")
    if new_role in ("admin", "supervisor", "officer"):
        log_audit("user.change_role", f"{user.username}: {user.role} -> {new_role}")
        user.role = new_role
        db.session.commit()
    return redirect(url_for("admin.users"))


@admin_bp.route("/communities", methods=["GET", "POST"])
def communities():
    error = None
    created_token = None

    created_community = None

    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        slug = (request.form.get("slug") or "").strip()
        custom_domain = (request.form.get("custom_domain") or "").strip()
        if not name:
            error = "Name is required."
        else:
            try:
                community = tenancy.create_community(name, requested_slug=slug or None, custom_domain=custom_domain or None)
                created_token = community.api_token
                created_community = community
                log_audit("community.create", f"{community.name} ({community.slug})")
                db.session.commit()
            except tenancy.ProvisioningError as e:
                error = str(e)

    all_communities = Community.query.order_by(Community.created_at.asc()).all()
    return render_template(
        "admin_communities.html",
        communities=all_communities,
        error=error,
        created_token=created_token,
        created_community=created_community,
        mysql_enabled=bool(current_app.config.get("MYSQL_PROVISIONER_PASSWORD")),
        tenant_base_domain=current_app.config.get("TENANT_BASE_DOMAIN", ""),
    )


@admin_bp.route("/communities/<int:community_id>/toggle-phone-app", methods=["POST"])
def toggle_community_phone_app(community_id):
    community = Community.query.get_or_404(community_id)
    community.phone_app_enabled = not community.phone_app_enabled
    log_audit(
        "community.toggle_phone_app",
        f"{'enabled' if community.phone_app_enabled else 'disabled'} phone app for {community.name} ({community.slug})",
    )
    db.session.commit()
    return redirect(url_for("admin.communities"))


@admin_bp.route("/audit-log")
def audit_log():
    entries = AuditLog.query.order_by(AuditLog.created_at.desc()).limit(200).all()
    return render_template("admin_audit_log.html", entries=entries)
