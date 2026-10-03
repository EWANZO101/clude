import json
import csv
import io
from datetime import datetime, timedelta, timezone

from flask import Blueprint, render_template, redirect, url_for, request, flash, g, abort, jsonify, Response, current_app

from app.extensions import db
from app.models import (
    Instance, EnrollmentToken, InstanceConfig, UpdatePackage, UpdateDeployment,
    RemoteAccessToken, AgentErrorReport, log_action, InstanceCommand, StagedRolloutInstance,
    InstanceEquipmentItem, EQUIPMENT_KINDS, EQUIPMENT_STATUSES, EQUIPMENT_CSV_FIELDS,
    EQUIPMENT_CATEGORIES, TOOL_STATUSES,
    InstanceLocalUser, LOCAL_USER_STATUSES, LOCAL_USER_ROLES, is_valid_pin_format, PIN_MIN_LENGTH, PIN_MAX_LENGTH,
    InstanceRole, SIDEBAR_ITEM_KEYS,
    InstanceItemType, InstanceInventoryItem, InstanceNavEntry,
    ChangeRequest, CHANGE_REQUEST_STATUSES,
    ScanToken,
)
from app.rbac import load_company_context, permission_required, require_product_access
from app.update_scheduling import resolve_deployment_target
from app.long_poll import long_poll_response
from app import inventory_admin, measurement
from flask_login import login_required, current_user

bp = Blueprint("instances", __name__, url_prefix="/companies/<company_id>/instances")
bp.before_request(require_product_access("kiosk", "the Kiosk System"))

# Command types that represent the kiosk PROCESS's own lifecycle, as
# opposed to "run_command" (a one-off arbitrary shell command that shares
# the same InstanceCommand queue/status machinery but has nothing to do
# with whether the kiosk process is starting/stopping). Used to scope the
# Kiosk Process panel's "what's currently in flight" query so an unrelated
# run_command can't hijack its status pill.
KIOSK_LIFECYCLE_COMMAND_TYPES = ("start", "stop", "restart", "configure")


@bp.route("/")
@login_required
@load_company_context
def list_instances(company_id):
    company = g.company
    instances = Instance.query.filter_by(company_id=company.id).order_by(Instance.created_at.desc()).all()
    tokens = EnrollmentToken.query.filter_by(company_id=company.id, revoked=False).order_by(
        EnrollmentToken.created_at.desc()
    ).all()

    from datetime import timedelta
    day_ago = datetime.utcnow() - timedelta(hours=24)
    stats = {
        "total": len(instances),
        "online": sum(1 for i in instances if i.connection_status == "online"),
        "offline": sum(1 for i in instances if i.connection_status == "offline"),
        "updating": sum(1 for i in instances if i.active_deployment() is not None),
        "failed_24h": UpdateDeployment.query.join(Instance).filter(
            Instance.company_id == company.id,
            UpdateDeployment.status.in_(["failed", "rolled_back"]),
            UpdateDeployment.completed_at >= day_ago,
        ).count(),
        "successful_24h": UpdateDeployment.query.join(Instance).filter(
            Instance.company_id == company.id,
            UpdateDeployment.status == "successful",
            UpdateDeployment.completed_at >= day_ago,
        ).count(),
    }

    return render_template(
        "instances/list.html", company=company, instances=instances, tokens=tokens,
        role=g.company_role, stats=stats,
    )


@bp.route("/status")
@login_required
@load_company_context
def instances_status(company_id):
    """Long-polled from the instances list page (see app/long_poll.py) so
    the stat tiles and each row's Connection/Update status cells update
    live — another admin pushing an update, an instance going on/offline,
    or a deployment progressing all show up here within ~0.5s, without
    the page needing a manual refresh."""
    from datetime import timedelta
    company_id_int = g.company.id

    def build_payload():
        instances = Instance.query.filter_by(company_id=company_id_int).all()
        day_ago = datetime.utcnow() - timedelta(hours=24)
        rows = {}
        for i in instances:
            d = i.active_deployment()
            rows[i.public_id] = {
                "connection_status": i.connection_status,
                "app_version": i.app_version,
                "last_seen_at": i.last_seen_at.strftime("%Y-%m-%d %H:%M UTC") if i.last_seen_at else None,
                "deployment": {"status": d.status, "version": d.package.version} if d else None,
            }
        stats = {
            "total": len(instances),
            "online": sum(1 for i in instances if i.connection_status == "online"),
            "offline": sum(1 for i in instances if i.connection_status == "offline"),
            "updating": sum(1 for i in instances if i.active_deployment() is not None),
            "failed_24h": UpdateDeployment.query.join(Instance).filter(
                Instance.company_id == company_id_int,
                UpdateDeployment.status.in_(["failed", "rolled_back"]),
                UpdateDeployment.completed_at >= day_ago,
            ).count(),
        }
        return {"instances": rows, "stats": stats}

    return long_poll_response(build_payload)


@bp.route("/tokens/new", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def new_token(company_id):
    company = g.company
    label = request.form.get("label", "").strip() or None
    expires_in_days = request.form.get("expires_in_days", "").strip()
    max_uses = request.form.get("max_uses", "").strip()
    license_duration_days = request.form.get("license_duration_days", "").strip()

    token = EnrollmentToken(company_id=company.id, label=label, created_by_id=current_user.id)
    if expires_in_days.isdigit() and int(expires_in_days) > 0:
        token.expires_at = datetime.utcnow() + timedelta(days=int(expires_in_days))
    if max_uses.isdigit() and int(max_uses) > 0:
        token.max_uses = int(max_uses)
    if license_duration_days.isdigit() and int(license_duration_days) > 0:
        token.license_duration_days = int(license_duration_days)

    db.session.add(token)
    log_action(company, current_user, "enrollment_token_created", label or "(no label)")
    db.session.commit()

    flash("Enrollment token created. Copy the install command before leaving this page.", "success")
    return redirect(url_for("instances.list_instances", company_id=company.public_id))


@bp.route("/tokens/<int:token_id>/revoke", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def revoke_token(company_id, token_id):
    company = g.company
    token = EnrollmentToken.query.filter_by(id=token_id, company_id=company.id).first()
    if token is None:
        abort(404)
    token.revoked = True
    log_action(company, current_user, "enrollment_token_revoked", token.label or token.token[:8])
    db.session.commit()
    flash("Enrollment token revoked.", "info")
    return redirect(url_for("instances.list_instances", company_id=company.public_id))


@bp.route("/<instance_id>")
@login_required
@load_company_context
def detail(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    current_config = instance.current_config()
    pending_config = instance.pending_config()
    current_config_pretty = (
        json.dumps(json.loads(current_config.config_json), indent=2, sort_keys=True)
        if current_config else "{}"
    )
    # For the "quick set" fields below the raw JSON editor (e.g. auto-logout):
    # prefer whatever's pending (the operator's most recent intent) over what's
    # actually applied yet, same precedence set_auto_logout itself merges onto.
    _latest_config_source = pending_config or current_config
    current_config_dict = (
        json.loads(_latest_config_source.config_json) if _latest_config_source else {}
    )

    latest_remote_access = (
        RemoteAccessToken.query
        .filter_by(instance_id=instance.id)
        .order_by(RemoteAccessToken.created_at.desc())
        .first()
    )
    recent_error_reports = (
        AgentErrorReport.query
        .filter_by(instance_id=instance.id)
        .order_by(AgentErrorReport.created_at.desc())
        .limit(20)
        .all()
    )

    # Only these command types represent the kiosk PROCESS's own
    # lifecycle. "run_command" is a real InstanceCommand too (same queue,
    # same status field) but running an arbitrary one-off shell command on
    # the kiosk has nothing to do with whether the kiosk process itself is
    # starting/stopping — filtering it out here fixes a real bug where
    # using "Run a command on this kiosk" would hijack the Kiosk Process
    # panel's status pill into showing a generic "Working…" state for the
    # whole duration of an unrelated command.
    pending_kiosk_command = InstanceCommand.query.filter(
        InstanceCommand.instance_id == instance.id,
        InstanceCommand.command_type.in_(KIOSK_LIFECYCLE_COMMAND_TYPES),
        InstanceCommand.status.in_(("pending", "in_progress")),
    ).order_by(InstanceCommand.created_at.desc()).first()
    recent_kiosk_commands = InstanceCommand.query.filter_by(instance_id=instance.id).order_by(
        InstanceCommand.created_at.desc()
    ).limit(10).all()

    equipment_items = InstanceEquipmentItem.query.filter_by(
        instance_id=instance.id, deleted_at=None
    ).order_by(InstanceEquipmentItem.kind, InstanceEquipmentItem.name).all()
    items_by_category = _group_equipment_by_category(equipment_items, "item")
    tools_by_category = _group_equipment_by_category(equipment_items, "tool")
    items_count = sum(len(rows) for _, rows in items_by_category)
    tools_count = sum(len(rows) for _, rows in tools_by_category)
    # Suggestions for the category/type input's datalist: whatever's
    # already in use on this instance, plus the two defaults — never
    # enforced, just autocomplete.
    category_suggestions = sorted(
        {(e.category or "").strip() for e in equipment_items if e.category} | set(EQUIPMENT_CATEGORIES)
    )
    local_users = InstanceLocalUser.query.filter_by(
        instance_id=instance.id, deleted_at=None
    ).order_by(InstanceLocalUser.name).all()
    roles = InstanceRole.query.filter_by(instance_id=instance.id).order_by(InstanceRole.name).all()
    role_names_for_datalist = sorted({r.name for r in roles} | set(LOCAL_USER_ROLES))

    # Explicit permission booleans for the template, rather than hardcoded
    # role-name lists sprinkled through detail.html — this is what actually
    # drives what a Client Portal operator sees vs. a manager/admin/owner
    # (see ROLE_PERMISSIONS / "operate_kiosk" in models.py): kiosk lifecycle,
    # Items & Tools, and Local Kiosk Users for anyone who can operate_kiosk;
    # everything that changes how the instance is set up or reached (config,
    # rename/delete, enrollment tokens, remote access, arbitrary commands)
    # stays behind manage_instances/manage_config, which operate_kiosk alone
    # does not grant.
    can_operate_kiosk = current_user.has_permission(company.id, "operate_kiosk")
    can_manage_instances = current_user.has_permission(company.id, "manage_instances")
    can_manage_config = current_user.has_permission(company.id, "manage_config")
    can_manage_updates = (
        current_user.has_permission(company.id, "manage_updates")
        or current_user.has_permission(company.id, "operate_kiosk_updates")
    )

    change_requests = ChangeRequest.query.filter_by(instance_id=instance.id).order_by(
        ChangeRequest.created_at.desc()
    ).all()
    scan_tokens = ScanToken.query.filter_by(instance_id=instance.id, revoked=False).order_by(
        ScanToken.created_at.desc()
    ).all()
    _instance_usable_packages = _usable_packages_for(instance)

    return render_template(
        "instances/detail.html", company=company, instance=instance, role=g.company_role,
        can_operate_kiosk=can_operate_kiosk, can_manage_instances=can_manage_instances,
        can_manage_config=can_manage_config, can_manage_updates=can_manage_updates,
        current_config=current_config, pending_config=pending_config,
        current_config_pretty=current_config_pretty, current_config_dict=current_config_dict,
        config_history=instance.configs,
        usable_packages=_instance_usable_packages,
        usable_package_groups=_grouped_packages(_instance_usable_packages),
        active_deployment=instance.active_deployment(),
        deployment_history=instance.deployments,
        latest_remote_access=latest_remote_access,
        recent_error_reports=recent_error_reports,
        pending_kiosk_command=pending_kiosk_command,
        recent_kiosk_commands=recent_kiosk_commands,
        equipment_items=equipment_items, equipment_kinds=EQUIPMENT_KINDS,
        equipment_statuses=EQUIPMENT_STATUSES,
        items_by_category=items_by_category, tools_by_category=tools_by_category,
        items_count=items_count, tools_count=tools_count,
        equipment_categories=category_suggestions, tool_statuses=TOOL_STATUSES,
        local_users=local_users, local_user_statuses=LOCAL_USER_STATUSES, local_user_roles=role_names_for_datalist,
        pin_min_length=PIN_MIN_LENGTH, pin_max_length=PIN_MAX_LENGTH,
        roles=roles, sidebar_item_keys=SIDEBAR_ITEM_KEYS,
        change_requests=change_requests,
        scan_tokens=scan_tokens,
        suspended_message=SUSPENDED_MESSAGE,
    )


@bp.route("/<instance_id>/requests/<request_id>/respond", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def respond_change_request(company_id, instance_id, request_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    change_request = ChangeRequest.query.filter_by(public_id=request_id, instance_id=instance.id).first()
    if change_request is None:
        abort(404)
    status = request.form.get("status", "").strip()
    if status not in CHANGE_REQUEST_STATUSES:
        abort(400)

    change_request.status = status
    change_request.admin_response = (request.form.get("admin_response") or "").strip() or None
    change_request.resolved_by_id = current_user.id
    change_request.resolved_at = datetime.utcnow()
    log_action(company, current_user, "change_request_updated", f"{change_request.title} -> {status}")
    db.session.commit()
    flash("Request updated.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


# --- Scan links (phone-camera / physical-scanner mini app, see scan_portal.py) ---

@bp.route("/<instance_id>/scan-tokens/create", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def create_scan_token(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    label = request.form.get("label", "").strip() or None
    token = ScanToken(instance_id=instance.id, created_by_id=current_user.id, label=label)
    db.session.add(token)
    log_action(company, current_user, "scan_token_created", label or "(no label)")
    db.session.commit()
    flash("Scan link created — share the link or QR code below with whoever needs it.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id) + "#inventory")


@bp.route("/<instance_id>/scan-tokens/<int:token_id>/revoke", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def revoke_scan_token(company_id, instance_id, token_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    token = ScanToken.query.filter_by(id=token_id, instance_id=instance.id).first()
    if token is None:
        abort(404)

    token.revoked = True
    log_action(company, current_user, "scan_token_revoked", token.label or token.token[:8])
    db.session.commit()
    flash("Scan link revoked — it will no longer open for anyone holding it.", "info")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id) + "#inventory")


@bp.route("/<instance_id>/scan-tokens/<int:token_id>/qr.svg")
@login_required
@load_company_context
@permission_required("manage_instances")
def scan_token_qr(company_id, instance_id, token_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    token = ScanToken.query.filter_by(id=token_id, instance_id=instance.id).first()
    if token is None:
        abort(404)

    # Lazy import — see the PDF-export incident this comment's sibling in
    # kiosk_app/app/blueprints/items.py describes: a module-level import of
    # a dependency that isn't actually installed yet must never be able to
    # take the whole process down at startup, only this one QR image.
    try:
        import qrcode
        import qrcode.image.svg
    except ImportError:
        abort(503)

    import io
    scan_url = current_app.config["BASE_URL"] + url_for("scan_portal.scan_app", token=token.token)
    img = qrcode.make(scan_url, image_factory=qrcode.image.svg.SvgPathImage, box_size=8, border=2)
    buf = io.BytesIO()
    img.save(buf)
    return Response(buf.getvalue(), mimetype="image/svg+xml")


@bp.route("/<instance_id>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def delete_instance(company_id, instance_id):
    """Permanently removes an instance and everything recorded against it.
    The Agent itself is untouched by this (there's no uninstall call in the
    API - it would just re-register as a brand new instance on its next
    heartbeat if it's still running with valid credentials) - this only
    forgets the Admin Panel's record of it.

    Instance.configs and Instance.deployments already cascade via their
    relationship() definitions, but RemoteAccessToken, AgentErrorReport,
    StagedRolloutInstance, and InstanceCommand only have a plain
    nullable=False foreign key with no ORM-level cascade - deleting the
    Instance row directly would hit an integrity error on whichever of
    those four has rows first. Deleted explicitly here instead of adding
    cascade="all, delete-orphan" to four more relationships for a path this
    rarely used only needs once.
    """
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    display_name = instance.display_name()

    RemoteAccessToken.query.filter_by(instance_id=instance.id).delete()
    AgentErrorReport.query.filter_by(instance_id=instance.id).delete()
    StagedRolloutInstance.query.filter_by(instance_id=instance.id).delete()
    InstanceCommand.query.filter_by(instance_id=instance.id).delete()

    log_action(company, current_user, "instance_deleted", display_name)
    db.session.delete(instance)  # cascades to configs + deployments via their relationships
    db.session.commit()

    flash(f"{display_name} has been deleted.", "success")
    return redirect(url_for("instances.list_instances", company_id=company.public_id))


@bp.route("/<instance_id>/rename", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def rename(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    name = request.form.get("name", "").strip()
    instance.name = name or None

    time_str = request.form.get("scheduled_update_time", "").strip()
    if request.form.get("clear_update_time"):
        instance.scheduled_update_time = None
    elif time_str:
        try:
            instance.scheduled_update_time = datetime.strptime(time_str, "%H:%M").time()
        except ValueError:
            flash("Update time must be in HH:MM format.", "danger")
            return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    db.session.commit()
    flash("Instance settings updated.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


def _add_months(dt: datetime, months: int) -> datetime:
    """Adds calendar months, not a 30-day approximation — a 1-year license
    bought on Jan 31 should land on the following Jan 31 (or Feb 28/29 if
    that month is shorter), not drift by leap-year quirks."""
    import calendar
    month_index = dt.month - 1 + months
    year = dt.year + month_index // 12
    month = month_index % 12 + 1
    day = min(dt.day, calendar.monthrange(year, month)[1])
    return dt.replace(year=year, month=month, day=day)


def _cancel_pending_kiosk_commands(instance, reason: str) -> None:
    """Marks any not-yet-delivered kiosk lifecycle command (start/stop/
    restart/configure) as failed instead of leaving it stuck showing
    "Queued..." forever. Used when suspending a license: the Agent can
    never actually poll for these again (every /api/v1/instances/* call
    403s — see instance_auth_required) until reactivated, and a stale
    pending command left sitting in the queue would otherwise fire the
    moment it's reactivated, whether or not that's still wanted at that
    point."""
    pending = InstanceCommand.query.filter(
        InstanceCommand.instance_id == instance.id,
        InstanceCommand.command_type.in_(KIOSK_LIFECYCLE_COMMAND_TYPES),
        InstanceCommand.status.in_(("pending", "in_progress")),
    ).all()
    for cmd in pending:
        cmd.status = "failed"
        cmd.result_message = reason
        cmd.acked_at = datetime.utcnow()


SUSPENDED_MESSAGE = (
    "Your service has been suspended by an OpsLabs admin. "
    "Please contact OpsLabs if you believe this is a mistake."
)


def _blocked_while_suspended(instance) -> bool:
    """True (and flashes an explanation) if this instance's license is
    suspended and the caller should refuse whatever start/restart/
    reconfigure/execute action brought it here — belt-and-suspenders on
    top of instance_auth_required's 403 (which the Agent can never even
    poll past while suspended), so staff/clients get an immediate, clear
    answer instead of a command that silently goes nowhere and sits there
    looking "Queued..." forever. Stopping is never blocked — it's always
    harmless, and blocking it would just be one more no-op command stuck
    in the queue."""
    if instance.license_status != "suspended":
        return False
    flash(SUSPENDED_MESSAGE, "danger")
    return True


@bp.route("/<instance_id>/license/suspend", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def suspend_license(company_id, instance_id):
    """Manual kill switch — see Instance.is_licensed()/license_status.
    Takes effect on the Agent's next heartbeat (instance_auth_required
    starts 403ing every /api/v1/instances/* call, and the Agent's own
    heartbeat loop stops the locally supervised kiosk process on seeing
    that specific rejection — see agent/heartbeat.py). kiosk_process_status
    is set to "suspended" here immediately though, rather than waiting for
    that heartbeat, so the Admin Panel and Client Portal both reflect the
    suspension right away instead of showing whatever stale status (or a
    stuck "Queued..." pending command) happened to be last reported."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    instance.license_status = "suspended"
    instance.kiosk_process_status = "suspended"
    _cancel_pending_kiosk_commands(instance, "Cancelled — instance suspended.")
    log_action(company, current_user, "license_suspended", instance.display_name())
    db.session.commit()
    flash(f"{instance.display_name()} suspended — it will stop working on its next heartbeat.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/license/reactivate", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def reactivate_license(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    instance.license_status = "active"
    # Cleared rather than guessed at — genuinely unknown until the Agent's
    # next successful heartbeat reports the real state (suspension blocked
    # every report it would otherwise have sent).
    instance.kiosk_process_status = None
    log_action(company, current_user, "license_reactivated", instance.display_name())
    db.session.commit()
    flash(f"{instance.display_name()} reactivated.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/license/extend", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def extend_license(company_id, instance_id):
    """Adds amount*unit to whichever is later: the current expiry (if
    still in the future) or now — extending an already-future expiry
    stacks onto it rather than resetting it, same as renewing a
    subscription before it lapses."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    try:
        amount = int(request.form.get("amount", "").strip())
    except ValueError:
        flash("Enter a whole number for the duration.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    if amount <= 0:
        flash("Duration must be a positive number.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    unit = request.form.get("unit", "days")
    now = datetime.utcnow()
    base = instance.license_expires_at if (instance.license_expires_at and instance.license_expires_at > now) else now

    if unit == "days":
        instance.license_expires_at = base + timedelta(days=amount)
    elif unit == "months":
        instance.license_expires_at = _add_months(base, amount)
    elif unit == "years":
        instance.license_expires_at = _add_months(base, amount * 12)
    else:
        flash("Unknown duration unit.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    log_action(company, current_user, "license_extended",
               f"{instance.display_name()}: +{amount} {unit} -> {instance.license_expires_at.strftime('%Y-%m-%d')}")
    db.session.commit()
    flash(f"License extended to {instance.license_expires_at.strftime('%Y-%m-%d')} UTC.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/license/clear-expiry", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def clear_license_expiry(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    instance.license_expires_at = None
    log_action(company, current_user, "license_expiry_cleared", instance.display_name())
    db.session.commit()
    flash("Expiry cleared — this instance's license no longer expires on its own.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/config/push", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_config")
def push_config(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    raw = request.form.get("config_json", "").strip()
    try:
        parsed = json.loads(raw) if raw else {}
    except ValueError:
        flash("That isn't valid JSON — fix the syntax and try again.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    if not isinstance(parsed, dict):
        flash("Config must be a JSON object (key/value pairs), not a list or scalar.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    # A new push supersedes any still-unacknowledged one — the instance should
    # only ever have one thing to apply at a time.
    existing_pending = instance.pending_config()
    if existing_pending is not None:
        existing_pending.status = "rejected"
        existing_pending.agent_message = "Superseded by a newer push before it was acknowledged."
        existing_pending.acknowledged_at = datetime.utcnow()

    last_version = db.session.query(db.func.max(InstanceConfig.version)).filter_by(
        instance_id=instance.id
    ).scalar() or 0

    config = InstanceConfig(
        instance_id=instance.id,
        version=last_version + 1,
        config_json=json.dumps(parsed, sort_keys=True),
        pushed_by_id=current_user.id,
        status="pending",
    )
    db.session.add(config)
    log_action(company, current_user, "config_pushed", f"{instance.display_name()} v{config.version}")
    db.session.commit()

    flash(f"Configuration v{config.version} queued — it will apply next time the instance checks in.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/config/auto-logout", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_config")
def set_auto_logout(company_id, instance_id):
    """Friendly shortcut over push_config for the one key most operators
    actually want to change day-to-day — merges auto_logout_minutes into
    whatever config is already pending/applied rather than making them
    hand-edit the raw JSON textarea and risk dropping unrelated keys."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    try:
        minutes = int(request.form.get("minutes", "").strip())
    except ValueError:
        flash("Enter a whole number of minutes.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    if minutes < 1:
        flash("Auto-logout must be at least 1 minute.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    base = instance.pending_config() or instance.current_config()
    try:
        merged = json.loads(base.config_json) if base else {}
    except ValueError:
        merged = {}
    if not isinstance(merged, dict):
        merged = {}
    merged["auto_logout_minutes"] = minutes

    existing_pending = instance.pending_config()
    if existing_pending is not None:
        existing_pending.status = "rejected"
        existing_pending.agent_message = "Superseded by a newer push before it was acknowledged."
        existing_pending.acknowledged_at = datetime.utcnow()

    last_version = db.session.query(db.func.max(InstanceConfig.version)).filter_by(
        instance_id=instance.id
    ).scalar() or 0

    config = InstanceConfig(
        instance_id=instance.id,
        version=last_version + 1,
        config_json=json.dumps(merged, sort_keys=True),
        pushed_by_id=current_user.id,
        status="pending",
    )
    db.session.add(config)
    log_action(company, current_user, "config_pushed", f"{instance.display_name()} v{config.version} (auto_logout_minutes={minutes})")
    db.session.commit()

    flash(f"Auto-logout set to {minutes} minute(s) — queued as v{config.version}.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/config/tenant-name", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_config")
def set_tenant_name(company_id, instance_id):
    """Friendly shortcut over push_config for the tenant/company name shown
    on the kiosk's own login screen (kiosk_app's TENANT_NAME, sourced from
    this same config_json under the "tenant_name" key) — same merge-not-
    replace pattern as set_auto_logout, so setting this never drops other
    pending config keys."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    tenant_name = request.form.get("tenant_name", "").strip()
    if not tenant_name:
        flash("Enter a name to show on the login screen.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    base = instance.pending_config() or instance.current_config()
    try:
        merged = json.loads(base.config_json) if base else {}
    except ValueError:
        merged = {}
    if not isinstance(merged, dict):
        merged = {}
    merged["tenant_name"] = tenant_name

    existing_pending = instance.pending_config()
    if existing_pending is not None:
        existing_pending.status = "rejected"
        existing_pending.agent_message = "Superseded by a newer push before it was acknowledged."
        existing_pending.acknowledged_at = datetime.utcnow()

    last_version = db.session.query(db.func.max(InstanceConfig.version)).filter_by(
        instance_id=instance.id
    ).scalar() or 0

    config = InstanceConfig(
        instance_id=instance.id,
        version=last_version + 1,
        config_json=json.dumps(merged, sort_keys=True),
        pushed_by_id=current_user.id,
        status="pending",
    )
    db.session.add(config)
    log_action(company, current_user, "config_pushed", f"{instance.display_name()} v{config.version} (tenant_name={tenant_name!r})")
    db.session.commit()

    flash(f"Login screen name set to \"{tenant_name}\" — queued as v{config.version}.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/config/client-portal-port", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_config")
def set_client_portal_port(company_id, instance_id):
    """Enables/reconfigures the Local Client Portal's LAN-facing port (see
    kiosk_app/app/blueprints/client.py + kiosk_app/app/config.py's
    CLIENT_PORTAL_PORT) on an already-enrolled instance. There is no other
    remote channel for this — the Agent starts kiosk_app with a plain
    command, inheriting its own environment (see agent/main.py), so the
    only way to hand it a port number after the fact is through this same
    config-push/apply pipeline already used for tenant_name/
    auto_logout_minutes. Same merge-not-replace pattern as those; blank
    clears it back to disabled (None) rather than requiring 0 or similar."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    raw_port = request.form.get("client_portal_port", "").strip()
    port = None
    if raw_port:
        try:
            port = int(raw_port)
            if not (1 <= port <= 65535):
                raise ValueError
        except ValueError:
            flash("Enter a valid port number (1-65535), or leave blank to disable.", "danger")
            return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    base = instance.pending_config() or instance.current_config()
    try:
        merged = json.loads(base.config_json) if base else {}
    except ValueError:
        merged = {}
    if not isinstance(merged, dict):
        merged = {}
    if port is None:
        merged.pop("client_portal_port", None)
    else:
        merged["client_portal_port"] = port

    existing_pending = instance.pending_config()
    if existing_pending is not None:
        existing_pending.status = "rejected"
        existing_pending.agent_message = "Superseded by a newer push before it was acknowledged."
        existing_pending.acknowledged_at = datetime.utcnow()

    last_version = db.session.query(db.func.max(InstanceConfig.version)).filter_by(
        instance_id=instance.id
    ).scalar() or 0

    config = InstanceConfig(
        instance_id=instance.id,
        version=last_version + 1,
        config_json=json.dumps(merged, sort_keys=True),
        pushed_by_id=current_user.id,
        status="pending",
    )
    db.session.add(config)
    log_action(company, current_user, "config_pushed", f"{instance.display_name()} v{config.version} (client_portal_port={port})")
    db.session.commit()

    if port is None:
        flash(f"Local Client Portal disabled — queued as v{config.version}.", "success")
    else:
        flash(f"Local Client Portal port set to {port} — queued as v{config.version}.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/config/<int:version>/restore", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_config")
def restore_config(company_id, instance_id, version):
    """Configuration rollback safety (spec Section 43): restoring an older
    version doesn't rewrite history — it pushes a brand-new version whose
    content is a copy of the old one, going through the same
    receive/validate/apply/confirm path as any other push. The version being
    restored FROM stays exactly as it was in history."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    old = InstanceConfig.query.filter_by(instance_id=instance.id, version=version).first()
    if old is None:
        abort(404)

    existing_pending = instance.pending_config()
    if existing_pending is not None:
        existing_pending.status = "rejected"
        existing_pending.agent_message = "Superseded by a config restore before it was acknowledged."
        existing_pending.acknowledged_at = datetime.utcnow()

    last_version = db.session.query(db.func.max(InstanceConfig.version)).filter_by(
        instance_id=instance.id
    ).scalar() or 0

    restored = InstanceConfig(
        instance_id=instance.id,
        version=last_version + 1,
        config_json=old.config_json,
        pushed_by_id=current_user.id,
        status="pending",
    )
    db.session.add(restored)
    log_action(company, current_user, "config_restored", f"{instance.display_name()} restored from v{version} as v{restored.version}")
    db.session.commit()

    flash(f"Restoring v{version}'s content as new version v{restored.version} — it will apply next check-in.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


def _grouped_packages(packages):
    """Groups packages (must already be ordered newest-first by uploaded_at,
    same as _usable_packages_for/bulk_schedule's own queries) into
    (month_label, [packages]) pairs — e.g. "September 2026" — so the Package
    dropdown reads as a scannable release timeline instead of one long flat
    "vX.Y.Z" list with no sense of when anything actually shipped. Plain
    Python grouping rather than Jinja's groupby filter, which re-sorts
    ascending by the group key first and would undo the newest-first order
    this depends on."""
    groups = []
    current_label = None
    for p in packages:
        label = p.uploaded_at.strftime("%B %Y")
        if label != current_label:
            groups.append((label, []))
            current_label = label
        groups[-1][1].append(p)
    return groups


def _usable_packages_for(instance):
    return UpdatePackage.query.filter_by(status="validated", withdrawn=False).filter(
        UpdatePackage.supported_os.contains(instance.os)
    ).order_by(UpdatePackage.uploaded_at.desc()).all()


def _schedule_update(instance, package, mode, custom_dt_utc, user):
    """Shared by single-instance and bulk push. Returns (deployment, error)."""
    if not package.is_usable():
        return None, f"Package v{package.version} is not usable (invalid or withdrawn)."
    if instance.os not in package.supported_os_list():
        return None, f"Package v{package.version} does not support {instance.os}."

    existing = instance.active_deployment()
    if existing is not None:
        if existing.status in ("scheduled", "waiting"):
            existing.status = "superseded"
            existing.append_log("superseded", "replaced by a newer push before it started")
        else:
            return None, (
                f"Instance already has an update in progress (v{existing.package.version}, "
                f"status: {existing.status}) — wait for it to finish before pushing another."
            )

    try:
        target_time_utc, source = resolve_deployment_target(instance, mode, custom_dt_utc)
    except ValueError as e:
        return None, str(e)

    deployment = UpdateDeployment(
        instance_id=instance.id,
        package_id=package.id,
        requested_by_id=user.id,
        target_time_utc=target_time_utc,
        schedule_source=source,
        previous_version=instance.app_version,
    )
    deployment.append_log("scheduled", f"requested by {user.email}, source={source}")
    db.session.add(deployment)
    return deployment, None


@bp.route("/<instance_id>/updates/schedule", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_updates", "operate_kiosk_updates")
def schedule_update(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    package = UpdatePackage.query.filter_by(public_id=request.form.get("package_id")).first()
    mode = request.form.get("mode", "schedule")
    custom_dt_utc = None
    if mode == "custom":
        raw = request.form.get("custom_datetime", "").strip()
        try:
            custom_dt_utc = datetime.strptime(raw, "%Y-%m-%dT%H:%M")
        except ValueError:
            flash("Enter a valid custom date/time.", "danger")
            return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    if package is None:
        flash("Choose a package to push.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    deployment, error = _schedule_update(instance, package, mode, custom_dt_utc, current_user)
    if error:
        db.session.rollback()
        flash(error, "danger")
    else:
        log_action(company, current_user, "update_pushed", f"{instance.display_name()} -> v{package.version} ({mode})")
        db.session.commit()
        if mode == "now":
            flash(f"Update to v{package.version} pushed immediately.", "success")
        else:
            flash(
                f"Update to v{package.version} scheduled for "
                f"{deployment.target_time_utc.strftime('%Y-%m-%d %H:%M UTC')} "
                f"(source: {deployment.schedule_source}).",
                "success",
            )
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/updates/<deployment_id>/cancel", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_updates", "operate_kiosk_updates")
def cancel_update(company_id, instance_id, deployment_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    deployment = UpdateDeployment.query.filter_by(public_id=deployment_id, instance_id=instance.id).first()
    if deployment is None:
        abort(404)
    if deployment.status not in ("scheduled", "waiting"):
        flash("That update has already started and can no longer be cancelled from here.", "warning")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    deployment.status = "cancelled"
    deployment.cancelled_at = datetime.utcnow()
    deployment.cancelled_by_id = current_user.id
    log_action(company, current_user, "update_cancelled", f"{instance.display_name()} v{deployment.package.version}")
    db.session.commit()
    flash("Scheduled update cancelled.", "info")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/updates/bulk-schedule", methods=["GET", "POST"])
@login_required
@load_company_context
@permission_required("manage_updates")
def bulk_schedule(company_id):
    company = g.company
    instances = Instance.query.filter_by(company_id=company.id).order_by(Instance.created_at.desc()).all()
    packages = UpdatePackage.query.filter_by(status="validated", withdrawn=False).order_by(
        UpdatePackage.uploaded_at.desc()
    ).all()

    if request.method == "POST":
        package = UpdatePackage.query.filter_by(public_id=request.form.get("package_id")).first()
        mode = request.form.get("mode", "schedule")
        instance_ids = request.form.getlist("instance_ids")

        custom_dt_utc = None
        if mode == "custom":
            raw = request.form.get("custom_datetime", "").strip()
            try:
                custom_dt_utc = datetime.strptime(raw, "%Y-%m-%dT%H:%M")
            except ValueError:
                flash("Enter a valid custom date/time.", "danger")
                return redirect(url_for("instances.bulk_schedule", company_id=company.public_id))

        if package is None or not instance_ids:
            flash("Choose a package and at least one instance.", "danger")
            return redirect(url_for("instances.bulk_schedule", company_id=company.public_id))

        succeeded, failed = [], []
        for pub_id in instance_ids:
            instance = Instance.query.filter_by(public_id=pub_id, company_id=company.id).first()
            if instance is None:
                continue
            deployment, error = _schedule_update(instance, package, mode, custom_dt_utc, current_user)
            if error:
                failed.append((instance.display_name(), error))
            else:
                succeeded.append(instance.display_name())
        db.session.commit()

        if succeeded:
            flash(f"Scheduled for {len(succeeded)} instance(s): {', '.join(succeeded)}.", "success")
            log_action(company, current_user, "bulk_update_pushed", f"{package.version} -> {', '.join(succeeded)}")
        for name, error in failed:
            flash(f"{name}: {error}", "danger")

        return redirect(url_for("instances.list_instances", company_id=company.public_id))

    return render_template(
        "instances/bulk_schedule.html", company=company, instances=instances, packages=packages,
        package_groups=_grouped_packages(packages),
    )


@bp.route("/<instance_id>/remote-access/request", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def request_remote_access(company_id, instance_id):
    from datetime import timedelta
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    token = RemoteAccessToken(
        instance_id=instance.id,
        requested_by_id=current_user.id,
        expires_at=datetime.utcnow() + timedelta(minutes=10),
    )
    db.session.add(token)
    log_action(company, current_user, "remote_access_requested", instance.display_name())
    db.session.commit()

    flash(
        f"Remote access token issued (valid 10 minutes). The Instance Agent will "
        f"pick it up on its next poll and report back — the tunnel broker that "
        f"would actually open a session doesn't exist yet, so expect an "
        f"'unsupported' outcome, honestly reported rather than silently ignored.",
        "info",
    )
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/audit-log")
@login_required
@load_company_context
@permission_required("manage_members")
def audit_log(company_id):
    from app.models import AuditLogEntry
    company = g.company
    entries = AuditLogEntry.query.filter_by(company_id=company.id).order_by(
        AuditLogEntry.created_at.desc()
    ).limit(200).all()
    return render_template("instances/audit_log.html", company=company, entries=entries, role=g.company_role)


def _queue_command(instance, command_type, payload=None, actor_id=None):
    """Only one pending command per instance at a time — a new one
    supersedes an old still-unacknowledged one, same pattern used for
    config pushes and update pushes elsewhere in this file.

    `actor_id` defaults to the logged-in staff user, but callers outside
    this blueprint that have already resolved a `users.id`-safe id
    themselves (the Client Portal — see client_portal.py — whose own
    ClientUser accounts live in a separate table and must never leak their
    own id into this column) can pass it explicitly instead."""
    import json as _json
    existing = InstanceCommand.query.filter_by(instance_id=instance.id, status="pending").first()
    if existing is not None:
        existing.status = "failed"
        existing.result_message = "Superseded by a newer command before the Agent picked it up."
        existing.acked_at = datetime.utcnow()

    command = InstanceCommand(
        instance_id=instance.id, command_type=command_type,
        payload_json=_json.dumps(payload) if payload else None,
        requested_by_id=actor_id if actor_id is not None else current_user.id,
    )
    db.session.add(command)
    return command


def _epoch_ms(dt):
    """Epoch milliseconds, not isoformat() — our datetimes are naive UTC
    (datetime.utcnow()), and isoformat() on a naive datetime carries no
    timezone marker, so JavaScript's Date parser would silently read it as
    LOCAL time instead of UTC. That's a few hours of drift on this server
    (UK), which would make client-side elapsed-time math wildly wrong. An
    epoch number sidesteps the ambiguity entirely."""
    return int(dt.replace(tzinfo=timezone.utc).timestamp() * 1000)


def _kiosk_status_payload(instance):
    """Shared shape for the initial page render and the polling endpoint,
    so the JS updating the DOM after a fetch() matches what Jinja rendered
    on load."""
    pending_kiosk_command = InstanceCommand.query.filter(
        InstanceCommand.instance_id == instance.id,
        InstanceCommand.command_type.in_(KIOSK_LIFECYCLE_COMMAND_TYPES),
        InstanceCommand.status.in_(("pending", "in_progress")),
    ).order_by(InstanceCommand.created_at.desc()).first()
    recent_kiosk_commands = InstanceCommand.query.filter_by(instance_id=instance.id).order_by(
        InstanceCommand.created_at.desc()
    ).limit(10).all()

    payload = {
        "kiosk_process_status": instance.kiosk_process_status,
        "connection_status": instance.connection_status,
        "pending_command": (
            {
                "command_type": pending_kiosk_command.command_type,
                # "pending": queued, the Agent hasn't picked it up yet (or
                # we simply haven't heard back — could be offline, or just
                # mid-poll-cycle; the Agent long-polls up to 20s at a time,
                # so this is genuinely unbounded and NOT something to fake
                # a percentage for).
                # "in_progress": the Agent has confirmed it's actively
                # executing this — a real signal, not a guess (see
                # InstanceCommand.started_at / agent_api.py's
                # start_command / agent/commands.py).
                "status": pending_kiosk_command.status,
                "queued_at": _epoch_ms(pending_kiosk_command.created_at),
                "started_at": (
                    _epoch_ms(pending_kiosk_command.started_at)
                    if pending_kiosk_command.started_at else None
                ),
            }
            if pending_kiosk_command else None
        ),
        "recent_commands": [
            {
                "command_type": cmd.command_type,
                "status": cmd.status,
                "result_message": cmd.result_message or "",
                "created_at": cmd.created_at.strftime("%Y-%m-%d %H:%M UTC"),
            }
            for cmd in recent_kiosk_commands
        ],
    }
    import hashlib as _hashlib
    import json as _json
    payload["sig"] = _hashlib.sha1(
        _json.dumps(payload, sort_keys=True, default=str).encode()
    ).hexdigest()
    return payload


@bp.route("/<instance_id>/kiosk/status")
@login_required
@load_company_context
def kiosk_status(company_id, instance_id):
    """Polled from the instance detail page so the Kiosk Process panel can
    update live (status pill, pending-command banner, recent commands)
    without a full page reload.

    Long-polls when ?wait=<seconds>&sig=<last known sig> are given, using
    the exact same pattern as the Agent's own get_pending_command channel
    in agent_api.py: hold the connection open, re-checking every ~0.5s,
    until the computed state signature differs from what the browser
    already has, or the wait expires. Without this the browser was stuck
    on a flat interval (originally 3s) — noticeably laggy for something
    that's supposed to feel instant. This gets updates onto the page
    within ~0.5s of the DB actually changing, whether that change came
    from this browser tab, another admin's tab, or the Agent's own
    heartbeat/ack — while still working as a plain single-shot GET if
    wait/sig are omitted.
    """
    import time as _time
    company = g.company
    company_id_int = company.id  # capture before the loop re-queries per iteration

    # Confirm the instance exists / belongs to this company before entering
    # the wait loop, so a bad instance_id 404s immediately instead of
    # hanging for MAX_WAIT_SECONDS.
    if Instance.query.filter_by(public_id=instance_id, company_id=company_id_int).first() is None:
        abort(404)

    MAX_WAIT_SECONDS = 25
    wait_seconds = request.args.get("wait", type=float, default=0) or 0
    wait_seconds = max(0.0, min(wait_seconds, MAX_WAIT_SECONDS))
    known_sig = request.args.get("sig", type=str, default=None)
    deadline = _time.monotonic() + wait_seconds

    while True:
        # Re-fetch the instance fresh every iteration rather than reusing
        # the object from before the loop — after db.session.remove() below,
        # a held-onto ORM object is detached and its already-loaded scalar
        # attributes (like kiosk_process_status) do NOT refresh themselves
        # on the next access, so a stale `instance` here would make this
        # loop only ever "see" recent_commands changes (a fresh query
        # inside _kiosk_status_payload) while kiosk_process_status itself
        # stayed frozen at whatever it was when the request started — this
        # is exactly the bug the Agent's own long-poll in agent_api.py
        # avoids by re-querying from scratch each pass, and the reason it
        # calls db.session.remove() at all instead of just sleeping.
        instance = Instance.query.filter_by(public_id=instance_id, company_id=company_id_int).first()
        if instance is None:
            abort(404)
        payload = _kiosk_status_payload(instance)
        if payload["sig"] != known_sig or _time.monotonic() >= deadline:
            return jsonify(payload)
        db.session.remove()
        _time.sleep(0.5)


@bp.route("/<instance_id>/kiosk/start", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def kiosk_start(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    if _blocked_while_suspended(instance):
        if request.headers.get("X-Requested-With") == "fetch":
            return jsonify(_kiosk_status_payload(instance))
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    _queue_command(instance, "start")
    log_action(company, current_user, "kiosk_start_requested", instance.display_name())
    db.session.commit()
    if request.headers.get("X-Requested-With") == "fetch":
        return jsonify(_kiosk_status_payload(instance))
    flash("Start requested — the Agent will pick this up on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/stop", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def kiosk_stop(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "stop")
    log_action(company, current_user, "kiosk_stop_requested", instance.display_name())
    db.session.commit()
    if request.headers.get("X-Requested-With") == "fetch":
        return jsonify(_kiosk_status_payload(instance))
    flash("Stop requested — the Agent will pick this up on its next poll.", "warning")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/restart", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def kiosk_restart(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    if _blocked_while_suspended(instance):
        if request.headers.get("X-Requested-With") == "fetch":
            return jsonify(_kiosk_status_payload(instance))
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    _queue_command(instance, "restart")
    log_action(company, current_user, "kiosk_restart_requested", instance.display_name())
    db.session.commit()
    if request.headers.get("X-Requested-With") == "fetch":
        return jsonify(_kiosk_status_payload(instance))
    flash("Restart requested — the Agent will pick this up on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/reset-db", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_reset_db(company_id, instance_id):
    """Wipes every row out of the Kiosk App's local database on this
    instance (items, tools, local users, projects, wire, audits — see
    kiosk_app/app/blueprints/sync_api.py::reset_db, which this queues), an
    order of magnitude more destructive than start/stop/restart, so this
    sits behind manage_instances like delete_instance rather than the
    lighter operate_kiosk permission. The Agent takes a safety backup
    (uploaded to this Admin Panel as normal, so it shows up in the
    instance's backup history) immediately before wiping — see
    run_db_reset in the Agent — so this is recoverable via restore, but
    never silently.
    """
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "db_reset")
    log_action(company, current_user, "kiosk_db_reset_requested", instance.display_name())
    db.session.commit()
    if request.headers.get("X-Requested-With") == "fetch":
        return jsonify(_kiosk_status_payload(instance))
    flash(
        "Database reset requested — the Agent will back up the current database "
        "and then wipe it on its next poll.",
        "warning",
    )
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/agent/update", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def agent_self_update(company_id, instance_id):
    """Pushes the agent/ folder currently on disk here to ONE
    already-enrolled instance's live Agent service — a narrow, one-shot
    exception to "no remote Agent self-update channel exists" (see
    dev_files.py::publish's own docstring). Queues an 'agent_update'
    InstanceCommand carrying a download URL + checksum for the exact same
    opslab-agent.tar.gz artifact fresh installs already use (rebuilt here
    first, so this always ships whatever is on disk right now, not a
    possibly-stale previous Publish) — see agent/self_update.py for what
    the Agent does with it: downloads, verifies, then hands off to a
    detached helper process to actually stop the service, swap agent/,
    and restart it, specifically so the swap is never done by a thread
    the service's own shutdown path has to wait on (see that module's own
    docstring for why that matters — it's what caused a real deadlock the
    last time this was attempted by hand).

    Deliberately does NOT touch the Kiosk App (app_install_dir) or the
    installed Python runtime — only agent/ itself, which is all that's
    changed. A future change to service_files/ or requirements.txt would
    need this taught to swap those too; out of scope for this one-shot
    tool as it stands today.
    """
    import hashlib
    import os
    from app.blueprints.dev_files import build_agent_tarball_snapshot, AGENT_UPDATE_SNAPSHOT_DIR

    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    if _blocked_while_suspended(instance):
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    # An immutable, uniquely-named snapshot (never rewritten after this
    # call) rather than the shared opslab-agent.tar.gz that publish() also
    # rebuilds — see build_agent_tarball_snapshot()'s docstring for the
    # checksum race that shared file caused (traced from a real failure:
    # 2026-09-12's agent_update to this exact route came back "Checksum
    # mismatch"). Computing the checksum from this exact file, which
    # nothing will ever touch again, means it can never drift out from
    # under a later download no matter what else gets rebuilt/published
    # meanwhile.
    tarball_path = build_agent_tarball_snapshot()
    with open(tarball_path, "rb") as f:
        checksum = hashlib.sha256(f.read()).hexdigest()

    snapshot_filename = os.path.relpath(tarball_path, AGENT_UPDATE_SNAPSHOT_DIR)
    download_url = current_app.config["BASE_URL"] + url_for(
        "static", filename=f"installers/agent_updates/{snapshot_filename}"
    )
    _queue_command(instance, "agent_update", payload={
        "download_url": download_url,
        "checksum_sha256": checksum,
    })
    log_action(company, current_user, "agent_update_requested", instance.display_name())
    db.session.commit()
    flash(
        "Agent update requested — on its next command poll, the Agent will download, verify, "
        "and hand off to a detached helper that stops the service, swaps the agent/ code, and "
        "restarts it. The service will be briefly unreachable during that restart.",
        "warning",
    )
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/configure", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_configure(company_id, instance_id):
    """Sets what command the Agent uses to start the kiosk process — the
    piece that was completely missing before: there was no way to tell an
    already-installed Agent what to actually run, short of hand-editing
    settings.json on the machine itself."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    if _blocked_while_suspended(instance):
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    start_command = request.form.get("kiosk_start_command", "").strip()
    working_dir = request.form.get("kiosk_working_dir", "").strip()
    health_check_url = request.form.get("kiosk_health_check_url", "").strip()
    health_check_command = request.form.get("kiosk_health_check_command", "").strip()
    inventory_sync_url = request.form.get("kiosk_inventory_sync_url", "").strip()
    confirm_clear = request.form.get("confirm_clear") == "1"

    # A blank start command stops process supervision entirely (see
    # agent/commands.py::_apply_configure) — this form has no way to show
    # what's currently running (it's local-only state on the Agent's own
    # settings.json until the Admin Panel has sent a configure command of
    # its own; see Instance.last_kiosk_start_command's docstring), so a
    # blank submission is exactly as likely to be "someone only meant to
    # change the sync URL and forgot this field was here" as it is to be
    # a deliberate clear. Require an explicit checkbox before treating it
    # as the latter — real incident (2026-09-09): this very gap almost
    # stopped a live kiosk process that was only ever meant to get an
    # inventory sync URL added.
    if not start_command and not confirm_clear:
        flash(
            "Start command was left blank, which stops the kiosk process entirely — "
            "tick \"Yes, stop the kiosk process\" if that's really what you want, "
            "otherwise re-enter the current start command (see the pre-filled value "
            "if one was remembered, or check the Agent's settings.json on the machine "
            "itself). Nothing was changed.",
            "error",
        )
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    _queue_command(instance, "configure", payload={
        "kiosk_start_command": start_command,
        "kiosk_working_dir": working_dir,
        "kiosk_health_check_url": health_check_url,
        "kiosk_health_check_command": health_check_command,
        "kiosk_inventory_sync_url": inventory_sync_url,
    })
    instance.last_kiosk_start_command = start_command or None
    instance.last_kiosk_working_dir = working_dir or None
    instance.last_kiosk_health_check_url = health_check_url or None
    instance.last_kiosk_health_check_command = health_check_command or None
    instance.last_kiosk_inventory_sync_url = inventory_sync_url or None
    log_action(company, current_user, "kiosk_configure_requested",
               f"{instance.display_name()}: {start_command or '(cleared)'}")
    db.session.commit()
    flash("Configuration queued — the Agent will apply it (and start the process) on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/run-command", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def run_command(company_id, instance_id):
    """Generic remote execution — real command execution on the kiosk
    machine via the same authenticated command channel as start/stop/
    restart/configure, not a remote-desktop/screen-sharing session (no
    tunnel server exists for that — see the "Request remote access token"
    button elsewhere on this page, which is honest that it only tracks the
    request). This is genuinely capable of "add or install things on the
    kiosk remotely" (run an msiexec, a pip install, a PowerShell one-liner)
    without expanding the system's actual trust boundary: an admin with
    manage_instances permission can already push arbitrary code to this
    exact machine via an Update package, just with more ceremony and
    latency. Output is returned through the same result_message field the
    Recent Commands table already renders - no new UI surface needed to
    see what happened.
    """
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    if _blocked_while_suspended(instance):
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    command_text = request.form.get("command", "").strip()
    if not command_text:
        flash("Enter a command to run.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    _queue_command(instance, "run_command", payload={"command": command_text})
    log_action(company, current_user, "run_command_requested", f"{instance.display_name()}: {command_text}")
    db.session.commit()
    flash("Command queued — the Agent will run it (and report output) on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


def _inventory_custom_fields_from_form(fields, form) -> dict:
    """Shared by both this blueprint and client_portal.py — extracts
    {field_key: value} for a type's custom fields from a submitted form,
    coercing booleans/numbers per field_type. Mirrors kiosk_app's
    inventory.py::_custom_fields_form exactly (duplicated per OWNERSHIP.md
    rather than imported)."""
    values = {}
    for f in fields:
        raw = form.get(f"field_{f['key']}")
        if f["field_type"] == "boolean":
            values[f["key"]] = (raw == "on")
        elif f["field_type"] == "number":
            try:
                values[f["key"]] = float(raw) if raw not in (None, "") else None
            except ValueError:
                values[f["key"]] = raw
        else:
            values[f["key"]] = raw
    return values


# ---------------------------------------------------------------------------
# Items & Tools: equipment attached to this kiosk (built into the instance
# page alongside Connection, per design — not a separate top-level section)
# ---------------------------------------------------------------------------

def _apply_equipment_fields(equipment, form) -> str:
    """Shared by add/edit in both this blueprint and client_portal.py —
    applies every field an admin/client can set by hand, including the
    Kiosk App inventory sync fields (models.py's InstanceEquipmentItem;
    see agent/inventory_sync.py for what actually reads sku/quantity/etc.
    on the wire). Returns an error message, or "" if applied successfully
    — caller still owns add-to-session/commit."""
    kind = form.get("kind", equipment.kind)
    if kind not in EQUIPMENT_KINDS:
        kind = equipment.kind or "item"
    name = form.get("name", "").strip()
    if not name:
        return "Name is required."
    status = form.get("status", equipment.status)
    if status not in EQUIPMENT_STATUSES:
        status = equipment.status or "active"

    equipment.kind = kind
    equipment.name = name
    equipment.description = form.get("description", "").strip() or None
    equipment.serial_number = form.get("serial_number", "").strip() or None
    equipment.status = status
    # Freeform "type" — the Items & Tools accordion groups by this on
    # EITHER kind (see _group_equipment_by_category below); the two
    # EQUIPMENT_CATEGORIES values are only ever offered as suggestions,
    # not enforced, since kiosk_app's own category enum for kind=="item"
    # is a separate, kiosk-side concern (see the column's own note).
    equipment.category = form.get("category", "").strip() or None

    def _float(key):
        raw = form.get(key, "").strip()
        try:
            return float(raw) if raw else None
        except ValueError:
            return None

    def _int(key):
        raw = form.get(key, "").strip()
        try:
            return int(raw) if raw else None
        except ValueError:
            return None

    if kind == "item":
        equipment.sku = form.get("sku", "").strip() or None
        equipment.quantity = _int("quantity")
        equipment.unit = form.get("unit", "").strip() or None
        equipment.unit_cost = _float("unit_cost")
    else:
        tool_status = form.get("tool_status", "").strip() or None
        if tool_status in TOOL_STATUSES:
            equipment.tool_status = tool_status
        equipment.current_project = form.get("current_project", "").strip() or None
        equipment.purchase_price = _float("purchase_price")

    return ""


def _group_equipment_by_category(equipment_items, kind: str):
    """Splits one instance's full equipment_items list (mixed kinds) down
    to just `kind`, grouped by category — blank/None collapses to
    "Uncategorized". Returns an ordered list of (label, [rows]) tuples,
    alphabetical by label with "Uncategorized" always last, so the Items
    & Tools accordion has a stable, predictable section order across
    requests rather than reflecting query/insertion order."""
    groups = {}
    for row in equipment_items:
        if row.kind != kind:
            continue
        label = (row.category or "").strip() or "Uncategorized"
        groups.setdefault(label, []).append(row)
    return sorted(groups.items(), key=lambda kv: (kv[0] == "Uncategorized", kv[0].lower()))


def _slugify_username(name: str, instance_id: int) -> str:
    """Derives a Kiosk-App-safe username from a display name (e.g. "Jamie
    (till 2)" -> "jamie"), only ever used when an admin/client adds a
    local user without typing one themselves — see add_local_user. Never
    silently overwrites a blank username someone cleared on purpose during
    an edit (see _apply_local_user_sync_fields, which is not this)."""
    import re
    base = re.sub(r"[^a-z0-9]+", "", name.lower()) or "user"
    username = base
    n = 1
    while InstanceLocalUser.query.filter_by(
        instance_id=instance_id, username=username, deleted_at=None
    ).first() is not None:
        n += 1
        username = f"{base}{n}"
    return username


def _apply_local_user_sync_fields(local_user, form) -> str:
    """Shared by add/edit — the Kiosk App sync fields (username/role) on
    top of the pre-existing name/status/PIN handling, which stays inline
    in each route since it also needs _validate_new_pin's own error path.
    Returns an error message, or "" if applied successfully."""
    username = form.get("username", "").strip() or None
    if username != local_user.username:
        if username is not None:
            # deleted_at.is_(None): a removed local user's old username is
            # free to reuse — see InstanceLocalUser's partial unique index.
            clash = InstanceLocalUser.query.filter(
                InstanceLocalUser.instance_id == local_user.instance_id,
                InstanceLocalUser.username == username,
                InstanceLocalUser.deleted_at.is_(None),
                InstanceLocalUser.id != (local_user.id or -1),
            ).first()
            if clash is not None:
                return f"Username '{username}' is already used by another local user on this instance."
        local_user.username = username
    # Freeform, not a fixed-list check: kiosk roles are user-defined now
    # (kiosk_app/app/role_admin.py). LOCAL_USER_ROLES survives only as a
    # datalist suggestion (see the built-ins plus whatever a real Roles
    # panel poll has added — see instances.py's own role listing route).
    role = form.get("role", "").strip()
    if role:
        local_user.role = role
    return ""


def _get_equipment_or_404(instance, equipment_id):
    equipment = InstanceEquipmentItem.query.filter_by(
        public_id=equipment_id, instance_id=instance.id
    ).first()
    if equipment is None:
        abort(404)
    return equipment


@bp.route("/<instance_id>/equipment/add", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def add_equipment(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    equipment = InstanceEquipmentItem(instance_id=instance.id, added_by_id=current_user.id)
    error = _apply_equipment_fields(equipment, request.form)
    if error:
        flash(error, "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    db.session.add(equipment)
    log_action(company, current_user, f"{equipment.kind}_added", f"{instance.display_name()}: {equipment.name}")
    db.session.commit()
    flash(f"{'Tool' if equipment.kind == 'tool' else 'Item'} added.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/equipment/<equipment_id>/edit", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def edit_equipment(company_id, instance_id, equipment_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    equipment = _get_equipment_or_404(instance, equipment_id)

    error = _apply_equipment_fields(equipment, request.form)
    if error:
        flash(error, "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    log_action(company, current_user, f"{equipment.kind}_edited", f"{instance.display_name()}: {equipment.name}")
    db.session.commit()
    flash("Saved.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/equipment/<equipment_id>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def delete_equipment(company_id, instance_id, equipment_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    equipment = _get_equipment_or_404(instance, equipment_id)

    # Soft-delete, not a hard delete — a tombstone (deleted_at) is what lets
    # the removal actually reach a synced Kiosk App counterpart (see
    # agent/inventory_sync.py); a hard delete here would just look like
    # "never existed" to a Kiosk App that hasn't polled since, which would
    # re-create it right back on its next sync.
    equipment.deleted_at = datetime.utcnow()
    log_action(company, current_user, f"{equipment.kind}_removed", f"{instance.display_name()}: {equipment.name}")
    db.session.commit()
    flash("Removed.", "info")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/equipment/export.csv")
@login_required
@load_company_context
def export_equipment_csv(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=EQUIPMENT_CSV_FIELDS)
    writer.writeheader()
    for eq in InstanceEquipmentItem.query.filter_by(instance_id=instance.id, deleted_at=None).all():
        writer.writerow(eq.to_csv_row())

    filename = f"{instance.display_name().replace(' ', '_')}_equipment.csv"
    return Response(
        buf.getvalue(), mimetype="text/csv",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


@bp.route("/<instance_id>/equipment/import", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def import_equipment_csv(company_id, instance_id):
    """Adds rows from the uploaded CSV as new equipment — does not touch or
    remove anything already here. Matching columns:
    kind,name,description,serial_number,status,category (kind/status
    default to 'item'/'active' if missing or invalid, so a minimal
    'name'-only CSV still imports cleanly; category is optional and
    freeform — it's what groups rows into the Items & Tools accordion, so
    a bulk import worth organizing later should set it, but nothing
    requires it up front)."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    f = request.files.get("file")
    if f is None or f.filename == "":
        flash("Choose a CSV file.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    try:
        text = f.stream.read().decode("utf-8-sig")
    except UnicodeDecodeError:
        flash("Couldn't read that file as UTF-8 CSV.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    reader = csv.DictReader(io.StringIO(text))
    created, skipped = 0, 0
    for row in reader:
        name = (row.get("name") or "").strip()
        if not name:
            skipped += 1
            continue
        kind = (row.get("kind") or "item").strip().lower()
        if kind not in EQUIPMENT_KINDS:
            kind = "item"
        status = (row.get("status") or "active").strip().lower()
        if status not in EQUIPMENT_STATUSES:
            status = "active"
        db.session.add(InstanceEquipmentItem(
            instance_id=instance.id, kind=kind, name=name,
            description=(row.get("description") or "").strip() or None,
            serial_number=(row.get("serial_number") or "").strip() or None,
            category=(row.get("category") or "").strip() or None,
            status=status, added_by_id=current_user.id,
        ))
        created += 1

    log_action(company, current_user, "equipment_imported", f"{instance.display_name()}: {created} row(s)")
    db.session.commit()
    flash(f"Imported {created} item(s)/tool(s)." + (f" Skipped {skipped} row(s) missing a name." if skipped else ""), "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/equipment/backup.json")
@login_required
@load_company_context
def backup_equipment(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    payload = {
        "instance": instance.display_name(),
        "exported_at": datetime.utcnow().isoformat() + "Z",
        "equipment": [
            eq.to_backup_dict()
            for eq in InstanceEquipmentItem.query.filter_by(instance_id=instance.id, deleted_at=None).all()
        ],
    }
    filename = f"{instance.display_name().replace(' ', '_')}_equipment_backup.json"
    return Response(
        json.dumps(payload, indent=2), mimetype="application/json",
        headers={"Content-Disposition": f"attachment; filename={filename}"},
    )


@bp.route("/<instance_id>/equipment/restore", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def restore_equipment(company_id, instance_id):
    """Adds every equipment entry from the uploaded backup JSON as new
    rows — deliberately additive, never deletes or overwrites existing
    equipment, so restoring a backup can never silently wipe out anything
    added since that backup was taken. Run 'Export' first and review if
    you specifically want a clean slate, then remove old rows by hand."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    f = request.files.get("file")
    if f is None or f.filename == "":
        flash("Choose a backup JSON file.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    try:
        data = json.loads(f.stream.read().decode("utf-8"))
        rows = data.get("equipment", []) if isinstance(data, dict) else []
    except (ValueError, UnicodeDecodeError):
        flash("That file isn't valid backup JSON.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    restored = 0
    for row in rows:
        name = (row.get("name") or "").strip()
        if not name:
            continue
        kind = row.get("kind") if row.get("kind") in EQUIPMENT_KINDS else "item"
        status = row.get("status") if row.get("status") in EQUIPMENT_STATUSES else "active"
        db.session.add(InstanceEquipmentItem(
            instance_id=instance.id, kind=kind, name=name,
            description=row.get("description") or None,
            serial_number=row.get("serial_number") or None,
            category=(row.get("category") or "").strip() or None,
            status=status, added_by_id=current_user.id,
        ))
        restored += 1

    log_action(company, current_user, "equipment_restored", f"{instance.display_name()}: {restored} row(s)")
    db.session.commit()
    flash(f"Restored {restored} item(s)/tool(s) from backup.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

# ---------------------------------------------------------------------------
# Local kiosk users: the people who operate this specific kiosk terminal
# day-to-day. Distinct from company Users/members (fleet managers logging
# into this Admin Panel) — no email, no dashboard login, just a name and
# an optional PIN, managed here since there's no real Kiosk Application
# yet with its own on-device management screen.
# ---------------------------------------------------------------------------

def _get_local_user_or_404(instance, local_user_id):
    local_user = InstanceLocalUser.query.filter_by(
        public_id=local_user_id, instance_id=instance.id
    ).first()
    if local_user is None:
        abort(404)
    return local_user


def _validate_new_pin(local_user, pin, pin_confirm):
    """Returns an error message string, or None if the PIN is acceptable.
    Shared by add and edit/reset — same rules as the web dashboard's own
    PIN setup (models.py's is_valid_pin_format), same no-reuse-via-history
    check as User.pin_was_used_before, just against this local user's own
    history instead."""
    if not pin:
        return None  # optional — a local user can exist with no PIN set yet
    if not is_valid_pin_format(pin):
        return f"PIN must be {PIN_MIN_LENGTH} to {PIN_MAX_LENGTH} digits, numbers only."
    if pin != pin_confirm:
        return "PINs do not match."
    if local_user.pin_was_used_before(pin):
        return "That PIN has been used before for this local user. Choose a different one."
    return None


@bp.route("/<instance_id>/local-users/add", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def add_local_user(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    name = request.form.get("name", "").strip()
    status = request.form.get("status", "active")
    pin = request.form.get("pin", "").strip()
    pin_confirm = request.form.get("pin_confirm", "").strip()

    if not name:
        flash("Name is required.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    if status not in LOCAL_USER_STATUSES:
        status = "active"

    local_user = InstanceLocalUser(
        instance_id=instance.id, name=name, status=status, added_by_id=current_user.id,
    )
    error = _apply_local_user_sync_fields(local_user, request.form)
    if error:
        flash(error, "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    if not local_user.username:
        local_user.username = _slugify_username(name, instance.id)
    if pin:
        error = _validate_new_pin(local_user, pin, pin_confirm)
        if error:
            flash(error, "danger")
            return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
        local_user.set_pin(pin)

    db.session.add(local_user)
    log_action(company, current_user, "local_kiosk_user_added", f"{instance.display_name()}: {name}")
    db.session.commit()
    flash(f"Added {name}.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/local-users/<local_user_id>/edit", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def edit_local_user(company_id, instance_id, local_user_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    local_user = _get_local_user_or_404(instance, local_user_id)

    name = request.form.get("name", "").strip()
    if not name:
        flash("Name is required.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    status = request.form.get("status", local_user.status)
    pin = request.form.get("pin", "").strip()
    pin_confirm = request.form.get("pin_confirm", "").strip()

    error = _apply_local_user_sync_fields(local_user, request.form)
    if error:
        flash(error, "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    if pin:
        error = _validate_new_pin(local_user, pin, pin_confirm)
        if error:
            flash(error, "danger")
            return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
        local_user.set_pin(pin)

    local_user.name = name
    if status in LOCAL_USER_STATUSES:
        local_user.status = status

    log_action(company, current_user, "local_kiosk_user_edited", f"{instance.display_name()}: {name}")
    db.session.commit()
    flash("Saved.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/local-users/<local_user_id>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def delete_local_user(company_id, instance_id, local_user_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    local_user = _get_local_user_or_404(instance, local_user_id)

    # Soft-delete tombstone — see delete_equipment above for why.
    local_user.deleted_at = datetime.utcnow()
    log_action(company, current_user, "local_kiosk_user_removed", f"{instance.display_name()}: {local_user.name}")
    db.session.commit()
    flash("Removed.", "info")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


# ---------------------------------------------------------------------------
# Roles — remote control of kiosk_app's own Role/RolePermission/
# RoleSidebarPermission tables (see kiosk_app/app/role_admin.py). The list
# shown here is InstanceRole, a read-only cache refreshed by
# agent/inventory_sync.py each pass — actual changes go out over the
# InstanceCommand channel (agent/commands.py's role_* handlers, which
# relay straight to kiosk_app/app/blueprints/sync_api.py's role routes) and
# land in that cache on the Agent's next sync pass, same delay as any
# other inventory sync change.
# ---------------------------------------------------------------------------

@bp.route("/<instance_id>/roles/create", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def create_role(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    name = request.form.get("name", "").strip()
    if not name:
        flash("Role name is required.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    _queue_command(instance, "role_create", payload={
        "name": name, "description": request.form.get("description", "").strip() or None,
        "actor": current_user.email,
    })
    log_action(company, current_user, "role_create_requested", f"{instance.display_name()}: {name}")
    db.session.commit()
    flash(f"Role '{name}' queued — the Agent will create it on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/roles/<role_name>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def delete_role(company_id, instance_id, role_name):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "role_delete", payload={"name": role_name, "actor": current_user.email})
    log_action(company, current_user, "role_delete_requested", f"{instance.display_name()}: {role_name}")
    db.session.commit()
    flash(f"Delete for '{role_name}' queued.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/roles/<role_name>/login", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def set_role_login(company_id, instance_id, role_name):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    enabled = request.form.get("login_enabled") == "on"
    _queue_command(instance, "role_set_login", payload={
        "name": role_name, "enabled": enabled, "actor": current_user.email,
    })
    log_action(company, current_user, "role_login_toggle_requested", f"{instance.display_name()}: {role_name}={enabled}")
    db.session.commit()
    flash(f"Login change for '{role_name}' queued.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/roles/<role_name>/sidebar", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def set_role_sidebar(company_id, instance_id, role_name):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    visibility = {key: (request.form.get(f"item_{key}") == "on") for key in SIDEBAR_ITEM_KEYS}
    _queue_command(instance, "role_set_sidebar", payload={
        "name": role_name, "visibility": visibility, "actor": current_user.email,
    })
    log_action(company, current_user, "role_sidebar_requested", f"{instance.display_name()}: {role_name}")
    db.session.commit()
    flash(f"Sidebar change for '{role_name}' queued.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/sidebar/order", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def set_sidebar_order(company_id, instance_id):
    """Sidebar builder (Track 2): queues the new instance-wide nav order —
    see /root/.claude/plans/sprightly-meandering-whisper.md. `order` is a
    comma-separated list of NavEntry keys in the new order, posted by the
    drag-drop list's JS; the cached InstanceNavEntry rows themselves get
    refreshed on the next inventory_sync pass once the Agent relays this
    and re-reads the kiosk's own layout, same as a role edit."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    order = [k.strip() for k in request.form.get("order", "").split(",") if k.strip()]
    if not order:
        flash("No order was submitted.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    _queue_command(instance, "sidebar_reorder", payload={"order": order, "actor": current_user.email})
    log_action(company, current_user, "sidebar_reorder_requested", instance.display_name())
    db.session.commit()
    flash("Sidebar order queued — the Agent will apply it on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/sidebar")
@login_required
@load_company_context
@permission_required("operate_kiosk")
def sidebar_page(company_id, instance_id):
    """Sidebar builder (Track 2) — drag-drop reorder against the cached
    InstanceNavEntry rows; posts to set_sidebar_order above, which queues
    the actual sidebar_reorder command."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    nav_entries = InstanceNavEntry.query.filter_by(instance_id=instance.id).order_by(InstanceNavEntry.sort_order).all()
    return render_template("instances/sidebar.html", company=company, instance=instance, nav_entries=nav_entries)


# ---------------------------------------------------------------------------
# Generic inventory type system (Track 2 — see
# /root/.claude/plans/sprightly-meandering-whisper.md). Additive: the
# existing Items & Tools section above (InstanceEquipmentItem) is
# completely untouched — this is new, separate surface area reached via a
# "Manage" button, gated the same way (operate_kiosk).
# ---------------------------------------------------------------------------

@bp.route("/<instance_id>/inventory")
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_types(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    return render_template(
        "instances/inventory_types.html", company=company, instance=instance,
        types=inventory_admin.all_types_state(instance), field_types=inventory_admin.FIELD_TYPES,
    )


@bp.route("/<instance_id>/inventory/types/add", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_add_type(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message, _t = inventory_admin.create_type(
        instance, request.form.get("name", ""), request.form.get("description", ""),
    )
    if ok:
        log_action(company, current_user, "item_type_create", f"{instance.display_name()}: {request.form.get('name', '')}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_types", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/inventory/types/<type_key>/edit", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_edit_type(company_id, instance_id, type_key):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message = inventory_admin.update_type(
        instance, type_key, request.form.get("name", ""), request.form.get("description", ""),
    )
    if ok:
        log_action(company, current_user, "item_type_update", f"{instance.display_name()}: {type_key}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_types", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/inventory/types/<type_key>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_delete_type(company_id, instance_id, type_key):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message = inventory_admin.delete_type(instance, type_key)
    if ok:
        log_action(company, current_user, "item_type_delete", f"{instance.display_name()}: {type_key}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_types", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/inventory/types/<type_key>/fields/add", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_add_field(company_id, instance_id, type_key):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    options = [o.strip() for o in request.form.get("options", "").split(",") if o.strip()]
    ok, message = inventory_admin.add_field(
        instance, type_key, request.form.get("label", ""),
        request.form.get("field_type", "text"), options=options, required=(request.form.get("required") == "on"),
    )
    if ok:
        log_action(company, current_user, "item_type_field_add", f"{instance.display_name()}: {type_key}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_types", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/inventory/types/<type_key>/fields/<int:field_id>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_delete_field(company_id, instance_id, type_key, field_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message = inventory_admin.delete_field(instance, field_id)
    if ok:
        log_action(company, current_user, "item_type_field_delete", f"{instance.display_name()}: {type_key}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_types", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/inventory/type/<type_key>")
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_list_type(company_id, instance_id, type_key):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=type_key, deleted_at=None).first()
    if item_type is None:
        abort(404)
    items = InstanceInventoryItem.query.filter_by(
        instance_id=instance.id, item_type_key=type_key, deleted_at=None
    ).order_by(InstanceInventoryItem.name).all()
    fields = inventory_admin.type_state(instance, type_key)["fields"]
    return render_template(
        "instances/inventory_list.html", company=company, instance=instance, item_type=item_type,
        items=items, fields=fields, measurement_kinds=measurement.MEASUREMENT_KINDS,
        all_types=InstanceItemType.query.filter_by(instance_id=instance.id, deleted_at=None).order_by(InstanceItemType.name).all(),
    )


@bp.route("/<instance_id>/inventory/type/<type_key>/add", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_add_item(company_id, instance_id, type_key):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    fields = inventory_admin.type_state(instance, type_key)["fields"] if inventory_admin.type_state(instance, type_key) else []
    custom_values = _inventory_custom_fields_from_form(fields, request.form)
    ok, message, _item = inventory_admin.create_item(
        instance, current_user.id, type_key, request.form.get("name", ""),
        sku=request.form.get("sku"), serial_number=request.form.get("serial_number"),
        quantity_value=(float(request.form["quantity_value"]) if request.form.get("quantity_value") else None),
        quantity_unit=request.form.get("quantity_unit") or None, custom_fields=custom_values,
        status=request.form.get("status", "active"),
    )
    if ok:
        log_action(company, current_user, "inventory_item_create", f"{instance.display_name()}: {request.form.get('name', '')}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_list_type", company_id=company.public_id, instance_id=instance.public_id, type_key=type_key))


@bp.route("/<instance_id>/inventory/<int:item_id>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_delete_item(company_id, instance_id, item_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id).first()
    type_key = item.item_type_key if item else None
    item_name = item.name if item else ""
    ok, message = inventory_admin.delete_item(instance, item_id)
    if ok:
        log_action(company, current_user, "inventory_item_delete", f"{instance.display_name()}: {item_name}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    if type_key:
        return redirect(url_for("instances.inventory_list_type", company_id=company.public_id, instance_id=instance.public_id, type_key=type_key))
    return redirect(url_for("instances.inventory_types", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/inventory/bulk", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_bulk_action(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    type_key = request.form.get("type_key", "")
    item_ids = [int(i) for i in request.form.getlist("item_ids") if i.isdigit()]
    action = request.form.get("action", "")
    if not item_ids:
        flash("No items were selected.", "danger")
        return redirect(url_for("instances.inventory_list_type", company_id=company.public_id, instance_id=instance.public_id, type_key=type_key))

    if action == "delete":
        ok, message, _c = inventory_admin.bulk_delete(instance, item_ids)
        audit_action = "inventory_item_bulk_delete"
    elif action == "set_status":
        ok, message, _c = inventory_admin.bulk_update(instance, item_ids, status=request.form.get("status"))
        audit_action = "inventory_item_bulk_update"
    elif action == "set_unit":
        ok, message, _c = inventory_admin.bulk_update(instance, item_ids, quantity_unit=request.form.get("quantity_unit"))
        audit_action = "inventory_item_bulk_update"
    elif action == "set_type":
        ok, message, _c = inventory_admin.bulk_update(instance, item_ids, item_type_key=request.form.get("new_type_key"))
        audit_action = "inventory_item_bulk_update"
    else:
        ok, message = False, f"Unknown bulk action '{action}'."
        audit_action = None

    if ok and audit_action:
        log_action(company, current_user, audit_action, f"{instance.display_name()}: {len(item_ids)} item(s), action={action}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_list_type", company_id=company.public_id, instance_id=instance.public_id, type_key=type_key))


@bp.route("/<instance_id>/inventory/<int:item_id>/manage")
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_manage_item(company_id, instance_id, item_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id).first()
    if item is None:
        abort(404)
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=item.item_type_key).first()
    fields = inventory_admin.type_state(instance, item.item_type_key)["fields"] if item_type else []
    current_kind = measurement.kind_for_unit(item.quantity_unit) if item.quantity_unit else None
    return render_template(
        "instances/inventory_manage.html", company=company, instance=instance, item=item, item_type=item_type,
        fields=fields, custom_values=item.custom_fields_dict(),
        all_types=InstanceItemType.query.filter_by(instance_id=instance.id, deleted_at=None).order_by(InstanceItemType.name).all(),
        measurement_kinds=measurement.MEASUREMENT_KINDS, current_kind=current_kind, event_types=inventory_admin.EVENT_TYPES,
    )


@bp.route("/<instance_id>/inventory/<int:item_id>/manage/save", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_save_item(company_id, instance_id, item_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id).first()
    if item is None:
        abort(404)
    fields = inventory_admin.type_state(instance, item.item_type_key)["fields"] if item.item_type_key else []
    custom_values = _inventory_custom_fields_from_form(fields, request.form)
    ok, message = inventory_admin.update_item(
        instance, item_id, name=request.form.get("name"), sku=request.form.get("sku"),
        serial_number=request.form.get("serial_number"), status=request.form.get("status"),
        custom_fields=custom_values, checked_out_by_name=request.form.get("checked_out_by_name"),
        current_project=request.form.get("current_project"),
    )
    if ok:
        log_action(company, current_user, "inventory_item_update", f"{instance.display_name()}: {item.name}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_manage_item", company_id=company.public_id, instance_id=instance.public_id, item_id=item_id))


@bp.route("/<instance_id>/inventory/<int:item_id>/manage/measurement", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_set_measurement(company_id, instance_id, item_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message = inventory_admin.change_measurement(instance, item_id, request.form.get("quantity_unit", ""))
    if ok:
        log_action(company, current_user, "inventory_item_measurement_change", f"{instance.display_name()}: item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_manage_item", company_id=company.public_id, instance_id=instance.public_id, item_id=item_id))


@bp.route("/<instance_id>/inventory/<int:item_id>/manage/type", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_set_type(company_id, instance_id, item_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message = inventory_admin.change_type(instance, item_id, request.form.get("item_type_key", ""))
    if ok:
        log_action(company, current_user, "inventory_item_type_change", f"{instance.display_name()}: item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_manage_item", company_id=company.public_id, instance_id=instance.public_id, item_id=item_id))


@bp.route("/<instance_id>/inventory/<int:item_id>/manage/generate-sku", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_generate_sku(company_id, instance_id, item_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message = inventory_admin.generate_sku(instance, item_id)
    if ok:
        log_action(company, current_user, "inventory_item_sku_generated", f"{instance.display_name()}: item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_manage_item", company_id=company.public_id, instance_id=instance.public_id, item_id=item_id))


@bp.route("/<instance_id>/inventory/<int:item_id>/manage/generate-serial", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_generate_serial(company_id, instance_id, item_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message = inventory_admin.generate_serial_number(instance, item_id)
    if ok:
        log_action(company, current_user, "inventory_item_serial_generated", f"{instance.display_name()}: item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_manage_item", company_id=company.public_id, instance_id=instance.public_id, item_id=item_id))


@bp.route("/<instance_id>/inventory/<int:item_id>/manage/event", methods=["POST"])
@login_required
@load_company_context
@permission_required("operate_kiosk")
def inventory_log_event(company_id, instance_id, item_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    ok, message = inventory_admin.log_event(
        instance, current_user.email, item_id, request.form.get("event_type", ""),
        project=request.form.get("project"), detail=request.form.get("detail"),
    )
    if ok:
        log_action(company, current_user, "inventory_item_event", f"{instance.display_name()}: item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("instances.inventory_manage_item", company_id=company.public_id, instance_id=instance.public_id, item_id=item_id))
