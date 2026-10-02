from datetime import datetime, timedelta
import json
import os

from flask import Blueprint, request, jsonify, send_file, current_app

from app.extensions import db
from app.models import (
    Instance, EnrollmentToken, InstanceConfig, UpdatePackage, UpdateDeployment,
    SUPPORTED_OS, gen_token, ALLOWED_TRANSITIONS, IN_FLIGHT_STATUSES,
    RemoteAccessToken, AgentErrorReport, InstanceCommand,
    InstanceEquipmentItem, InstanceLocalUser, EQUIPMENT_STATUSES, LOCAL_USER_STATUSES, InstanceRole,
    InstanceItemType, InstanceItemTypeField, InstanceInventoryItem, InstanceNavEntry,
    InstanceBackup, prune_instance_backups, get_scheduler_service_user, inspect_backup_contents,
    Product, kiosk_product_id,
)
from app.instance_auth import instance_auth_required
from app.backup_scheduling import is_backup_due

bp = Blueprint("agent_api", __name__, url_prefix="/api/v1")


def _auto_schedule_latest_release(instance: Instance, token: EnrollmentToken) -> None:
    """Zero-touch bring-up (companion to the Agent's own
    agent/update_manager.py::_auto_default_kiosk_command): a freshly
    registered instance immediately gets the latest validated, non-withdrawn
    release for its OS scheduled as an "install now" deployment, with no
    admin action needed. Without this, "run install.ps1, the kiosk is fully
    working" would still require someone to separately open the instance
    and click Push Update after every single enrollment.

    Deliberately does NOT reuse app.blueprints.instances._schedule_update -
    that helper is built around an interactively-supplied user + mode +
    existing active_deployment check, none of which apply to a brand-new
    instance that cannot possibly have one yet. Attributed to the
    enrollment token's creator (a real user, and the only human plausibly
    "responsible" for this instance existing at all) rather than a fake
    system user.

    Silently does nothing if no usable package exists for this OS yet -
    that's the ordinary state before the first release is ever uploaded,
    not an error.
    """
    package = (
        UpdatePackage.query.filter_by(
            status="validated", withdrawn=False,
            product_id=instance.product_id or kiosk_product_id(),
        )
        .filter(UpdatePackage.supported_os.contains(instance.os))
        .order_by(UpdatePackage.uploaded_at.desc())
        .first()
    )
    if package is None:
        return

    deployment = UpdateDeployment(
        instance_id=instance.id,
        package_id=package.id,
        requested_by_id=token.created_by_id,
        target_time_utc=datetime.utcnow(),
        schedule_source="auto_provision",
        previous_version=None,
    )
    deployment.append_log(
        "scheduled",
        f"auto-provisioned on registration (enrollment token: {token.label or token.id}), "
        f"targeting v{package.version}",
    )
    db.session.add(deployment)


@bp.route("/instances/register", methods=["POST"])
def register_instance():
    """Called once by a freshly-installed Instance Agent (spec Sections 5/6,
    step "Connect/register with the management service"). Consumes an
    enrollment token and returns a permanent per-instance credential.

    The returned instance_secret is shown exactly once — the agent must
    persist it locally (e.g. settings.json equivalent) alongside instance_id.
    """
    data = request.get_json(silent=True) or {}

    registration_token = (data.get("registration_token") or "").strip()
    os_name = (data.get("os") or "").strip().lower()
    hostname = (data.get("hostname") or "").strip() or None
    os_version = (data.get("os_version") or "").strip() or None
    agent_version = (data.get("agent_version") or "").strip() or None
    app_version = (data.get("app_version") or "").strip() or None

    if not registration_token:
        return jsonify({"error": "registration_token is required"}), 400
    if os_name not in SUPPORTED_OS:
        return jsonify({"error": f"os must be one of {SUPPORTED_OS}"}), 400

    token = EnrollmentToken.query.filter_by(token=registration_token).first()
    if token is None or not token.is_valid():
        # Same message whether the token is unknown, expired, revoked, or
        # exhausted — don't help an attacker distinguish those cases.
        return jsonify({"error": "invalid or expired registration token"}), 401

    instance = Instance(
        company_id=token.company_id,
        product_id=token.product_id,
        hostname=hostname,
        os=os_name,
        os_version=os_version,
        agent_version=agent_version,
        app_version=app_version,
        registered_via_token_id=token.id,
    )
    if token.license_duration_days is not None:
        instance.license_expires_at = datetime.utcnow() + timedelta(days=token.license_duration_days)
    raw_secret = gen_token(32)
    instance.set_secret(raw_secret)
    instance.mark_seen()

    token.use_count += 1

    db.session.add(instance)
    db.session.flush()  # instance.id needed by _auto_schedule_latest_release below

    _auto_schedule_latest_release(instance, token)

    db.session.commit()

    return jsonify({
        "instance_id": instance.public_id,
        "instance_secret": raw_secret,
        "company_name": token.company.name,
        # Which app this Agent installation should supervise — the new
        # agent/identity.py::ensure_registered persists this into
        # settings.json as settings.product. An Agent too old to read this
        # key just ignores it and behaves exactly as it always has (kiosk).
        "product": (token.product.slug if token.product_id else "kiosk"),
    }), 201


@bp.route("/instances/heartbeat", methods=["POST"])
@instance_auth_required
def heartbeat():
    """Periodic check-in. Reports live version/connection info and marks the
    instance online. Update-state fields (health, scheduled update, etc.) are
    added to this payload in Part 5/6 once those systems exist."""
    from flask import g
    data = request.get_json(silent=True) or {}

    g.instance.mark_seen(
        agent_version=(data.get("agent_version") or "").strip() or None,
        app_version=(data.get("app_version") or "").strip() or None,
        os_version=(data.get("os_version") or "").strip() or None,
        local_ip=(data.get("local_ip") or "").strip() or None,
        public_ip=(data.get("public_ip") or "").strip() or None,
        port=data.get("port") if isinstance(data.get("port"), int) else None,
    )
    if "tunnel_connected" in data:
        g.instance.tunnel_connected = bool(data.get("tunnel_connected"))
    if "kiosk_process_status" in data:
        g.instance.kiosk_process_status = (data.get("kiosk_process_status") or "").strip() or None

    db.session.commit()

    return jsonify({
        "ok": True,
        "instance_name": g.instance.display_name(),
        "company_name": g.instance.company.name,
        "server_time": datetime.utcnow().isoformat() + "Z",
    })


@bp.route("/instances/me", methods=["GET"])
@instance_auth_required
def me():
    """Lets the agent confirm its own registered identity/config at any time
    (e.g. after a restart, before deciding whether re-registration is needed)."""
    from flask import g
    instance = g.instance
    return jsonify({
        "instance_id": instance.public_id,
        "name": instance.display_name(),
        "company_name": instance.company.name,
        "os": instance.os,
        "connection_status": instance.connection_status,
        "last_seen_at": instance.last_seen_at.isoformat() + "Z" if instance.last_seen_at else None,
    })


@bp.route("/instances/config", methods=["GET"])
@instance_auth_required
def get_config():
    """Polled by the agent (spec Section 11: 'Configuration changes should be
    sent securely to the Instance Agent'). Returns the newest unacknowledged
    config push, if any — the agent is expected to receive, validate, apply,
    then ack via /config/ack below. If there's nothing pending, returns the
    last applied config for reference with pending: null.

    Long-polls when ?wait=<seconds> is given (capped at MAX_WAIT_SECONDS),
    same technique as get_pending_command below: holds the connection open,
    re-checking every ~1s, until either a config shows up or the wait
    expires — instead of the caller sleeping a full poll interval and
    trying again, which made clicking Save on e.g. the Login Screen's
    tenant_name take up to config_poll_interval_seconds (30s default) to
    even reach the Agent. db.session.remove() between checks is necessary
    for the same identity-map reason documented on get_pending_command."""
    from flask import g
    import time as _time

    MAX_WAIT_SECONDS = 25
    wait_seconds = request.args.get("wait", type=float, default=0) or 0
    wait_seconds = max(0.0, min(wait_seconds, MAX_WAIT_SECONDS))
    deadline = _time.monotonic() + wait_seconds
    instance_id = g.instance.id  # plain int, safe to reuse after db.session.remove() below

    while True:
        instance = Instance.query.get(instance_id)
        pending = instance.pending_config() if instance else None

        if pending is not None or _time.monotonic() >= deadline:
            current = instance.current_config() if instance else None
            return jsonify({
                "pending": {
                    "version": pending.version,
                    "config": json.loads(pending.config_json),
                } if pending else None,
                "current": {
                    "version": current.version,
                    "config": json.loads(current.config_json),
                } if current else None,
            })

        db.session.remove()
        _time.sleep(1.0)


@bp.route("/instances/config/ack", methods=["POST"])
@instance_auth_required
def ack_config():
    """Agent reports the result of applying a pushed config (spec Section 11
    steps 4–6: apply, confirm, report result). Body: {version, status, message}
    where status is 'applied', 'failed', or 'rejected' (agent-side validation
    refused it before ever applying anything)."""
    from flask import g
    data = request.get_json(silent=True) or {}

    version = data.get("version")
    status = (data.get("status") or "").strip().lower()
    message = (data.get("message") or "").strip() or None

    if status not in ("applied", "failed", "rejected"):
        return jsonify({"error": "status must be one of applied, failed, rejected"}), 400
    if not isinstance(version, int):
        return jsonify({"error": "version (integer) is required"}), 400

    config = InstanceConfig.query.filter_by(instance_id=g.instance.id, version=version).first()
    if config is None:
        return jsonify({"error": "unknown config version"}), 404
    if config.status != "pending":
        # Already acknowledged (e.g. superseded by a newer push) — don't let a
        # late/duplicate ack from the agent overwrite that outcome.
        return jsonify({"error": "config version is no longer pending", "current_status": config.status}), 409

    config.status = status
    config.agent_message = message
    config.acknowledged_at = datetime.utcnow()

    if status == "applied":
        # tenant_name/auto_logout_minutes are only read once, at kiosk_app
        # process start (kiosk_app/app/config.py) — a config write alone
        # never changes what's on screen. Previously that meant "Save" on
        # the Login Screen panel silently did nothing further, exactly as
        # its own helper text says ("...and the kiosk restarts"), but
        # nothing ever performed that restart unless an operator separately
        # clicked Restart. Auto-queuing it here — right after a CONFIRMED
        # apply, not on the push itself and not on failed/rejected — makes
        # Save actually take effect without a race against the write, and
        # without restarting on a no-op/failed push. Same
        # system-attributed-command pattern as the scheduled backup_now
        # command above.
        from app.blueprints.instances import _queue_command
        _queue_command(g.instance, "restart", actor_id=get_scheduler_service_user().id)

    db.session.commit()

    return jsonify({"ok": True})


@bp.route("/instances/updates/current", methods=["GET"])
@instance_auth_required
def current_update():
    """Polled by the agent to find out if there's an update to act on (spec
    Section 20: kiosk-side update notification). If the deployment's
    target_time has arrived, it's flipped from 'scheduled' to 'waiting' here
    — 'waiting' is the agent's cue that it's allowed to start."""
    from flask import g
    instance = g.instance

    deployment = instance.active_deployment()
    if deployment is None:
        return jsonify({"deployment": None})

    now = datetime.utcnow()
    if deployment.status == "scheduled" and deployment.target_time_utc <= now:
        deployment.status = "waiting"
        deployment.append_log("waiting", "target time reached")
        db.session.commit()

    due = deployment.status != "scheduled" or deployment.target_time_utc <= now

    return jsonify({
        "deployment": {
            "id": deployment.public_id,
            "status": deployment.status,
            "due": due,
            "target_time_utc": deployment.target_time_utc.isoformat() + "Z",
            "package": {
                "version": deployment.package.version,
                "checksum_sha256": deployment.package.checksum_sha256,
                "file_size": deployment.package.file_size,
                "download_url": f"/api/v1/updates/{deployment.package.public_id}/download",
            },
        }
    })


@bp.route("/updates/<package_id>/download", methods=["GET"])
@instance_auth_required
def download_package(package_id):
    """Streams the ZIP for an in-flight deployment only — an instance can't
    use its credentials to fetch arbitrary packages it wasn't offered (spec
    Section 15: 'never blindly execute an arbitrary file received from an
    unknown source' applies just as much to what it's allowed to fetch)."""
    from flask import g
    instance = g.instance

    package = UpdatePackage.query.filter_by(public_id=package_id).first()
    if package is None:
        return jsonify({"error": "unknown package"}), 404

    deployment = instance.active_deployment()
    if deployment is None or deployment.package_id != package.id or deployment.status not in ("waiting", "downloading"):
        return jsonify({"error": "no authorized in-progress deployment for this package"}), 403

    if not os.path.exists(package.file_path):
        return jsonify({"error": "package file missing on server"}), 500

    if deployment.status == "waiting":
        deployment.status = "downloading"
        deployment.started_at = deployment.started_at or datetime.utcnow()
        deployment.append_log("downloading", "download started")
        db.session.commit()

    return send_file(
        package.file_path, mimetype="application/zip",
        as_attachment=True, download_name=f"stocktool-kiosk-{package.version}.zip",
    )


@bp.route("/instances/updates/<deployment_id>/status", methods=["POST"])
@instance_auth_required
def report_update_status(deployment_id):
    """Agent reports progress through the lifecycle (spec Section 28 steps
    7-14). Forward-only — see ALLOWED_TRANSITIONS — so a confused or replayed
    report can't jump the state machine or resurrect a finished deployment."""
    from flask import g
    instance = g.instance

    deployment = UpdateDeployment.query.filter_by(public_id=deployment_id, instance_id=instance.id).first()
    if deployment is None:
        return jsonify({"error": "unknown deployment"}), 404

    data = request.get_json(silent=True) or {}
    new_status = (data.get("status") or "").strip()
    message = (data.get("message") or "").strip() or None
    health_check_passed = data.get("health_check_passed")

    allowed = ALLOWED_TRANSITIONS.get(deployment.status, set())
    if new_status not in allowed:
        return jsonify({
            "error": f"cannot transition from '{deployment.status}' to '{new_status}'",
            "allowed_next": sorted(allowed),
        }), 409

    if new_status == "successful":
        # Spec Section 32: only a passed health check may confirm success —
        # never inferred from the application merely having started.
        if deployment.health_check_passed is not True:
            return jsonify({
                "error": "cannot mark successful — no passed health check on record for this deployment"
            }), 400

    if new_status == "health_check" and health_check_passed is not None:
        deployment.health_check_passed = bool(health_check_passed)
        deployment.health_check_message = message

    if new_status == "rolling_back":
        deployment.rollback_reason = message

    if deployment.started_at is None and new_status not in ("scheduled", "waiting"):
        deployment.started_at = datetime.utcnow()

    deployment.status = new_status
    deployment.append_log(new_status, message)

    if new_status == "successful":
        deployment.completed_at = datetime.utcnow()
        instance.app_version = deployment.package.version
        instance.last_known_good_version = deployment.package.version
    elif new_status == "rolled_back":
        deployment.completed_at = datetime.utcnow()
        # Instance.app_version was never advanced (only 'successful' does
        # that), so it's already sitting at the previous/Last Known Good
        # version — nothing to revert here, just record the outcome.

    db.session.commit()
    return jsonify({"ok": True, "status": deployment.status})


@bp.route("/instances/errors", methods=["POST"])
@instance_auth_required
def report_error():
    """Receives one ERROR/CRITICAL log event from an Instance Agent's
    error_reporter.py. Best-effort on the Agent's side (it never retries),
    so this stays simple: validate the shape, store it, done. Surfaced on
    the instance's Diagnostics panel."""
    from flask import g
    data = request.get_json(silent=True) or {}

    level = (data.get("level") or "").strip().upper()
    if level not in ("ERROR", "CRITICAL"):
        return jsonify({"error": "level must be ERROR or CRITICAL"}), 400

    message = (data.get("message") or "").strip()
    if not message:
        return jsonify({"error": "message is required"}), 400

    suppressed = data.get("suppressed_since_last", 0)
    if not isinstance(suppressed, int) or suppressed < 0:
        suppressed = 0

    report = AgentErrorReport(
        instance_id=g.instance.id,
        level=level,
        logger_name=(data.get("logger") or "").strip() or None,
        message=message,
        traceback=data.get("traceback") or None,
        suppressed_since_last=suppressed,
    )
    db.session.add(report)
    db.session.commit()
    return jsonify({"ok": True}), 201


@bp.route("/instances/tunnel", methods=["GET"])
@instance_auth_required
def get_tunnel_request():
    """Polled by the Agent's tunnel.py to check whether an operator has
    requested remote access (issued from the instance detail page's
    "Request remote access token" button). Only ever returns a request
    still in 'pending' status — once the Agent reports an outcome via
    /tunnel/<id>/status below, it stops being handed back here, so a
    long-lived poll loop doesn't re-report the same request every cycle."""
    from flask import g
    now = datetime.utcnow()

    req = (
        RemoteAccessToken.query
        .filter_by(instance_id=g.instance.id, status="pending", revoked=False)
        .filter(RemoteAccessToken.expires_at > now)
        .order_by(RemoteAccessToken.created_at.desc())
        .first()
    )
    if req is None:
        return jsonify({"request": None})

    return jsonify({
        "request": {
            "id": req.public_id,
            "requested_at": req.created_at.isoformat() + "Z",
            "expires_at": req.expires_at.isoformat() + "Z",
        }
    })


@bp.route("/instances/tunnel/<tunnel_id>/status", methods=["POST"])
@instance_auth_required
def report_tunnel_status(tunnel_id):
    """Agent reports what happened with a tunnel request it saw via GET
    /tunnel above. 'unsupported' is the expected real-world status right
    now — the Agent's tunnel client is a deliberate stub until a tunnel
    broker exists on this side (spec Section 14); this endpoint just
    records whatever the Agent honestly reports."""
    from flask import g
    req = RemoteAccessToken.query.filter_by(public_id=tunnel_id, instance_id=g.instance.id).first()
    if req is None:
        return jsonify({"error": "unknown tunnel request"}), 404

    data = request.get_json(silent=True) or {}
    status = (data.get("status") or "").strip().lower()
    if status not in ("connected", "unsupported", "failed"):
        return jsonify({"error": "status must be one of connected, unsupported, failed"}), 400

    req.status = status
    req.status_message = (data.get("message") or "").strip() or None
    if status == "connected":
        req.used = True
        req.used_at = datetime.utcnow()

    db.session.commit()
    return jsonify({"ok": True})


@bp.route("/instances/commands", methods=["GET"])
@instance_auth_required
def get_pending_command():
    """Polled by the Agent's commands.py — the remote start/stop/restart/
    configure channel that was missing entirely before: previously the only
    way to change what starts the kiosk process, or turn it on/off, was to
    hand-edit settings.json on the machine itself.

    Long-polls when ?wait=<seconds> is given (capped at MAX_WAIT_SECONDS,
    comfortably under typical proxy/load-balancer timeouts): holds the
    connection open, re-checking every ~1s, until either a command shows up
    or the wait expires — instead of the caller sleeping a full poll
    interval and trying again, which made clicking Start/Stop/Restart in
    the UI take up to command_poll_interval_seconds (15s default) to
    actually reach the Agent. db.session.remove() between checks is
    necessary, not decorative: without it, SQLAlchemy's session-level
    identity map can keep returning the "nothing pending" result from the
    first query in this loop even after another request commits a new
    command row — this forces a fresh read every iteration.
    """
    from flask import g
    import time as _time

    MAX_WAIT_SECONDS = 25
    wait_seconds = request.args.get("wait", type=float, default=0) or 0
    wait_seconds = max(0.0, min(wait_seconds, MAX_WAIT_SECONDS))
    deadline = _time.monotonic() + wait_seconds
    instance_id = g.instance.id  # plain int, safe to reuse after db.session.remove() below

    while True:
        command = InstanceCommand.query.filter_by(
            instance_id=instance_id, status="pending"
        ).order_by(InstanceCommand.created_at.asc()).first()

        if command is None:
            # Nothing a human queued — check whether a scheduled cloud
            # backup has come due (see app/backup_scheduling.py). Re-fetch
            # the instance fresh rather than reusing g.instance: after the
            # db.session.remove() at the bottom of this loop on a prior
            # pass, that object is detached and its scalar attributes
            # (backup_time etc.) won't reflect a concurrent change — same
            # reasoning as this endpoint's own docstring already gives for
            # re-querying InstanceCommand every iteration.
            fresh_instance = Instance.query.get(instance_id)
            if fresh_instance is not None and is_backup_due(fresh_instance):
                command = InstanceCommand(
                    instance_id=instance_id, command_type="backup_now",
                    payload_json='{"source": "scheduled"}',
                    requested_by_id=get_scheduler_service_user().id,
                )
                db.session.add(command)
                # Marked immediately, not after the Agent's ack — a slow/
                # never-acked command must not cause this same "due" check
                # to re-fire and queue a second one on the very next poll.
                fresh_instance.last_cloud_backup_at = datetime.utcnow()
                db.session.commit()

        if command is not None:
            return jsonify({
                "command": {
                    "id": command.public_id,
                    "command_type": command.command_type,
                    "payload": command.payload(),
                }
            })

        if _time.monotonic() >= deadline:
            return jsonify({"command": None})

        db.session.remove()
        _time.sleep(1.0)


@bp.route("/instances/commands/<command_id>/start", methods=["POST"])
@instance_auth_required
def start_command(command_id):
    """Called by the Agent the moment it picks a command off the queue,
    BEFORE executing it — the missing second anchor point in the status
    system's timeline (see InstanceCommand.started_at). Best-effort by
    design: agent/commands.py doesn't let a failure here block actually
    running the command, so this endpoint is deliberately forgiving about
    what state it's called from — a command that's already moved past
    "pending" (e.g. a slow/duplicate call arriving after the real ack)
    is a no-op, not an error, so a network hiccup on this call never
    breaks the command itself."""
    from flask import g
    command = InstanceCommand.query.filter_by(public_id=command_id, instance_id=g.instance.id).first()
    if command is None:
        return jsonify({"error": "unknown command"}), 404
    if command.status == "pending":
        command.status = "in_progress"
        command.started_at = datetime.utcnow()
        db.session.commit()
    return jsonify({"ok": True, "status": command.status})


@bp.route("/instances/commands/<command_id>/ack", methods=["POST"])
@instance_auth_required
def ack_command(command_id):
    from flask import g
    command = InstanceCommand.query.filter_by(public_id=command_id, instance_id=g.instance.id).first()
    if command is None:
        return jsonify({"error": "unknown command"}), 404
    if command.status not in ("pending", "in_progress"):
        return jsonify({"error": "command already acknowledged", "status": command.status}), 409

    data = request.get_json(silent=True) or {}
    status = (data.get("status") or "").strip()
    if status not in ("success", "failed"):
        return jsonify({"error": "status must be 'success' or 'failed'"}), 400

    command.status = status
    command.result_message = (data.get("message") or "").strip() or None
    command.acked_at = datetime.utcnow()
    db.session.commit()

    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Kiosk App inventory sync: Items & Tools (InstanceEquipmentItem) and Local
# Kiosk Users (InstanceLocalUser) two-way synced with kiosk_app's own real
# Item/Tool/LocalUser tables via the Agent (agent/inventory_sync.py), which
# is the only thing with network access to both the Admin Panel and (over
# localhost) the Kiosk App running on the same machine. See
# InstanceEquipmentItem.to_sync_dict()/InstanceLocalUser.to_sync_dict() in
# models.py for the wire shape.
#
# Conflict resolution is last-write-wins by `updated_at`, applied
# independently on each side receiving a POST here — this endpoint never
# needs to know what the Agent's OTHER leg (the Kiosk App's own sync API)
# looks like, it just refuses to let older incoming data overwrite
# something newer already on file. Deletions are tombstones
# (`deleted_at`), never a hard delete, so a delete on one side can still
# reach the other before eventually being safe to actually forget.
# ---------------------------------------------------------------------------

def _parse_sync_dt(value):
    """Parses an ISO datetime string from a sync payload — never raises;
    missing/malformed input is treated as "no timestamp", which sorts
    before every real one below (so a row with no timestamp never wins a
    last-write-wins comparison against a row that has one)."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except (ValueError, TypeError):
        return None


def _is_incoming_newer(incoming_dt, existing_dt) -> bool:
    if incoming_dt is None:
        return False
    if existing_dt is None:
        return True
    return incoming_dt > existing_dt


@bp.route("/instances/equipment/sync", methods=["GET"])
@instance_auth_required
def get_equipment_sync():
    from flask import g
    rows = InstanceEquipmentItem.query.filter_by(instance_id=g.instance.id).all()
    return jsonify({
        "items": [r.to_sync_dict() for r in rows if r.kind == "item"],
        "tools": [r.to_sync_dict() for r in rows if r.kind == "tool"],
    })


@bp.route("/instances/equipment/sync", methods=["POST"])
@instance_auth_required
def apply_equipment_sync():
    from flask import g
    data = request.get_json(silent=True) or {}
    instance = g.instance

    applied = 0
    for kind, payload_list in (("item", data.get("items") or []), ("tool", data.get("tools") or [])):
        for payload in payload_list:
            public_id = (payload.get("public_id") or "").strip()
            if not public_id:
                continue
            incoming_updated_at = _parse_sync_dt(payload.get("updated_at"))
            incoming_deleted_at = _parse_sync_dt(payload.get("deleted_at"))

            existing = InstanceEquipmentItem.query.filter_by(
                instance_id=instance.id, public_id=public_id
            ).first()

            if existing is None:
                if incoming_deleted_at is not None:
                    continue  # already gone elsewhere — nothing to create
                name = (payload.get("name") or "").strip()
                if not name:
                    continue
                existing = InstanceEquipmentItem(instance_id=instance.id, public_id=public_id, kind=kind, name=name)
                db.session.add(existing)
            elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
                continue  # what we already have is at least as new — incoming loses

            existing.name = (payload.get("name") or existing.name or "").strip() or existing.name
            existing.description = payload.get("description")
            status = payload.get("status")
            existing.status = status if status in EQUIPMENT_STATUSES else existing.status
            existing.sku = payload.get("sku")
            existing.quantity = payload.get("quantity")
            existing.unit = payload.get("unit")
            existing.category = payload.get("category")
            existing.unit_cost = payload.get("unit_cost")
            existing.tool_status = payload.get("tool_status")
            existing.checked_out_by_name = payload.get("checked_out_by_name")
            existing.current_project = payload.get("current_project")
            existing.purchase_price = payload.get("purchase_price")
            existing.barcode_code = payload.get("barcode_code")
            existing.deleted_at = incoming_deleted_at
            if incoming_updated_at is not None:
                existing.updated_at = incoming_updated_at
            applied += 1

    db.session.commit()
    return jsonify({"ok": True, "applied": applied})


@bp.route("/instances/local-users/sync", methods=["GET"])
@instance_auth_required
def get_local_users_sync():
    from flask import g
    rows = InstanceLocalUser.query.filter_by(instance_id=g.instance.id).all()
    return jsonify({"local_users": [r.to_sync_dict() for r in rows]})


@bp.route("/instances/local-users/sync", methods=["POST"])
@instance_auth_required
def apply_local_users_sync():
    from flask import g
    data = request.get_json(silent=True) or {}
    instance = g.instance

    applied = 0
    for payload in (data.get("local_users") or []):
        public_id = (payload.get("public_id") or "").strip()
        if not public_id:
            continue
        incoming_updated_at = _parse_sync_dt(payload.get("updated_at"))
        incoming_deleted_at = _parse_sync_dt(payload.get("deleted_at"))

        existing = InstanceLocalUser.query.filter_by(instance_id=instance.id, public_id=public_id).first()

        if existing is None:
            if incoming_deleted_at is not None:
                continue
            name = (payload.get("name") or "").strip()
            if not name:
                continue
            existing = InstanceLocalUser(instance_id=instance.id, public_id=public_id, name=name)
            db.session.add(existing)
        elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
            continue

        existing.name = (payload.get("name") or existing.name or "").strip() or existing.name
        status = payload.get("status")
        existing.status = status if status in LOCAL_USER_STATUSES else existing.status
        username = (payload.get("username") or "").strip() or None
        # A username collision with another local user on this SAME instance
        # (the only scope it's unique within — see the model's
        # UniqueConstraint) is a real possibility once both sides can
        # create rows independently; skip just the username on conflict
        # rather than failing the whole row over one field.
        if username and username != existing.username:
            # deleted_at.is_(None): a removed local user's old username is
            # free to reuse — see InstanceLocalUser's partial unique index.
            clash = InstanceLocalUser.query.filter(
                InstanceLocalUser.instance_id == instance.id,
                InstanceLocalUser.username == username,
                InstanceLocalUser.deleted_at.is_(None),
                InstanceLocalUser.id != existing.id,
            ).first()
            if clash is None:
                existing.username = username
        # Permissive accept, not a fixed-list check: kiosk_app roles are
        # user-defined now (kiosk_app/app/role_admin.py) and this side has
        # no live view of that instance's actual role list without a round
        # trip — same reasoning `category` already uses on equipment sync.
        role = (payload.get("role") or "").strip()
        existing.role = role or existing.role
        existing.badge_code = payload.get("badge_code") or existing.badge_code
        pin_hash = payload.get("pin_hash")
        if pin_hash:
            existing.pin_hash = pin_hash
        existing.deleted_at = incoming_deleted_at
        if incoming_updated_at is not None:
            existing.updated_at = incoming_updated_at
        applied += 1

    db.session.commit()
    return jsonify({"ok": True, "applied": applied})


@bp.route("/instances/roles/sync", methods=["POST"])
@instance_auth_required
def push_roles_sync():
    """Replaces this instance's InstanceRole cache wholesale from the
    Agent's current read of kiosk_app's own Role/RolePermission/
    RoleSidebarPermission tables (see agent/inventory_sync.py and
    kiosk_app/app/blueprints/sync_api.py::list_roles). Read-only display
    cache, not a merge target — roles are actually edited via the
    InstanceCommand channel (see instances.py's role routes), so there's
    no incoming-vs-existing conflict to resolve here, just "what does the
    kiosk currently say" replacing "what we last cached"."""
    from flask import g
    data = request.get_json(silent=True) or {}
    instance = g.instance

    InstanceRole.query.filter_by(instance_id=instance.id).delete()
    for row in (data.get("roles") or []):
        name = (row.get("name") or "").strip()
        if not name:
            continue
        db.session.add(InstanceRole(
            instance_id=instance.id, name=name,
            is_builtin=bool(row.get("is_builtin")),
            user_count=int(row.get("user_count") or 0),
            login_enabled=bool(row.get("login_enabled", True)),
            sidebar_json=json.dumps(row.get("sidebar") or {}),
        ))
    db.session.commit()
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
# Track 2 Phase B — generic inventory type system sync (see
# /root/.claude/plans/sprightly-meandering-whisper.md). item_types and
# inventory_items are bidirectional, last-write-wins-by-updated_at, exactly
# like equipment/local-users above — this side (Admin Panel/Client Portal's
# type manager, Phase C) can create/edit a type or item, not just the kiosk
# terminal. nav_entries stays a read-only cache, same pattern roles uses
# just above, since kiosk_app remains the source of truth for nav layout.
# ---------------------------------------------------------------------------

@bp.route("/instances/item-types/sync", methods=["GET"])
@instance_auth_required
def get_item_types_sync():
    from flask import g
    rows = InstanceItemType.query.filter_by(instance_id=g.instance.id).all()
    return jsonify({"item_types": [r.to_sync_dict() for r in rows]})


@bp.route("/instances/item-types/sync", methods=["POST"])
@instance_auth_required
def apply_item_types_sync():
    from flask import g
    data = request.get_json(silent=True) or {}
    instance = g.instance

    applied = 0
    for payload in (data.get("item_types") or []):
        key = (payload.get("key") or "").strip()
        if not key:
            continue
        incoming_updated_at = _parse_sync_dt(payload.get("updated_at"))
        incoming_deleted_at = _parse_sync_dt(payload.get("deleted_at"))

        existing = InstanceItemType.query.filter_by(instance_id=instance.id, key=key).first()
        if existing is None:
            if incoming_deleted_at is not None:
                continue
            name = (payload.get("name") or "").strip()
            if not name:
                continue
            existing = InstanceItemType(instance_id=instance.id, key=key, name=name)
            db.session.add(existing)
            db.session.flush()
        elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
            continue
        elif existing.is_builtin:
            continue

        existing.name = (payload.get("name") or existing.name or "").strip() or existing.name
        existing.description = payload.get("description")
        existing.is_builtin = bool(payload.get("is_builtin"))
        existing.deleted_at = incoming_deleted_at
        if incoming_updated_at is not None:
            existing.updated_at = incoming_updated_at

        if incoming_deleted_at is None:
            InstanceItemTypeField.query.filter_by(instance_item_type_id=existing.id).delete()
            for f in (payload.get("fields") or []):
                f_key = (f.get("key") or "").strip()
                if not f_key:
                    continue
                db.session.add(InstanceItemTypeField(
                    instance_item_type_id=existing.id, key=f_key, label=f.get("label") or f_key,
                    field_type=f.get("field_type") or "text",
                    options_json=json.dumps(f.get("options") or []),
                    required=bool(f.get("required")), sort_order=int(f.get("sort_order") or 0),
                ))
        applied += 1

    db.session.commit()
    return jsonify({"ok": True, "applied": applied})


@bp.route("/instances/inventory-items/sync", methods=["GET"])
@instance_auth_required
def get_inventory_items_sync():
    from flask import g
    rows = InstanceInventoryItem.query.filter_by(instance_id=g.instance.id).all()
    return jsonify({"inventory_items": [r.to_sync_dict() for r in rows]})


@bp.route("/instances/inventory-items/sync", methods=["POST"])
@instance_auth_required
def apply_inventory_items_sync():
    from flask import g
    data = request.get_json(silent=True) or {}
    instance = g.instance

    applied = 0
    for payload in (data.get("inventory_items") or []):
        public_id = (payload.get("public_id") or "").strip()
        if not public_id:
            continue
        incoming_updated_at = _parse_sync_dt(payload.get("updated_at"))
        incoming_deleted_at = _parse_sync_dt(payload.get("deleted_at"))

        existing = InstanceInventoryItem.query.filter_by(instance_id=instance.id, public_id=public_id).first()
        if existing is None:
            if incoming_deleted_at is not None:
                continue
            name = (payload.get("name") or "").strip()
            item_type_key = (payload.get("item_type_key") or "").strip()
            if not name or not item_type_key:
                continue
            existing = InstanceInventoryItem(
                instance_id=instance.id, public_id=public_id, name=name, item_type_key=item_type_key,
            )
            db.session.add(existing)
        elif not _is_incoming_newer(incoming_updated_at, existing.updated_at):
            continue

        existing.name = (payload.get("name") or existing.name or "").strip() or existing.name
        if payload.get("item_type_key"):
            existing.item_type_key = payload["item_type_key"]
        existing.sku = payload.get("sku")
        existing.serial_number = payload.get("serial_number")
        status = payload.get("status")
        if status:
            existing.status = status
        existing.quantity_value = payload.get("quantity_value")
        existing.quantity_unit = payload.get("quantity_unit")
        existing.custom_fields = json.dumps(payload.get("custom_fields") or {})
        existing.barcode_code = payload.get("barcode_code")
        existing.checked_out_by_name = payload.get("checked_out_by_name")
        existing.current_project = payload.get("current_project")
        existing.deleted_at = incoming_deleted_at
        if incoming_updated_at is not None:
            existing.updated_at = incoming_updated_at
        applied += 1

    db.session.commit()
    return jsonify({"ok": True, "applied": applied})


@bp.route("/instances/nav-entries/sync", methods=["POST"])
@instance_auth_required
def push_nav_entries_sync():
    """Replaces this instance's InstanceNavEntry cache wholesale from the
    Agent's current read of kiosk_app's own NavEntry table — same
    read-only-cache pattern push_roles_sync uses above; nav layout is
    edited via the InstanceCommand channel's sidebar_reorder, not by
    writing here directly."""
    from flask import g
    data = request.get_json(silent=True) or {}
    instance = g.instance

    InstanceNavEntry.query.filter_by(instance_id=instance.id).delete()
    for row in (data.get("nav_entries") or []):
        key = (row.get("key") or "").strip()
        if not key:
            continue
        db.session.add(InstanceNavEntry(
            instance_id=instance.id, key=key, label=row.get("label") or key,
            section=row.get("section") or "Other",
            is_builtin=bool(row.get("is_builtin")),
            sort_order=int(row.get("sort_order") or 0),
        ))
    db.session.commit()
    return jsonify({"ok": True})


@bp.route("/instances/backup/upload", methods=["POST"])
@instance_auth_required
def upload_backup():
    """Receives one backup file from the Agent — called after it executes
    a 'backup_now' InstanceCommand (see get_pending_command above and
    agent/backup_sync.py), whether that command was queued because a
    schedule came due or because someone clicked "Back up now" in the
    Client Portal (see request.form's 'source'). Stores it under
    INSTANCE_BACKUP_DIR/<instance public_id>/, records an InstanceBackup
    row, then immediately prunes anything now over the retention policy —
    see prune_instance_backups' own docstring for exactly what that keeps."""
    from flask import g
    import os as _os
    from werkzeug.utils import secure_filename

    instance = g.instance
    uploaded = request.files.get("file")
    if uploaded is None or uploaded.filename == "":
        return jsonify({"error": "no file"}), 400
    source = request.form.get("source", "scheduled")
    if source not in ("scheduled", "manual"):
        source = "scheduled"

    instance_dir = _os.path.join(current_app.config["INSTANCE_BACKUP_DIR"], instance.public_id)
    _os.makedirs(instance_dir, exist_ok=True)

    safe_name = secure_filename(uploaded.filename) or "backup.db"
    dest_path = _os.path.join(instance_dir, safe_name)
    # Never overwrite — two backups landing with the same name (clock skew,
    # a retry) both get kept rather than one silently clobbering the other.
    if _os.path.exists(dest_path):
        stem, ext = _os.path.splitext(safe_name)
        safe_name = f"{stem}-{gen_token(4)}{ext}"
        dest_path = _os.path.join(instance_dir, safe_name)
    uploaded.save(dest_path)

    backup = InstanceBackup(
        instance_id=instance.id, filename=safe_name, file_path=dest_path,
        file_size=_os.path.getsize(dest_path), source=source,
        contents_summary=inspect_backup_contents(dest_path),
    )
    db.session.add(backup)
    db.session.flush()
    prune_instance_backups(instance.id)
    db.session.commit()

    return jsonify({"ok": True, "backup_id": backup.public_id, "contents_summary": backup.contents_summary_dict()})

