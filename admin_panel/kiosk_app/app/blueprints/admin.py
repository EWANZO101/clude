from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash
from flask_login import login_required, current_user

from app.extensions import db
from app.models import LocalUser, Role, AuditLogEntry, SIDEBAR_ITEMS, gen_badge_code, ActivityFlag
from app.permissions import require_admin_role, ADMIN_ROLES
from app import role_admin

bp = Blueprint("admin", __name__, url_prefix="/admin")


def _audit(action: str, target: str = None, detail: str = None):
    db.session.add(AuditLogEntry(actor=current_user.username, action=action, target=target, detail=detail))


def _admin_capable_active_count(exclude_user_id: int = None) -> int:
    q = LocalUser.query.filter(LocalUser.role.in_(ADMIN_ROLES), LocalUser.is_active.is_(True))
    if exclude_user_id is not None:
        q = q.filter(LocalUser.id != exclude_user_id)
    return q.count()


@bp.before_request
@login_required
@require_admin_role
def _guard():
    return None


@bp.route("/")
def index():
    return render_template(
        "admin/index.html",
        user_count=LocalUser.query.count(),
        role_count=len(Role.all_role_names()),
        recent_audit=AuditLogEntry.query.order_by(AuditLogEntry.created_at.desc()).limit(5).all(),
        unresolved_flag_count=ActivityFlag.query.filter_by(resolved_at=None).count(),
    )


# ---------------------------------------------------------------------------
# Flagged activity (from the login-time "is this all you?" review)
# ---------------------------------------------------------------------------

@bp.route("/flagged-activity")
def flagged_activity():
    unresolved = ActivityFlag.query.filter_by(resolved_at=None).order_by(ActivityFlag.created_at.desc()).all()
    resolved = ActivityFlag.query.filter(ActivityFlag.resolved_at.isnot(None)).order_by(
        ActivityFlag.resolved_at.desc()
    ).limit(30).all()
    return render_template("admin/flagged_activity.html", unresolved=unresolved, resolved=resolved)


@bp.route("/flagged-activity/<int:flag_id>/resolve", methods=["POST"])
def resolve_flag(flag_id):
    flag = ActivityFlag.query.get_or_404(flag_id)
    flag.resolved_at = datetime.utcnow()
    flag.resolved_by_id = current_user.id
    _audit("activity_flag_resolved", target=flag.activity_event.entity_name if flag.activity_event else None)
    db.session.commit()
    flash("Marked resolved.", "success")
    return redirect(url_for("admin.flagged_activity"))


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

@bp.route("/users")
def list_users():
    users = LocalUser.query.order_by(LocalUser.username).all()
    return render_template("admin/users_list.html", users=users)


@bp.route("/users/add", methods=["GET", "POST"])
def add_user():
    roles = Role.all_role_names()
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        role = request.form.get("role", "").strip()

        if not username:
            flash("Username is required.", "danger")
            return render_template("admin/users_add.html", roles=roles)
        if LocalUser.query.filter_by(username=username).first() is not None:
            flash(f"Username '{username}' is already taken.", "danger")
            return render_template("admin/users_add.html", roles=roles)
        if role not in roles:
            flash("Choose a valid role.", "danger")
            return render_template("admin/users_add.html", roles=roles)

        badge_code = request.form.get("badge_code", "").strip() or gen_badge_code()
        if LocalUser.query.filter_by(badge_code=badge_code).first() is not None:
            flash(f"Badge code '{badge_code}' is already in use.", "danger")
            return render_template("admin/users_add.html", roles=roles)

        user = LocalUser(username=username, role=role, badge_code=badge_code)
        password = request.form.get("password", "")
        if password:
            user.set_password(password)
        db.session.add(user)
        _audit("user_create", target=username, detail=f"role={role}")
        db.session.commit()

        flash(f"User '{username}' created (badge {badge_code}).", "success")
        return redirect(url_for("admin.list_users"))

    return render_template("admin/users_add.html", roles=roles)


@bp.route("/users/<int:user_id>/edit", methods=["GET", "POST"])
def edit_user(user_id):
    user = LocalUser.query.get_or_404(user_id)
    roles = Role.all_role_names()
    if request.method == "POST":
        new_role = request.form.get("role", user.role)
        if new_role not in roles:
            flash("Choose a valid role.", "danger")
            return render_template("admin/users_edit.html", user=user, roles=roles)

        # Guard found while testing: changing the kiosk's only active
        # admin-capable account to a non-admin role leaves nobody able to
        # reach this panel to undo it — same "don't let the last one go"
        # shape as the tool/project delete guards elsewhere in this app.
        losing_admin_access = user.role in ADMIN_ROLES and new_role not in ADMIN_ROLES and user.is_active
        if losing_admin_access and _admin_capable_active_count(exclude_user_id=user.id) == 0:
            flash("Can't change this user's role — they're the last active admin-capable account.", "danger")
            return render_template("admin/users_edit.html", user=user, roles=roles)

        old_role = user.role
        user.role = new_role
        if old_role != new_role:
            _audit("user_role_change", target=user.username, detail=f"{old_role} -> {new_role}")
        db.session.commit()
        flash("User updated.", "success")
        return redirect(url_for("admin.list_users"))

    return render_template("admin/users_edit.html", user=user, roles=roles)


@bp.route("/users/<int:user_id>/deactivate", methods=["POST"])
def deactivate_user(user_id):
    user = LocalUser.query.get_or_404(user_id)
    if user.role in ADMIN_ROLES and _admin_capable_active_count(exclude_user_id=user.id) == 0:
        flash("Can't deactivate this user — they're the last active admin-capable account.", "danger")
        return redirect(url_for("admin.list_users"))
    user.is_active = False
    _audit("user_deactivate", target=user.username)
    db.session.commit()
    flash(f"'{user.username}' deactivated.", "info")
    return redirect(url_for("admin.list_users"))


@bp.route("/users/<int:user_id>/erase-personal-data", methods=["POST"])
def erase_user_personal_data(user_id):
    """POPIA data subject right to deletion — see LocalUser.erase_personal_data
    for exactly what this does and does not touch."""
    user = LocalUser.query.get_or_404(user_id)
    old_username = user.username
    try:
        user.erase_personal_data()
    except ValueError as e:
        flash(str(e), "danger")
        return redirect(url_for("admin.list_users"))
    _audit("user_personal_data_erased", target=old_username)
    db.session.commit()
    flash(f"Personal data erased for the account formerly '{old_username}'.", "success")
    return redirect(url_for("admin.list_users"))


@bp.route("/users/<int:user_id>/reactivate", methods=["POST"])
def reactivate_user(user_id):
    user = LocalUser.query.get_or_404(user_id)
    user.is_active = True
    _audit("user_reactivate", target=user.username)
    db.session.commit()
    flash(f"'{user.username}' reactivated.", "success")
    return redirect(url_for("admin.list_users"))


@bp.route("/users/<int:user_id>/regenerate-badge", methods=["POST"])
def regenerate_badge(user_id):
    user = LocalUser.query.get_or_404(user_id)
    new_code = gen_badge_code()
    while LocalUser.query.filter_by(badge_code=new_code).first() is not None:
        new_code = gen_badge_code()
    old_code = user.badge_code
    user.badge_code = new_code
    _audit("user_badge_regenerate", target=user.username, detail=f"{old_code} -> {new_code}")
    db.session.commit()
    flash(f"New badge code for '{user.username}': {new_code}", "success")
    return redirect(url_for("admin.list_users"))


@bp.route("/users/<int:user_id>/set-password", methods=["POST"])
def set_password(user_id):
    user = LocalUser.query.get_or_404(user_id)
    password = request.form.get("password", "")
    user.set_password(password)  # empty string clears it back to badge/username-only
    _audit("user_password_set" if password else "user_password_cleared", target=user.username)
    db.session.commit()
    flash(f"Password {'set' if password else 'cleared'} for '{user.username}'.", "success")
    return redirect(url_for("admin.list_users"))


# ---------------------------------------------------------------------------
# Roles, permissions, and the sidebar builder
# ---------------------------------------------------------------------------

@bp.route("/roles")
def list_roles():
    roles = Role.all_role_names()
    counts = {r: LocalUser.query.filter_by(role=r).count() for r in roles}
    custom_names = {r.name for r in Role.query.all()}
    return render_template("admin/roles_list.html", roles=roles, counts=counts, custom_names=custom_names)


@bp.route("/roles/add", methods=["GET", "POST"])
def add_role():
    if request.method == "POST":
        ok, message = role_admin.create_role(
            current_user.username, request.form.get("name", ""), request.form.get("description", ""),
        )
        flash(message, "success" if ok else "danger")
        if ok:
            return redirect(url_for("admin.list_roles"))
        return render_template("admin/roles_add.html")

    return render_template("admin/roles_add.html")


@bp.route("/roles/<role_name>/delete", methods=["POST"])
def delete_role(role_name):
    ok, message = role_admin.delete_role(current_user.username, role_name)
    flash(message, "info" if ok else "danger")
    return redirect(url_for("admin.list_roles"))


@bp.route("/roles/<role_name>", methods=["GET"])
def role_detail(role_name):
    if role_name not in Role.all_role_names():
        flash(f"Unknown role '{role_name}'.", "danger")
        return redirect(url_for("admin.list_roles"))

    state = role_admin.role_state(role_name)
    return render_template(
        "admin/role_detail.html", role_name=role_name, login_enabled=state["login_enabled"],
        sidebar_items=SIDEBAR_ITEMS, sidebar_state=state["sidebar"],
        is_baseline=state["is_builtin"],
    )


@bp.route("/roles/<role_name>/login-toggle", methods=["POST"])
def toggle_role_login(role_name):
    enabled = request.form.get("login_enabled") == "on"
    ok, message = role_admin.set_role_login(current_user.username, role_name, enabled)
    flash(message, "success" if ok else "danger")
    return redirect(url_for("admin.role_detail", role_name=role_name))


@bp.route("/roles/<role_name>/sidebar", methods=["POST"])
def update_sidebar(role_name):
    visibility = {key: request.form.get(f"item_{key}") == "on" for key, _, _ in SIDEBAR_ITEMS}
    ok, message = role_admin.set_role_sidebar(current_user.username, role_name, visibility)
    flash(message, "success" if ok else "danger")
    return redirect(url_for("admin.role_detail", role_name=role_name))


# ---------------------------------------------------------------------------
# Sidebar builder (Track 2 — see /root/.claude/plans/sprightly-meandering-
# whisper.md). Drag-and-drop reorder of every NavEntry, standing right at
# the terminal; the exact same nav_admin.reorder() is also reachable
# remotely via sync_api.py's /api/sync/sidebar/reorder, relayed by the
# Agent's sidebar_reorder command.
# ---------------------------------------------------------------------------

@bp.route("/sidebar")
def sidebar_builder():
    from app import nav_admin
    return render_template("admin/sidebar.html", nav_entries=nav_admin.get_state())


@bp.route("/sidebar/reorder", methods=["POST"])
def reorder_sidebar():
    from app import nav_admin
    order = [k.strip() for k in request.form.get("order", "").split(",") if k.strip()]
    ok, message = nav_admin.reorder(current_user.username, order)
    flash(message, "success" if ok else "danger")
    return redirect(url_for("admin.sidebar_builder"))


# ---------------------------------------------------------------------------
# Privacy & data retention (POPIA) — see app/retention.py and
# app/templates/privacy_notice.html (the public-facing notice, unauthenticated,
# linked from the login page) for the rest of this story.
# ---------------------------------------------------------------------------

@bp.route("/privacy")
def privacy_admin():
    from app.config import load_agent_config
    from app.retention import MIN_RETENTION_DAYS

    configured_days = load_agent_config().get("activity_log_retention_days")
    return render_template(
        "admin/privacy.html", configured_retention_days=configured_days, min_retention_days=MIN_RETENTION_DAYS,
    )


@bp.route("/privacy/purge", methods=["POST"])
def purge_personal_data():
    from app.retention import purge_older_than, MIN_RETENTION_DAYS

    raw_days = request.form.get("days", "").strip()
    try:
        days = int(raw_days)
    except ValueError:
        flash("Enter a whole number of days.", "danger")
        return redirect(url_for("admin.privacy_admin"))
    if days < MIN_RETENTION_DAYS:
        flash(f"Retention window must be at least {MIN_RETENTION_DAYS} days.", "danger")
        return redirect(url_for("admin.privacy_admin"))

    counts = purge_older_than(days)
    _audit("personal_data_purge", detail=f"older than {days}d: {counts}")
    db.session.commit()
    flash(f"Purged {sum(counts.values())} record(s) older than {days} days: {counts}", "success")
    return redirect(url_for("admin.privacy_admin"))


# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------

@bp.route("/audit")
def audit_log():
    action = request.args.get("action", "")
    query = AuditLogEntry.query
    if action:
        query = query.filter_by(action=action)
    entries = query.order_by(AuditLogEntry.created_at.desc()).limit(200).all()
    all_actions = sorted({row[0] for row in db.session.query(AuditLogEntry.action).distinct().all()})
    return render_template("admin/audit_log.html", entries=entries, all_actions=all_actions, action=action)
