import secrets
import string
from datetime import datetime, timedelta

from flask import Blueprint, render_template, redirect, url_for, request, flash, abort
from flask_login import login_required, current_user
from email_validator import validate_email, EmailNotValidError

from app.extensions import db
from app.models import (
    Instance, Company, UpdateDeployment, UpdatePackage, User, PlatformSetting, log_action,
    CompanyMembership, COMPANY_ROLES, gen_token,
    ClientUser, ClientInstanceAccess, ClientActionLog,
    ChangeRequest, CHANGE_REQUEST_STATUSES,
)
from app.platform_auth import platform_admin_required
from app.datetime_utils import group_by_month_week
from app.long_poll import long_poll_response

bp = Blueprint("platform", __name__, url_prefix="/admin")


@bp.route("/dashboard")
@login_required
@platform_admin_required
def dashboard():
    """Cross-company overview for OpsLab staff (spec Section 39) — the
    company-scoped equivalent lives on each company's instances page."""
    day_ago = datetime.utcnow() - timedelta(hours=24)

    instances = Instance.query.all()
    stats = {
        "total_companies": Company.query.count(),
        "total_kiosks": len(instances),
        "online": sum(1 for i in instances if i.connection_status == "online"),
        "offline": sum(1 for i in instances if i.connection_status == "offline"),
        "updating": sum(1 for i in instances if i.active_deployment() is not None),
        "failed_24h": UpdateDeployment.query.filter(
            UpdateDeployment.status.in_(["failed", "rolled_back"]),
            UpdateDeployment.completed_at >= day_ago,
        ).count(),
        "successful_24h": UpdateDeployment.query.filter(
            UpdateDeployment.status == "successful",
            UpdateDeployment.completed_at >= day_ago,
        ).count(),
        "total_packages": UpdatePackage.query.count(),
    }

    recent_deployments = UpdateDeployment.query.filter(
        UpdateDeployment.status.in_(["successful", "failed", "rolled_back"])
    ).order_by(UpdateDeployment.completed_at.desc()).limit(300).all()

    successful_deployments = [d for d in recent_deployments if d.status == "successful"]
    failed_deployments = [d for d in recent_deployments if d.status != "successful"]

    by_completed_at = lambda d: d.completed_at
    outcome_groups = {
        "all": group_by_month_week(recent_deployments, by_completed_at),
        "successful": group_by_month_week(successful_deployments, by_completed_at),
        "failed": group_by_month_week(failed_deployments, by_completed_at),
    }
    outcome_counts = {
        "all": len(recent_deployments),
        "successful": len(successful_deployments),
        "failed": len(failed_deployments),
    }

    return render_template(
        "platform/dashboard.html", stats=stats,
        outcome_groups=outcome_groups, outcome_counts=outcome_counts,
    )


@bp.route("/dashboard/status")
@login_required
@platform_admin_required
def dashboard_status():
    """Long-polled from the Platform overview page (see app/long_poll.py)
    so the stat tiles reflect a fleet-wide change — an instance going on/
    offline, an update completing anywhere — without a manual refresh."""
    def build_payload():
        day_ago = datetime.utcnow() - timedelta(hours=24)
        instances = Instance.query.all()
        return {
            "total_companies": Company.query.count(),
            "total_kiosks": len(instances),
            "online": sum(1 for i in instances if i.connection_status == "online"),
            "offline": sum(1 for i in instances if i.connection_status == "offline"),
            "updating": sum(1 for i in instances if i.active_deployment() is not None),
            "failed_24h": UpdateDeployment.query.filter(
                UpdateDeployment.status.in_(["failed", "rolled_back"]),
                UpdateDeployment.completed_at >= day_ago,
            ).count(),
            "successful_24h": UpdateDeployment.query.filter(
                UpdateDeployment.status == "successful",
                UpdateDeployment.completed_at >= day_ago,
            ).count(),
            "total_packages": UpdatePackage.query.count(),
        }

    return long_poll_response(build_payload)


@bp.route("/users")
@login_required
@platform_admin_required
def list_users():
    q = request.args.get("q", "").strip()
    query = User.query.filter_by(is_service_account=False)
    if q:
        like = f"%{q}%"
        query = query.filter(db.or_(User.email.ilike(like), User.full_name.ilike(like)))
    users = query.order_by(User.created_at.desc()).all()
    return render_template(
        "platform/users.html", users=users, q=q, settings=PlatformSetting.get()
    )


@bp.route("/users/new", methods=["GET", "POST"])
@login_required
@platform_admin_required
def new_user():
    if request.method == "POST":
        full_name = request.form.get("full_name", "").strip()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        grant_admin = bool(request.form.get("platform_admin"))

        errors = []
        if not full_name:
            errors.append("Full name is required.")
        try:
            email = validate_email(email, check_deliverability=False).normalized
        except EmailNotValidError as e:
            errors.append(str(e))
        if len(password) < 10:
            errors.append("Password must be at least 10 characters.")
        if not errors and User.query.filter_by(email=email).first() is not None:
            errors.append("An account with that email already exists.")

        if errors:
            for e in errors:
                flash(e, "danger")
            return render_template("platform/user_new.html", full_name=full_name, email=email)

        user = User(
            email=email, full_name=full_name,
            email_verified=True,  # admin-created accounts skip the verification email
            is_platform_admin=grant_admin,
        )
        user.set_password(password)
        db.session.add(user)
        log_action(None, current_user, "user_created_by_admin", f"{email}" + (" (platform admin)" if grant_admin else ""))
        db.session.commit()

        flash(f"Account created for {email}.", "success")
        return redirect(url_for("platform.user_detail", user_id=user.public_id))

    return render_template("platform/user_new.html")


@bp.route("/users/<user_id>")
@login_required
@platform_admin_required
def user_detail(user_id):
    user = User.query.filter_by(public_id=user_id).first()
    if user is None:
        abort(404)
    memberships = sorted(user.memberships, key=lambda m: m.company.name.lower())
    member_company_ids = {m.company_id for m in user.memberships}
    available_companies = sorted(
        (c for c in Company.query.all() if c.id not in member_company_ids),
        key=lambda c: c.name.lower(),
    )
    return render_template(
        "platform/user_detail.html", user=user, memberships=memberships,
        available_companies=available_companies,
    )


@bp.route("/users/<user_id>/memberships/add", methods=["POST"])
@login_required
@platform_admin_required
def add_membership(user_id):
    """Adds a user directly to a company with a given role — skips the
    email-invite flow entirely (see companies.py's invite_member), since
    a platform admin acting here already has the authority to make this
    call without the invited person's own confirmation step. Useful for
    onboarding or support situations where waiting on an email
    round-trip isn't practical."""
    user = User.query.filter_by(public_id=user_id).first()
    if user is None:
        abort(404)

    company = Company.query.filter_by(public_id=request.form.get("company_id", "")).first()
    role = request.form.get("role", "operator")

    if company is None:
        flash("Choose a company.", "danger")
    elif role not in COMPANY_ROLES:
        flash("Invalid role.", "danger")
    elif user.role_in(company.id) is not None:
        flash(f"{user.email} is already a member of {company.name}.", "warning")
    else:
        db.session.add(CompanyMembership(user_id=user.id, company_id=company.id, role=role))
        log_action(company, current_user, "member_added_by_platform_admin", f"{user.email} as {role}")
        db.session.commit()
        flash(f"Added {user.email} to {company.name} as {role}.", "success")

    return redirect(url_for("platform.user_detail", user_id=user.public_id))


@bp.route("/users/<user_id>/memberships/<int:membership_id>/remove", methods=["POST"])
@login_required
@platform_admin_required
def remove_membership(user_id, membership_id):
    user = User.query.filter_by(public_id=user_id).first()
    if user is None:
        abort(404)
    membership = CompanyMembership.query.filter_by(id=membership_id, user_id=user.id).first()
    if membership is None:
        abort(404)

    if membership.role == "owner":
        remaining_owners = CompanyMembership.query.filter_by(
            company_id=membership.company_id, role="owner"
        ).count()
        if remaining_owners <= 1:
            flash("Can't remove the last owner of a company — promote someone else there first.", "danger")
            return redirect(url_for("platform.user_detail", user_id=user.public_id))

    company_name = membership.company.name
    log_action(membership.company, current_user, "member_removed_by_platform_admin", f"{user.email} ({membership.role})")
    db.session.delete(membership)
    db.session.commit()
    flash(f"Removed {user.email} from {company_name}.", "info")
    return redirect(url_for("platform.user_detail", user_id=user.public_id))


@bp.route("/users/<user_id>/toggle-active", methods=["POST"])
@login_required
@platform_admin_required
def toggle_active(user_id):
    user = User.query.filter_by(public_id=user_id).first()
    if user is None:
        abort(404)
    if user.id == current_user.id:
        flash("You can't disable your own account. Ask another platform admin to do it.", "danger")
        return redirect(url_for("platform.user_detail", user_id=user.public_id))

    user.is_active = not user.is_active
    log_action(None, current_user, "user_" + ("enabled" if user.is_active else "disabled"), user.email)
    db.session.commit()
    flash(f"{user.email} is now " + ("active." if user.is_active else "disabled."), "success")
    return redirect(url_for("platform.user_detail", user_id=user.public_id))


@bp.route("/users/<user_id>/toggle-admin", methods=["POST"])
@login_required
@platform_admin_required
def toggle_admin(user_id):
    user = User.query.filter_by(public_id=user_id).first()
    if user is None:
        abort(404)
    if user.id == current_user.id:
        flash("You can't change your own platform-admin access. Ask another platform admin to do it.", "danger")
        return redirect(url_for("platform.user_detail", user_id=user.public_id))

    if user.is_platform_admin:
        other_admins = User.query.filter(User.is_platform_admin == True, User.id != user.id).count()  # noqa: E712
        if other_admins == 0:
            flash("Can't revoke the last remaining platform admin.", "danger")
            return redirect(url_for("platform.user_detail", user_id=user.public_id))

    user.is_platform_admin = not user.is_platform_admin
    log_action(None, current_user, "user_platform_admin_" + ("granted" if user.is_platform_admin else "revoked"), user.email)
    db.session.commit()
    flash(f"{user.email} is now " + ("a platform admin." if user.is_platform_admin else "no longer a platform admin."), "success")
    return redirect(url_for("platform.user_detail", user_id=user.public_id))


@bp.route("/users/<user_id>/reset-password", methods=["POST"])
@login_required
@platform_admin_required
def reset_password(user_id):
    user = User.query.filter_by(public_id=user_id).first()
    if user is None:
        abort(404)

    # Human-typeable temp password (gen_token's url-safe alphabet includes
    # -/_ which are easy to mis-transcribe when read aloud or over chat).
    alphabet = string.ascii_letters + string.digits
    temp_password = "".join(secrets.choice(alphabet) for _ in range(16))

    user.set_password(temp_password)
    log_action(None, current_user, "user_password_reset_by_platform_admin", user.email)
    db.session.commit()
    flash(
        f"Password for {user.email} reset. Temporary password (shown once): {temp_password}",
        "success",
    )
    return redirect(url_for("platform.user_detail", user_id=user.public_id))


@bp.route("/users/<user_id>/verify-email", methods=["POST"])
@login_required
@platform_admin_required
def verify_email_manual(user_id):
    user = User.query.filter_by(public_id=user_id).first()
    if user is None:
        abort(404)
    user.email_verified = True
    log_action(None, current_user, "user_email_verified_by_admin", user.email)
    db.session.commit()
    flash(f"{user.email} marked as verified.", "success")
    return redirect(url_for("platform.user_detail", user_id=user.public_id))


@bp.route("/settings/toggle-signups", methods=["POST"])
@login_required
@platform_admin_required
def toggle_signups():
    settings = PlatformSetting.get()
    settings.signups_enabled = not settings.signups_enabled
    log_action(None, current_user, "signups_" + ("enabled" if settings.signups_enabled else "disabled"))
    db.session.commit()
    flash("Public signup is now " + ("open." if settings.signups_enabled else "closed."), "success")
    return redirect(url_for("platform.list_users"))


@bp.route("/settings/client-portal-timeout", methods=["POST"])
@login_required
@platform_admin_required
def set_client_portal_timeout():
    """The Client Portal's idle-logout duration (see client_portal/
    _base.html's JS) — platform-wide, since a ClientUser isn't scoped to
    one company. The real kiosk terminal has its own separate per-instance
    setting for the same idea (instances.py's set_auto_logout)."""
    settings = PlatformSetting.get()
    try:
        minutes = int(request.form.get("minutes", "").strip())
    except ValueError:
        flash("Enter a whole number of minutes.", "danger")
        return redirect(url_for("platform.list_users"))
    if minutes < 1:
        flash("Timeout must be at least 1 minute.", "danger")
        return redirect(url_for("platform.list_users"))
    settings.client_portal_auto_logout_minutes = minutes
    log_action(None, current_user, "client_portal_timeout_changed", f"{minutes} minutes")
    db.session.commit()
    flash(f"Client Portal idle timeout set to {minutes} minute(s).", "success")
    return redirect(url_for("platform.list_users"))


# ---------------------------------------------------------------------------
# Clients (Client Portal): self-signed-up ClientUser accounts, outside the
# Company/CompanyMembership system entirely — see models.py's "Client
# Portal" section. Managed here, platform-wide, since a client isn't scoped
# to any one company: a platform admin assigns each one to whichever
# specific instance(s) they should be able to operate.
# ---------------------------------------------------------------------------

@bp.route("/clients")
@login_required
@platform_admin_required
def list_clients():
    q = request.args.get("q", "").strip()
    query = ClientUser.query
    if q:
        like = f"%{q}%"
        query = query.filter(db.or_(ClientUser.email.ilike(like), ClientUser.full_name.ilike(like)))
    clients = query.order_by(ClientUser.created_at.desc()).all()
    assignment_counts = dict(
        db.session.query(ClientInstanceAccess.client_user_id, db.func.count(ClientInstanceAccess.id))
        .group_by(ClientInstanceAccess.client_user_id).all()
    )
    return render_template("platform/clients.html", clients=clients, q=q, assignment_counts=assignment_counts)


@bp.route("/clients/<client_id>")
@login_required
@platform_admin_required
def client_detail(client_id):
    client = ClientUser.query.filter_by(public_id=client_id).first()
    if client is None:
        abort(404)
    assigned_instance_ids = {a.instance_id for a in client.assignments}
    available_instances = sorted(
        (i for i in Instance.query.all() if i.id not in assigned_instance_ids),
        key=lambda i: (i.company.name.lower(), i.display_name().lower()),
    )
    recent_activity = ClientActionLog.query.filter_by(client_user_id=client.id).order_by(
        ClientActionLog.created_at.desc()
    ).limit(30).all()
    return render_template(
        "platform/client_detail.html", client=client,
        assignments=sorted(client.assignments, key=lambda a: a.instance.display_name().lower()),
        available_instances=available_instances, recent_activity=recent_activity,
    )


@bp.route("/clients/<client_id>/assign", methods=["POST"])
@login_required
@platform_admin_required
def assign_client_instance(client_id):
    client = ClientUser.query.filter_by(public_id=client_id).first()
    if client is None:
        abort(404)
    instance = Instance.query.filter_by(public_id=request.form.get("instance_id", "")).first()

    if instance is None:
        flash("Choose an instance.", "danger")
    elif client.has_access(instance):
        flash(f"{client.email} already has access to {instance.display_name()}.", "warning")
    else:
        db.session.add(ClientInstanceAccess(
            client_user_id=client.id, instance_id=instance.id, granted_by_id=current_user.id,
        ))
        log_action(instance.company, current_user, "client_assigned_to_instance",
                   f"{client.email} -> {instance.display_name()}")
        db.session.commit()
        flash(f"Assigned {client.email} to {instance.display_name()}.", "success")

    return redirect(url_for("platform.client_detail", client_id=client.public_id))


@bp.route("/clients/<client_id>/assignments/<int:assignment_id>/revoke", methods=["POST"])
@login_required
@platform_admin_required
def revoke_client_instance(client_id, assignment_id):
    client = ClientUser.query.filter_by(public_id=client_id).first()
    if client is None:
        abort(404)
    assignment = ClientInstanceAccess.query.filter_by(id=assignment_id, client_user_id=client.id).first()
    if assignment is None:
        abort(404)

    instance_name = assignment.instance.display_name()
    log_action(assignment.instance.company, current_user, "client_instance_access_revoked",
               f"{client.email} -> {instance_name}")
    db.session.delete(assignment)
    db.session.commit()
    flash(f"Revoked {client.email}'s access to {instance_name}.", "info")
    return redirect(url_for("platform.client_detail", client_id=client.public_id))


@bp.route("/clients/<client_id>/reset-password", methods=["POST"])
@login_required
@platform_admin_required
def reset_client_password(client_id):
    """Client-user twin of reset_password above (staff Users) — same
    generate-and-show-once temp password pattern, for when a customer's
    own contact is locked out and needs a platform admin to get them back
    in rather than waiting on the (currently staff-only) forgot-password
    email flow."""
    client = ClientUser.query.filter_by(public_id=client_id).first()
    if client is None:
        abort(404)

    alphabet = string.ascii_letters + string.digits
    temp_password = "".join(secrets.choice(alphabet) for _ in range(16))

    client.set_password(temp_password)
    log_action(None, current_user, "client_password_reset_by_platform_admin", client.email)
    db.session.commit()
    flash(
        f"Password for {client.email} reset. Temporary password (shown once): {temp_password}",
        "success",
    )
    return redirect(url_for("platform.client_detail", client_id=client.public_id))


@bp.route("/clients/<client_id>/toggle-active", methods=["POST"])
@login_required
@platform_admin_required
def toggle_client_active(client_id):
    client = ClientUser.query.filter_by(public_id=client_id).first()
    if client is None:
        abort(404)
    client.is_active = not client.is_active
    log_action(None, current_user, "client_" + ("enabled" if client.is_active else "disabled"), client.email)
    db.session.commit()
    flash(f"{client.email} is now " + ("active." if client.is_active else "disabled."), "success")
    return redirect(url_for("platform.client_detail", client_id=client.public_id))


# --- Change requests (client-submitted requests for a future update/change) -

@bp.route("/change-requests")
@login_required
@platform_admin_required
def list_change_requests():
    all_requests = ChangeRequest.query.order_by(ChangeRequest.created_at.desc()).all()
    request_groups = {"all": all_requests}
    for status in CHANGE_REQUEST_STATUSES:
        request_groups[status] = [r for r in all_requests if r.status == status]
    request_counts = {key: len(rows) for key, rows in request_groups.items()}
    return render_template(
        "platform/change_requests.html",
        request_groups=request_groups, request_counts=request_counts,
    )


@bp.route("/change-requests/status")
@login_required
@platform_admin_required
def change_requests_status():
    """Long-polled from the Change requests page's tab counts (see
    app/long_poll.py) — a client submitting a new request or another
    admin responding to one shows up in the badges live."""
    def build_payload():
        all_requests = ChangeRequest.query.all()
        counts = {"all": len(all_requests)}
        for status in CHANGE_REQUEST_STATUSES:
            counts[status] = sum(1 for r in all_requests if r.status == status)
        return counts

    return long_poll_response(build_payload)


@bp.route("/change-requests/<request_id>/respond", methods=["POST"])
@login_required
@platform_admin_required
def respond_change_request(request_id):
    req = ChangeRequest.query.filter_by(public_id=request_id).first()
    if req is None:
        abort(404)
    status = request.form.get("status", "").strip()
    if status not in CHANGE_REQUEST_STATUSES:
        abort(400)

    req.status = status
    req.admin_response = (request.form.get("admin_response") or "").strip() or None
    req.resolved_by_id = current_user.id
    req.resolved_at = datetime.utcnow()
    log_action(req.instance.company, current_user, "change_request_updated", f"{req.title} -> {status}")
    db.session.commit()
    flash("Request updated.", "success")
    return redirect(url_for("platform.list_change_requests"))
