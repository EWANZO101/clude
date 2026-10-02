"""Client Portal: a second, separate front door for a customer's own end
users — deliberately outside the Company/CompanyMembership system (see
models.py's "Client Portal" section for why). A ClientUser signs themselves
up here, then has no access to anything until a platform admin assigns them
to one or more specific instances from Platform -> Clients. From then on
they can operate exactly what a company's "operator" role can (start/stop/
restart, push an update, Items & Tools, Local Kiosk Users) on just those
instances — never company settings, members, config, or anything else.

Deliberately does not extend the staff-side base.html shell (Platform/
Company nav, "current_user.is_platform_admin" checks, etc. — none of that
applies to a ClientUser) — see templates/client_portal/_shell.html.
"""
import csv
import io
import json
from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, abort, Response
from flask_login import login_required, current_user, login_user, logout_user
from email_validator import validate_email, EmailNotValidError

from app.extensions import db
from app.models import (
    ClientUser, ClientInstanceAccess, Instance, InstanceEquipmentItem, InstanceLocalUser,
    EQUIPMENT_KINDS, EQUIPMENT_STATUSES, EQUIPMENT_CSV_FIELDS, EQUIPMENT_CATEGORIES, TOOL_STATUSES,
    LOCAL_USER_STATUSES, LOCAL_USER_ROLES, InstanceRole, SIDEBAR_ITEM_KEYS,
    InstanceItemType, InstanceInventoryItem, InstanceNavEntry,
    is_valid_pin_format, PIN_MIN_LENGTH, PIN_MAX_LENGTH,
    get_client_portal_service_user, log_client_action,
    ChangeRequest,
    InstanceBackup,
)
from app.blueprints.instances import (
    _queue_command, _schedule_update, _usable_packages_for, _validate_new_pin,
    _apply_equipment_fields, _apply_local_user_sync_fields, _slugify_username,
    _inventory_custom_fields_from_form, _epoch_ms,
)
from app.long_poll import long_poll_response
from app.backup_scheduling import available_backup_timezones
from app import inventory_admin, measurement

bp = Blueprint("client_portal", __name__, url_prefix="/client")


class _ActingAsService:
    """Duck-typed stand-in for the `user` argument instances.py's
    _schedule_update() writes into a NOT-NULL `users.id` foreign key —
    carries the service account's real, FK-safe id, but the actual
    client's email for the human-readable text _schedule_update logs
    inline (deployment.append_log's "requested by ..."), so that message
    stays honest about who really did it even though the FK can't."""
    def __init__(self, id, email):
        self.id = id
        self.email = email


def client_required(view):
    from functools import wraps

    @wraps(view)
    def wrapper(*args, **kwargs):
        if not current_user.is_authenticated or not isinstance(current_user, ClientUser):
            return redirect(url_for("client_portal.login", next=request.path))
        return view(*args, **kwargs)
    return wrapper


def _get_instance_or_404(instance_id):
    instance = Instance.query.filter_by(public_id=instance_id).first()
    if instance is None or not current_user.has_access(instance):
        # 404, not 403 — never confirms an instance with this id exists at
        # all to a client who isn't assigned to it.
        abort(404)
    return instance


@bp.route("/signup", methods=["GET", "POST"])
def signup():
    if current_user.is_authenticated and isinstance(current_user, ClientUser):
        return redirect(url_for("client_portal.dashboard"))

    if request.method == "POST":
        full_name = request.form.get("full_name", "").strip()
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")
        password_confirm = request.form.get("password_confirm", "")

        errors = []
        if not full_name:
            errors.append("Full name is required.")
        try:
            email = validate_email(email, check_deliverability=False).normalized
        except EmailNotValidError as e:
            errors.append(str(e))
        if len(password) < 10:
            errors.append("Password must be at least 10 characters.")
        if password != password_confirm:
            errors.append("Passwords do not match.")
        if not errors and ClientUser.query.filter_by(email=email).first() is not None:
            errors.append("An account with that email already exists.")

        if errors:
            for e in errors:
                flash(e, "danger")
            return render_template("client_portal/signup.html", full_name=full_name, email=email)

        client = ClientUser(email=email, full_name=full_name)
        client.set_password(password)
        db.session.add(client)
        db.session.commit()

        login_user(client)
        flash("Account created. An admin needs to assign you to an instance before you'll see anything here.", "success")
        return redirect(url_for("client_portal.dashboard"))

    return render_template("client_portal/signup.html")


@bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated and isinstance(current_user, ClientUser):
        return redirect(url_for("client_portal.dashboard"))

    if request.method == "POST":
        email = request.form.get("email", "").strip().lower()
        password = request.form.get("password", "")

        client = ClientUser.query.filter_by(email=email).first()
        if client is None or not client.check_password(password):
            flash("Invalid email or password.", "danger")
            return render_template("client_portal/login.html", email=email)
        if not client.is_active:
            flash("This account has been disabled.", "danger")
            return render_template("client_portal/login.html", email=email)

        login_user(client)
        client.last_login_at = datetime.utcnow()
        db.session.commit()
        return redirect(url_for("client_portal.dashboard"))

    return render_template("client_portal/login.html")


@bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("Logged out.", "info")
    return redirect(url_for("client_portal.login"))


@bp.route("/instances/legal")
def legal():
    """Deliberately public, no login required — same "openness" reasoning
    as kiosk_app/app/templates/privacy_notice.html's own docstring: a
    privacy/data-protection notice that only logged-in users could reach
    would defeat its own purpose.

    IMPORTANT: this page is an engineering-drafted starting point, not
    legal advice. It describes what this software actually does
    (technical measures, retention, data subject request handling) —
    it does not and cannot certify a customer's overall compliance, which
    also depends on things entirely outside this system (a registered
    Information Officer/DPO, lawful-basis assessments, staff contracts,
    regulator registrations, etc.). See the template itself for the
    per-section callouts; have this reviewed by qualified counsel in each
    jurisdiction before relying on it or publishing it externally."""
    return render_template("client_portal/legal.html")


@bp.route("/")
@client_required
def dashboard():
    instances = current_user.instances()
    return render_template("client_portal/dashboard.html", instances=instances)


@bp.route("/status")
@client_required
def dashboard_status():
    """Long-polled from the My Instances page (see app/long_poll.py) so
    each instance's Online/Offline pill updates live."""
    client_user_id = current_user.id

    def build_payload():
        from app.models import ClientUser
        client_user = ClientUser.query.get(client_user_id)
        return {
            "instances": {
                i.public_id: {"connection_status": i.connection_status}
                for i in client_user.instances()
            }
        }

    return long_poll_response(build_payload)


@bp.route("/instances/<instance_id>")
@client_required
def instance_detail(instance_id):
    instance = _get_instance_or_404(instance_id)

    equipment_items = InstanceEquipmentItem.query.filter_by(
        instance_id=instance.id, deleted_at=None
    ).order_by(InstanceEquipmentItem.kind, InstanceEquipmentItem.name).all()
    local_users = InstanceLocalUser.query.filter_by(
        instance_id=instance.id, deleted_at=None
    ).order_by(InstanceLocalUser.name).all()
    roles = InstanceRole.query.filter_by(instance_id=instance.id).order_by(InstanceRole.name).all()
    role_names_for_datalist = sorted({r.name for r in roles} | set(LOCAL_USER_ROLES))

    from app.blueprints.instances import KIOSK_LIFECYCLE_COMMAND_TYPES, _group_equipment_by_category
    items_by_category = _group_equipment_by_category(equipment_items, "item")
    tools_by_category = _group_equipment_by_category(equipment_items, "tool")
    items_count = sum(len(rows) for _, rows in items_by_category)
    tools_count = sum(len(rows) for _, rows in tools_by_category)
    category_suggestions = sorted(
        {(e.category or "").strip() for e in equipment_items if e.category} | set(EQUIPMENT_CATEGORIES)
    )
    from app.models import InstanceCommand
    pending_kiosk_command = InstanceCommand.query.filter(
        InstanceCommand.instance_id == instance.id,
        InstanceCommand.command_type.in_(KIOSK_LIFECYCLE_COMMAND_TYPES),
        InstanceCommand.status.in_(("pending", "in_progress")),
    ).order_by(InstanceCommand.created_at.desc()).first()
    recent_kiosk_commands = InstanceCommand.query.filter_by(instance_id=instance.id).order_by(
        InstanceCommand.created_at.desc()
    ).limit(10).all()
    change_requests = ChangeRequest.query.filter_by(
        instance_id=instance.id, client_user_id=current_user.id
    ).order_by(ChangeRequest.created_at.desc()).all()
    backups = InstanceBackup.query.filter_by(instance_id=instance.id).order_by(
        InstanceBackup.created_at.desc()
    ).limit(50).all()

    current_config = instance.current_config()
    pending_config = instance.pending_config()
    try:
        current_config_dict = json.loads(current_config.config_json) if current_config else {}
    except ValueError:
        current_config_dict = {}
    if not isinstance(current_config_dict, dict):
        current_config_dict = {}

    from app.blueprints.instances import SUSPENDED_MESSAGE, _grouped_packages

    _instance_usable_packages = _usable_packages_for(instance)

    return render_template(
        "client_portal/instance_detail.html", instance=instance,
        suspended_message=SUSPENDED_MESSAGE,
        current_config_dict=current_config_dict, pending_config=pending_config,
        equipment_items=equipment_items, equipment_kinds=EQUIPMENT_KINDS, equipment_statuses=EQUIPMENT_STATUSES,
        items_by_category=items_by_category, tools_by_category=tools_by_category,
        items_count=items_count, tools_count=tools_count,
        equipment_categories=category_suggestions, tool_statuses=TOOL_STATUSES,
        local_users=local_users, local_user_statuses=LOCAL_USER_STATUSES, local_user_roles=role_names_for_datalist,
        pin_min_length=PIN_MIN_LENGTH, pin_max_length=PIN_MAX_LENGTH,
        pending_kiosk_command=pending_kiosk_command, recent_kiosk_commands=recent_kiosk_commands,
        usable_packages=_instance_usable_packages,
        usable_package_groups=_grouped_packages(_instance_usable_packages),
        active_deployment=instance.active_deployment(), deployment_history=instance.deployments,
        roles=roles, sidebar_item_keys=SIDEBAR_ITEM_KEYS,
        change_requests=change_requests,
        backups=backups, available_timezones=available_backup_timezones(),
    )


@bp.route("/instances/<instance_id>/backup-schedule", methods=["POST"])
@client_required
def update_backup_schedule(instance_id):
    instance = _get_instance_or_404(instance_id)

    time_str = (request.form.get("backup_time") or "").strip()
    timezone_name = (request.form.get("backup_timezone") or "").strip()
    local_daily = request.form.get("backup_local_daily_enabled") == "1"
    cloud_enabled = request.form.get("backup_cloud_enabled") == "1"

    if (local_daily or cloud_enabled) and (not time_str or not timezone_name):
        flash("Pick a time and timezone before turning a backup schedule on.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")

    if timezone_name and timezone_name not in available_backup_timezones():
        flash("Unrecognized timezone.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")

    if time_str:
        try:
            instance.backup_time = datetime.strptime(time_str, "%H:%M").time()
        except ValueError:
            flash("Backup time must be in HH:MM format.", "danger")
            return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")

    instance.backup_timezone = timezone_name or None
    instance.backup_local_daily_enabled = local_daily
    instance.backup_cloud_enabled = cloud_enabled

    log_client_action(current_user, instance, "backup_schedule_updated",
                       f"time={time_str or '—'} tz={timezone_name or '—'} local={local_daily} cloud={cloud_enabled}")
    db.session.commit()
    flash("Backup schedule saved.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")


@bp.route("/instances/<instance_id>/client-portal-port", methods=["POST"])
@client_required
def update_client_portal_port(instance_id):
    """Client-facing twin of the Admin Panel's own
    instances.py::set_client_portal_port — lets the customer enable/
    reconfigure their own Local Client Portal port themselves (it's about
    their own LAN, not something that should need a vendor round-trip).
    Same merge-not-replace InstanceConfig push/apply pipeline as
    tenant_name/auto_logout_minutes there. pushed_by_id uses the shared
    client-portal service user, not this ClientUser's own id —
    InstanceConfig.pushed_by_id is a FK into `users`, a completely
    different table from `client_users` (see get_client_portal_service_user;
    same reasoning as _queue_command's actor_id elsewhere)."""
    from app.models import InstanceConfig

    instance = _get_instance_or_404(instance_id)

    raw_port = (request.form.get("client_portal_port") or "").strip()
    port = None
    if raw_port:
        try:
            port = int(raw_port)
            if not (1 <= port <= 65535):
                raise ValueError
        except ValueError:
            flash("Enter a valid port number (1-65535), or leave blank to disable.", "danger")
            return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")

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
        instance_id=instance.id, version=last_version + 1,
        config_json=json.dumps(merged, sort_keys=True),
        pushed_by_id=get_client_portal_service_user().id, status="pending",
    )
    db.session.add(config)
    log_client_action(current_user, instance, "client_portal_port_updated", f"port={port}")
    db.session.commit()

    if port is None:
        flash("Local Client Portal disabled.", "success")
    else:
        flash(f"Local Client Portal port set to {port}.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")


@bp.route("/instances/<instance_id>/privacy-settings", methods=["POST"])
@client_required
def update_privacy_settings(instance_id):
    """POPIA settings for the customer's own kiosk — who their Information
    Officer is, and how long closed activity/checkout/issuance history is
    kept before automatic purging (see kiosk_app/app/retention.py, which is
    the thing that actually reads activity_log_retention_days out of this
    same config once the Agent applies it). Deliberately client-facing,
    same reasoning as client_portal_port above: this is the customer's own
    organization/policy, not something a vendor should have to set for
    them. Same merge-not-replace InstanceConfig push pipeline as
    client_portal_port."""
    from app.models import InstanceConfig

    # Must match kiosk_app/app/retention.py's own MIN_RETENTION_DAYS — that
    # module is what actually reads this value back out on the kiosk once
    # the Agent applies it, and enforces the same floor independently
    # there. Duplicated rather than imported: kiosk_app is a separate
    # deployable (ships to customer machines, not this cloud process) with
    # its own "app" package name that collides with this one's — see
    # tests/test_kiosk_app_smoke.py's sys.path/sys.modules juggling for why
    # the two are never imported into the same process.
    MIN_RETENTION_DAYS = 30

    instance = _get_instance_or_404(instance_id)

    contact = (request.form.get("information_officer_contact") or "").strip()
    raw_days = (request.form.get("activity_log_retention_days") or "").strip()
    days = None
    if raw_days:
        try:
            days = int(raw_days)
            if days < MIN_RETENTION_DAYS:
                raise ValueError
        except ValueError:
            flash(f"Retention must be a whole number of days, at least {MIN_RETENTION_DAYS}.", "danger")
            return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")

    base = instance.pending_config() or instance.current_config()
    try:
        merged = json.loads(base.config_json) if base else {}
    except ValueError:
        merged = {}
    if not isinstance(merged, dict):
        merged = {}

    if contact:
        merged["information_officer_contact"] = contact
    else:
        merged.pop("information_officer_contact", None)
    if days is None:
        merged.pop("activity_log_retention_days", None)
    else:
        merged["activity_log_retention_days"] = days

    existing_pending = instance.pending_config()
    if existing_pending is not None:
        existing_pending.status = "rejected"
        existing_pending.agent_message = "Superseded by a newer push before it was acknowledged."
        existing_pending.acknowledged_at = datetime.utcnow()

    last_version = db.session.query(db.func.max(InstanceConfig.version)).filter_by(
        instance_id=instance.id
    ).scalar() or 0
    config = InstanceConfig(
        instance_id=instance.id, version=last_version + 1,
        config_json=json.dumps(merged, sort_keys=True),
        pushed_by_id=get_client_portal_service_user().id, status="pending",
    )
    db.session.add(config)
    log_client_action(
        current_user, instance, "privacy_settings_updated",
        f"information_officer_contact={contact or '—'} activity_log_retention_days={days if days is not None else '—'}",
    )
    db.session.commit()

    flash("Privacy & data retention settings saved.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")


@bp.route("/instances/<instance_id>/backup-now", methods=["POST"])
@client_required
def backup_now(instance_id):
    instance = _get_instance_or_404(instance_id)
    service_user = get_client_portal_service_user()
    command = _queue_command(instance, "backup_now", payload={"source": "manual"}, actor_id=service_user.id)
    log_client_action(current_user, instance, "backup_now_requested")
    db.session.commit()
    flash("Backup requested — this shows up below once the Agent finishes it (usually within a minute or two).", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#backups")


@bp.route("/instances/<instance_id>/backups/<backup_id>/download")
@client_required
def download_backup(instance_id, backup_id):
    instance = _get_instance_or_404(instance_id)
    backup = InstanceBackup.query.filter_by(public_id=backup_id, instance_id=instance.id).first()
    if backup is None:
        abort(404)
    from flask import send_file
    return send_file(backup.file_path, as_attachment=True, download_name=backup.filename)


@bp.route("/instances/<instance_id>/backup-status")
@client_required
def backup_status(instance_id):
    from app.models import InstanceCommand
    instance = _get_instance_or_404(instance_id)
    instance_pk = instance.id
    instance_public_id = instance.public_id

    def build_payload():
        pending_cmd = InstanceCommand.query.filter(
            InstanceCommand.instance_id == instance_pk,
            InstanceCommand.command_type == "backup_now",
            InstanceCommand.status.in_(("pending", "in_progress")),
        ).order_by(InstanceCommand.created_at.desc()).first()

        last_cmd = InstanceCommand.query.filter(
            InstanceCommand.instance_id == instance_pk,
            InstanceCommand.command_type == "backup_now",
            InstanceCommand.status.in_(("success", "failed")),
        ).order_by(InstanceCommand.created_at.desc()).first()

        backups = InstanceBackup.query.filter_by(instance_id=instance_pk).order_by(
            InstanceBackup.created_at.desc()
        ).limit(50).all()

        return {
            "pending": (
                {
                    "status": pending_cmd.status,
                    "queued_at": _epoch_ms(pending_cmd.created_at),
                    "started_at": _epoch_ms(pending_cmd.started_at) if pending_cmd.started_at else None,
                }
                if pending_cmd else None
            ),
            "last_result": (
                {
                    "id": last_cmd.public_id,
                    "status": last_cmd.status,
                    "message": last_cmd.result_message,
                    "completed_at": _epoch_ms(last_cmd.acked_at) if last_cmd.acked_at else None,
                }
                if last_cmd else None
            ),
            "backups": [
                {
                    "id": b.public_id, "filename": b.filename,
                    "size_mb": round(b.file_size / 1024 / 1024, 2),
                    "source": b.source, "created_at": b.created_at.strftime("%Y-%m-%d %H:%M UTC"),
                    "contents_summary": json.loads(b.contents_summary) if b.contents_summary else None,
                    "download_url": url_for(
                        "client_portal.download_backup",
                        instance_id=instance_public_id, backup_id=b.public_id,
                    ),
                }
                for b in backups
            ],
        }

    return long_poll_response(build_payload)


@bp.route("/instances/<instance_id>/requests/add", methods=["POST"])
@client_required
def add_change_request(instance_id):
    instance = _get_instance_or_404(instance_id)
    title = (request.form.get("title") or "").strip()
    description = (request.form.get("description") or "").strip()
    if not title or not description:
        flash("Title and description are both required.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#requests")

    req = ChangeRequest(
        client_user_id=current_user.id, instance_id=instance.id,
        title=title, description=description,
    )
    db.session.add(req)
    log_client_action(current_user, instance, "change_request_submitted", detail=title)
    db.session.commit()
    flash("Your request has been submitted.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id) + "#requests")


# --- Kiosk lifecycle --------------------------------------------------------

@bp.route("/instances/<instance_id>/kiosk/status")
@client_required
def kiosk_status(instance_id):
    """Long-polled from the instance page's status hero (see
    app/long_poll.py) — same payload shape as the staff side's identical
    endpoint in instances.py, just permission-checked via
    _get_instance_or_404 instead of company membership."""
    instance = _get_instance_or_404(instance_id)
    instance_pk = instance.id

    from app.blueprints.instances import _kiosk_status_payload

    def build_payload():
        inst = Instance.query.get(instance_pk)
        return _kiosk_status_payload(inst)

    return long_poll_response(build_payload)


@bp.route("/instances/<instance_id>/kiosk/<command_type>", methods=["POST"])
@client_required
def kiosk_command(instance_id, command_type):
    if command_type not in ("start", "stop", "restart"):
        abort(404)
    instance = _get_instance_or_404(instance_id)
    if command_type != "stop" and instance.license_status == "suspended":
        # Stop is never blocked — it's always harmless, and blocking it
        # would just be one more no-op command stuck in the queue (see
        # instances.py::_blocked_while_suspended, same reasoning).
        from app.blueprints.instances import SUSPENDED_MESSAGE
        flash(SUSPENDED_MESSAGE, "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
    service_user = get_client_portal_service_user()
    _queue_command(instance, command_type, actor_id=service_user.id)
    log_client_action(current_user, instance, f"kiosk_{command_type}_requested")
    db.session.commit()
    flash(f"{command_type.capitalize()} requested — the Agent will pick this up on its next poll.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


# --- Items & Tools -----------------------------------------------------------

@bp.route("/instances/<instance_id>/equipment/add", methods=["POST"])
@client_required
def add_equipment(instance_id):
    instance = _get_instance_or_404(instance_id)

    equipment = InstanceEquipmentItem(instance_id=instance.id)
    error = _apply_equipment_fields(equipment, request.form)
    if error:
        flash(error, "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

    db.session.add(equipment)
    log_client_action(current_user, instance, f"{equipment.kind}_added", equipment.name)
    db.session.commit()
    flash(f"{'Tool' if equipment.kind == 'tool' else 'Item'} added.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


def _get_equipment_or_404(instance, equipment_id):
    equipment = InstanceEquipmentItem.query.filter_by(public_id=equipment_id, instance_id=instance.id).first()
    if equipment is None:
        abort(404)
    return equipment


@bp.route("/instances/<instance_id>/equipment/<equipment_id>/edit", methods=["POST"])
@client_required
def edit_equipment(instance_id, equipment_id):
    instance = _get_instance_or_404(instance_id)
    equipment = _get_equipment_or_404(instance, equipment_id)

    error = _apply_equipment_fields(equipment, request.form)
    if error:
        flash(error, "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

    log_client_action(current_user, instance, f"{equipment.kind}_edited", equipment.name)
    db.session.commit()
    flash("Saved.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/equipment/<equipment_id>/delete", methods=["POST"])
@client_required
def delete_equipment(instance_id, equipment_id):
    instance = _get_instance_or_404(instance_id)
    equipment = _get_equipment_or_404(instance, equipment_id)

    # Soft-delete tombstone — see instances.py's delete_equipment for why.
    equipment.deleted_at = datetime.utcnow()
    log_client_action(current_user, instance, f"{equipment.kind}_removed", equipment.name)
    db.session.commit()
    flash("Removed.", "info")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/equipment/export.csv")
@client_required
def export_equipment_csv(instance_id):
    instance = _get_instance_or_404(instance_id)
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


@bp.route("/instances/<instance_id>/equipment/import", methods=["POST"])
@client_required
def import_equipment_csv(instance_id):
    instance = _get_instance_or_404(instance_id)

    f = request.files.get("file")
    if f is None or f.filename == "":
        flash("Choose a CSV file.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
    try:
        text = f.stream.read().decode("utf-8-sig")
    except UnicodeDecodeError:
        flash("Couldn't read that file as UTF-8 CSV.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

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
            status=status,
        ))
        created += 1

    log_client_action(current_user, instance, "equipment_imported", f"{created} row(s)")
    db.session.commit()
    flash(f"Imported {created} item(s)/tool(s)." + (f" Skipped {skipped} row(s) missing a name." if skipped else ""), "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/equipment/backup.json")
@client_required
def backup_equipment(instance_id):
    instance = _get_instance_or_404(instance_id)
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


@bp.route("/instances/<instance_id>/equipment/restore", methods=["POST"])
@client_required
def restore_equipment(instance_id):
    instance = _get_instance_or_404(instance_id)

    f = request.files.get("file")
    if f is None or f.filename == "":
        flash("Choose a backup JSON file.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
    try:
        data = json.loads(f.stream.read().decode("utf-8"))
        rows = data.get("equipment", []) if isinstance(data, dict) else []
    except (ValueError, UnicodeDecodeError):
        flash("That file isn't valid backup JSON.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

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
            status=status,
        ))
        restored += 1

    log_client_action(current_user, instance, "equipment_restored", f"{restored} row(s)")
    db.session.commit()
    flash(f"Restored {restored} item(s)/tool(s) from backup.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


# --- Local Kiosk Users -------------------------------------------------------

def _get_local_user_or_404(instance, local_user_id):
    local_user = InstanceLocalUser.query.filter_by(public_id=local_user_id, instance_id=instance.id).first()
    if local_user is None:
        abort(404)
    return local_user


@bp.route("/instances/<instance_id>/local-users/add", methods=["POST"])
@client_required
def add_local_user(instance_id):
    instance = _get_instance_or_404(instance_id)

    name = request.form.get("name", "").strip()
    status = request.form.get("status", "active")
    pin = request.form.get("pin", "").strip()
    pin_confirm = request.form.get("pin_confirm", "").strip()

    if not name:
        flash("Name is required.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
    if status not in LOCAL_USER_STATUSES:
        status = "active"

    local_user = InstanceLocalUser(instance_id=instance.id, name=name, status=status)
    error = _apply_local_user_sync_fields(local_user, request.form)
    if error:
        flash(error, "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
    if not local_user.username:
        local_user.username = _slugify_username(name, instance.id)
    if pin:
        error = _validate_new_pin(local_user, pin, pin_confirm)
        if error:
            flash(error, "danger")
            return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
        local_user.set_pin(pin)

    db.session.add(local_user)
    log_client_action(current_user, instance, "local_kiosk_user_added", name)
    db.session.commit()
    flash(f"Added {name}.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/local-users/<local_user_id>/edit", methods=["POST"])
@client_required
def edit_local_user(instance_id, local_user_id):
    instance = _get_instance_or_404(instance_id)
    local_user = _get_local_user_or_404(instance, local_user_id)

    name = request.form.get("name", "").strip()
    if not name:
        flash("Name is required.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

    status = request.form.get("status", local_user.status)
    pin = request.form.get("pin", "").strip()
    pin_confirm = request.form.get("pin_confirm", "").strip()

    error = _apply_local_user_sync_fields(local_user, request.form)
    if error:
        flash(error, "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

    if pin:
        error = _validate_new_pin(local_user, pin, pin_confirm)
        if error:
            flash(error, "danger")
            return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
        local_user.set_pin(pin)

    local_user.name = name
    if status in LOCAL_USER_STATUSES:
        local_user.status = status

    log_client_action(current_user, instance, "local_kiosk_user_edited", name)
    db.session.commit()
    flash("Saved.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/local-users/<local_user_id>/delete", methods=["POST"])
@client_required
def delete_local_user(instance_id, local_user_id):
    instance = _get_instance_or_404(instance_id)
    local_user = _get_local_user_or_404(instance, local_user_id)

    # Soft-delete tombstone — see instances.py's delete_local_user for why.
    local_user.deleted_at = datetime.utcnow()
    log_client_action(current_user, instance, "local_kiosk_user_removed", local_user.name)
    db.session.commit()
    flash("Removed.", "info")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


# --- Roles -------------------------------------------------------------------
# Mirrors instances.py's own role routes exactly (same InstanceCommand
# channel, same kiosk_app/app/role_admin.py on the receiving end) — see
# that file for the full design note.

@bp.route("/instances/<instance_id>/roles/create", methods=["POST"])
@client_required
def create_role(instance_id):
    instance = _get_instance_or_404(instance_id)
    name = request.form.get("name", "").strip()
    if not name:
        flash("Role name is required.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
    service_user = get_client_portal_service_user()
    _queue_command(instance, "role_create", payload={
        "name": name, "description": request.form.get("description", "").strip() or None,
        "actor": current_user.email,
    }, actor_id=service_user.id)
    log_client_action(current_user, instance, "role_create_requested", name)
    db.session.commit()
    flash(f"Role '{name}' queued.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/roles/<role_name>/delete", methods=["POST"])
@client_required
def delete_role(instance_id, role_name):
    instance = _get_instance_or_404(instance_id)
    service_user = get_client_portal_service_user()
    _queue_command(instance, "role_delete", payload={"name": role_name, "actor": current_user.email},
                    actor_id=service_user.id)
    log_client_action(current_user, instance, "role_delete_requested", role_name)
    db.session.commit()
    flash(f"Delete for '{role_name}' queued.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/roles/<role_name>/login", methods=["POST"])
@client_required
def set_role_login(instance_id, role_name):
    instance = _get_instance_or_404(instance_id)
    service_user = get_client_portal_service_user()
    enabled = request.form.get("login_enabled") == "on"
    _queue_command(instance, "role_set_login", payload={
        "name": role_name, "enabled": enabled, "actor": current_user.email,
    }, actor_id=service_user.id)
    log_client_action(current_user, instance, "role_login_toggle_requested", f"{role_name}={enabled}")
    db.session.commit()
    flash(f"Login change for '{role_name}' queued.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/roles/<role_name>/sidebar", methods=["POST"])
@client_required
def set_role_sidebar(instance_id, role_name):
    instance = _get_instance_or_404(instance_id)
    service_user = get_client_portal_service_user()
    visibility = {key: (request.form.get(f"item_{key}") == "on") for key in SIDEBAR_ITEM_KEYS}
    _queue_command(instance, "role_set_sidebar", payload={
        "name": role_name, "visibility": visibility, "actor": current_user.email,
    }, actor_id=service_user.id)
    log_client_action(current_user, instance, "role_sidebar_requested", role_name)
    db.session.commit()
    flash(f"Sidebar change for '{role_name}' queued.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/sidebar/order", methods=["POST"])
@client_required
def set_sidebar_order(instance_id):
    """Sidebar builder (Track 2) — mirrors instances.py's set_sidebar_order
    for the Client Portal. See /root/.claude/plans/sprightly-meandering-whisper.md."""
    instance = _get_instance_or_404(instance_id)
    service_user = get_client_portal_service_user()
    order = [k.strip() for k in request.form.get("order", "").split(",") if k.strip()]
    if not order:
        flash("No order was submitted.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
    _queue_command(instance, "sidebar_reorder", payload={"order": order, "actor": current_user.email},
                    actor_id=service_user.id)
    log_client_action(current_user, instance, "sidebar_reorder_requested", "")
    db.session.commit()
    flash("Sidebar order queued.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/sidebar")
@client_required
def sidebar_page(instance_id):
    instance = _get_instance_or_404(instance_id)
    nav_entries = InstanceNavEntry.query.filter_by(instance_id=instance.id).order_by(InstanceNavEntry.sort_order).all()
    return render_template("client_portal/sidebar.html", instance=instance, nav_entries=nav_entries)


# ---------------------------------------------------------------------------
# Generic inventory type system (Track 2 — see
# /root/.claude/plans/sprightly-meandering-whisper.md). Mirrors
# instances.py's inventory_* routes exactly, using the same shared
# app/inventory_admin.py business logic — only the auth decorator
# (client_required vs. login_required+permission_required) and the audit
# call (log_client_action vs. log_action) differ, same division client
# equipment routes already use against _apply_equipment_fields.
# ---------------------------------------------------------------------------

@bp.route("/instances/<instance_id>/inventory")
@client_required
def inventory_types(instance_id):
    instance = _get_instance_or_404(instance_id)
    return render_template(
        "client_portal/inventory_types.html", instance=instance,
        types=inventory_admin.all_types_state(instance), field_types=inventory_admin.FIELD_TYPES,
    )


@bp.route("/instances/<instance_id>/inventory/types/add", methods=["POST"])
@client_required
def inventory_add_type(instance_id):
    instance = _get_instance_or_404(instance_id)
    name = request.form.get("name", "")
    ok, message, _t = inventory_admin.create_type(instance, name, request.form.get("description", ""))
    if ok:
        log_client_action(current_user, instance, "item_type_create", name)
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_types", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/inventory/types/<type_key>/edit", methods=["POST"])
@client_required
def inventory_edit_type(instance_id, type_key):
    instance = _get_instance_or_404(instance_id)
    ok, message = inventory_admin.update_type(instance, type_key, request.form.get("name", ""), request.form.get("description", ""))
    if ok:
        log_client_action(current_user, instance, "item_type_update", type_key)
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_types", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/inventory/types/<type_key>/delete", methods=["POST"])
@client_required
def inventory_delete_type(instance_id, type_key):
    instance = _get_instance_or_404(instance_id)
    ok, message = inventory_admin.delete_type(instance, type_key)
    if ok:
        log_client_action(current_user, instance, "item_type_delete", type_key)
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_types", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/inventory/types/<type_key>/fields/add", methods=["POST"])
@client_required
def inventory_add_field(instance_id, type_key):
    instance = _get_instance_or_404(instance_id)
    options = [o.strip() for o in request.form.get("options", "").split(",") if o.strip()]
    ok, message = inventory_admin.add_field(
        instance, type_key, request.form.get("label", ""), request.form.get("field_type", "text"),
        options=options, required=(request.form.get("required") == "on"),
    )
    if ok:
        log_client_action(current_user, instance, "item_type_field_add", type_key)
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_types", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/inventory/types/<type_key>/fields/<int:field_id>/delete", methods=["POST"])
@client_required
def inventory_delete_field(instance_id, type_key, field_id):
    instance = _get_instance_or_404(instance_id)
    ok, message = inventory_admin.delete_field(instance, field_id)
    if ok:
        log_client_action(current_user, instance, "item_type_field_delete", type_key)
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_types", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/inventory/type/<type_key>")
@client_required
def inventory_list_type(instance_id, type_key):
    instance = _get_instance_or_404(instance_id)
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=type_key, deleted_at=None).first()
    if item_type is None:
        abort(404)
    items = InstanceInventoryItem.query.filter_by(
        instance_id=instance.id, item_type_key=type_key, deleted_at=None
    ).order_by(InstanceInventoryItem.name).all()
    fields = inventory_admin.type_state(instance, type_key)["fields"]
    return render_template(
        "client_portal/inventory_list.html", instance=instance, item_type=item_type,
        items=items, fields=fields, measurement_kinds=measurement.MEASUREMENT_KINDS,
        all_types=InstanceItemType.query.filter_by(instance_id=instance.id, deleted_at=None).order_by(InstanceItemType.name).all(),
    )


@bp.route("/instances/<instance_id>/inventory/type/<type_key>/add", methods=["POST"])
@client_required
def inventory_add_item(instance_id, type_key):
    instance = _get_instance_or_404(instance_id)
    service_user = get_client_portal_service_user()
    fields = inventory_admin.type_state(instance, type_key)["fields"] if inventory_admin.type_state(instance, type_key) else []
    custom_values = _inventory_custom_fields_from_form(fields, request.form)
    name = request.form.get("name", "")
    ok, message, _item = inventory_admin.create_item(
        instance, service_user.id, type_key, name,
        sku=request.form.get("sku"), serial_number=request.form.get("serial_number"),
        quantity_value=(float(request.form["quantity_value"]) if request.form.get("quantity_value") else None),
        quantity_unit=request.form.get("quantity_unit") or None, custom_fields=custom_values,
        status=request.form.get("status", "active"),
    )
    if ok:
        log_client_action(current_user, instance, "inventory_item_create", name)
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_list_type", instance_id=instance.public_id, type_key=type_key))


@bp.route("/instances/<instance_id>/inventory/<int:item_id>/delete", methods=["POST"])
@client_required
def inventory_delete_item(instance_id, item_id):
    instance = _get_instance_or_404(instance_id)
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id).first()
    type_key = item.item_type_key if item else None
    item_name = item.name if item else ""
    ok, message = inventory_admin.delete_item(instance, item_id)
    if ok:
        log_client_action(current_user, instance, "inventory_item_delete", item_name)
        db.session.commit()
    flash(message, "success" if ok else "danger")
    if type_key:
        return redirect(url_for("client_portal.inventory_list_type", instance_id=instance.public_id, type_key=type_key))
    return redirect(url_for("client_portal.inventory_types", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/inventory/bulk", methods=["POST"])
@client_required
def inventory_bulk_action(instance_id):
    instance = _get_instance_or_404(instance_id)
    type_key = request.form.get("type_key", "")
    item_ids = [int(i) for i in request.form.getlist("item_ids") if i.isdigit()]
    action = request.form.get("action", "")
    if not item_ids:
        flash("No items were selected.", "danger")
        return redirect(url_for("client_portal.inventory_list_type", instance_id=instance.public_id, type_key=type_key))

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
        log_client_action(current_user, instance, audit_action, f"{len(item_ids)} item(s), action={action}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_list_type", instance_id=instance.public_id, type_key=type_key))


@bp.route("/instances/<instance_id>/inventory/<int:item_id>/manage")
@client_required
def inventory_manage_item(instance_id, item_id):
    instance = _get_instance_or_404(instance_id)
    item = InstanceInventoryItem.query.filter_by(instance_id=instance.id, id=item_id).first()
    if item is None:
        abort(404)
    item_type = InstanceItemType.query.filter_by(instance_id=instance.id, key=item.item_type_key).first()
    fields = inventory_admin.type_state(instance, item.item_type_key)["fields"] if item_type else []
    current_kind = measurement.kind_for_unit(item.quantity_unit) if item.quantity_unit else None
    return render_template(
        "client_portal/inventory_manage.html", instance=instance, item=item, item_type=item_type,
        fields=fields, custom_values=item.custom_fields_dict(),
        all_types=InstanceItemType.query.filter_by(instance_id=instance.id, deleted_at=None).order_by(InstanceItemType.name).all(),
        measurement_kinds=measurement.MEASUREMENT_KINDS, current_kind=current_kind, event_types=inventory_admin.EVENT_TYPES,
    )


@bp.route("/instances/<instance_id>/inventory/<int:item_id>/manage/save", methods=["POST"])
@client_required
def inventory_save_item(instance_id, item_id):
    instance = _get_instance_or_404(instance_id)
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
        log_client_action(current_user, instance, "inventory_item_update", item.name)
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_manage_item", instance_id=instance.public_id, item_id=item_id))


@bp.route("/instances/<instance_id>/inventory/<int:item_id>/manage/measurement", methods=["POST"])
@client_required
def inventory_set_measurement(instance_id, item_id):
    instance = _get_instance_or_404(instance_id)
    ok, message = inventory_admin.change_measurement(instance, item_id, request.form.get("quantity_unit", ""))
    if ok:
        log_client_action(current_user, instance, "inventory_item_measurement_change", f"item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_manage_item", instance_id=instance.public_id, item_id=item_id))


@bp.route("/instances/<instance_id>/inventory/<int:item_id>/manage/type", methods=["POST"])
@client_required
def inventory_set_type(instance_id, item_id):
    instance = _get_instance_or_404(instance_id)
    ok, message = inventory_admin.change_type(instance, item_id, request.form.get("item_type_key", ""))
    if ok:
        log_client_action(current_user, instance, "inventory_item_type_change", f"item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_manage_item", instance_id=instance.public_id, item_id=item_id))


@bp.route("/instances/<instance_id>/inventory/<int:item_id>/manage/generate-sku", methods=["POST"])
@client_required
def inventory_generate_sku(instance_id, item_id):
    instance = _get_instance_or_404(instance_id)
    ok, message = inventory_admin.generate_sku(instance, item_id)
    if ok:
        log_client_action(current_user, instance, "inventory_item_sku_generated", f"item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_manage_item", instance_id=instance.public_id, item_id=item_id))


@bp.route("/instances/<instance_id>/inventory/<int:item_id>/manage/generate-serial", methods=["POST"])
@client_required
def inventory_generate_serial(instance_id, item_id):
    instance = _get_instance_or_404(instance_id)
    ok, message = inventory_admin.generate_serial_number(instance, item_id)
    if ok:
        log_client_action(current_user, instance, "inventory_item_serial_generated", f"item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_manage_item", instance_id=instance.public_id, item_id=item_id))


@bp.route("/instances/<instance_id>/inventory/<int:item_id>/manage/event", methods=["POST"])
@client_required
def inventory_log_event(instance_id, item_id):
    instance = _get_instance_or_404(instance_id)
    ok, message = inventory_admin.log_event(
        instance, current_user.email, item_id, request.form.get("event_type", ""),
        project=request.form.get("project"), detail=request.form.get("detail"),
    )
    if ok:
        log_client_action(current_user, instance, "inventory_item_event", f"item {item_id}")
        db.session.commit()
    flash(message, "success" if ok else "danger")
    return redirect(url_for("client_portal.inventory_manage_item", instance_id=instance.public_id, item_id=item_id))


# --- Updates ------------------------------------------------------------

@bp.route("/instances/<instance_id>/updates/schedule", methods=["POST"])
@client_required
def schedule_update(instance_id):
    from app.models import UpdatePackage
    instance = _get_instance_or_404(instance_id)

    package = UpdatePackage.query.filter_by(public_id=request.form.get("package_id")).first()
    mode = request.form.get("mode", "schedule")
    custom_dt_utc = None
    if mode == "custom":
        raw = request.form.get("custom_datetime", "").strip()
        try:
            custom_dt_utc = datetime.strptime(raw, "%Y-%m-%dT%H:%M")
        except ValueError:
            flash("Enter a valid custom date/time.", "danger")
            return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

    if package is None:
        flash("Choose a package to push.", "danger")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

    service_user = get_client_portal_service_user()
    acting_as = _ActingAsService(service_user.id, f"{current_user.email} (client portal)")
    deployment, error = _schedule_update(instance, package, mode, custom_dt_utc, acting_as)
    if error:
        db.session.rollback()
        flash(error, "danger")
    else:
        log_client_action(current_user, instance, "update_pushed", f"v{package.version} ({mode})")
        db.session.commit()
        flash(f"Update to v{package.version} pushed." if mode == "now" else f"Update to v{package.version} scheduled.", "success")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))


@bp.route("/instances/<instance_id>/updates/<deployment_id>/cancel", methods=["POST"])
@client_required
def cancel_update(instance_id, deployment_id):
    from app.models import UpdateDeployment
    instance = _get_instance_or_404(instance_id)
    deployment = UpdateDeployment.query.filter_by(public_id=deployment_id, instance_id=instance.id).first()
    if deployment is None:
        abort(404)
    if deployment.status not in ("scheduled", "waiting"):
        flash("That update has already started and can no longer be cancelled from here.", "warning")
        return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))

    service_user = get_client_portal_service_user()
    deployment.status = "cancelled"
    deployment.cancelled_at = datetime.utcnow()
    deployment.cancelled_by_id = service_user.id
    log_client_action(current_user, instance, "update_cancelled", f"v{deployment.package.version}")
    db.session.commit()
    flash("Scheduled update cancelled.", "info")
    return redirect(url_for("client_portal.instance_detail", instance_id=instance.public_id))
