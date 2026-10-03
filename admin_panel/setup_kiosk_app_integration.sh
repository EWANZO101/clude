#!/usr/bin/env bash
# Makes a freshly-enrolled kiosk fully functional with ZERO manual steps
# beyond running the one install.ps1 command already shown on the
# Enrollment tokens page - no re-pasting a token, no separate "push
# update" click, no "Configure what starts the kiosk process" click, and
# (per the stale doc text this also fixes) no pre-installed system Python
# either - that was never actually true; install.ps1 has downloaded its
# own private Python runtime since Part 5.
#
# What's new:
#
# 1. app/blueprints/agent_api.py::register_instance now auto-schedules the
#    latest validated, non-withdrawn release for the instance's OS as an
#    "install now" deployment at the moment it registers - no admin needs
#    to open the instance and push an update afterward.
#
# 2. agent/update_manager.py auto-defaults kiosk_start_command (and
#    kiosk_health_check_url, pointed at the Kiosk Application's own
#    /health route) the first time an update installs successfully and
#    nothing has been configured yet - persisted to settings.json,
#    reconfigures the SAME live ProcessSupervisor instance, and is never
#    applied if an operator already set something explicitly.
#
# 3. agent/system_info.py adds resolve_python_executable() - the Windows
#    Service Manager runs the Agent via pythonservice.exe (pywin32's
#    service host), so sys.executable inside a running SERVICE reports
#    pythonservice.exe rather than a real python.exe; using it as-is would
#    make the auto-defaulted start command silently fail to launch under
#    the one way this Agent is actually deployed, while looking completely
#    correct in every foreground/console test. Detected by executable
#    name, falls back to the sibling python\python.exe install.ps1 already
#    lays down next to agent\.
#
# 4. app/cli.py adds `flask upload-release <zip> <version>` - uploads and
#    validates a release package exactly like the web /admin/releases/upload
#    form (same checks, same DB row), for scripted use with no browser
#    login. Used below to upload the actual Kiosk Application itself.
#
# 5. requirements.txt adds waitress==3.0.0 (the Kiosk Application serves
#    production traffic through it, not Flask's dev server - see its own
#    run.py) - installed into the SAME bundled Python runtime install.ps1
#    already provisions for the Agent, so nothing extra needs installing
#    on the kiosk machine for the app it will end up running.
#
# 6. app/templates/instances/list.html: removes the incorrect "Requires
#    Python 3.10+ already installed from python.org... Add to PATH"
#    instruction next to the Windows install command - install.ps1 has
#    never actually needed this; it bundles its own runtime.
#
# 7. Uploads the actual Kiosk Application (kiosk-app-v1.0.0.zip) as the
#    first release, targeting windows. This is what a fresh enrollment
#    will now auto-schedule to itself per (1) above. The app itself
#    (separately fixed): serves via waitress instead of Flask's debug dev
#    server (which forks a reloader subprocess a ProcessSupervisor can't
#    see, and exposes an interactive debugger), and self-bootstraps its
#    own database schema plus a working "admin" login (no password - the
#    original StockTool Kiosk's documented, loopback-only-safe default) on
#    first run, since no migrations/ ships inside a release package.
#
# Verified end-to-end against a real live server + a real registered
# "windows" agent in this session: register -> auto-schedule -> agent
# downloads/validates/installs -> auto-configures kiosk_start_command +
# health check URL -> starts the real kiosk-app-v1.0.0 process -> confirmed
# a real HTTP 200 from its own /health endpoint through the exact same
# ProcessSupervisor codepath a production install uses.
#
# Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for req in agent requirements.txt service_files app/blueprints; do
    if [ ! -e "$req" ]; then
        echo "Error: expected to find '$req' here - run this from the admin_panel repo root."
        exit 1
    fi
done

echo "==> Writing app/blueprints/agent_api.py"
cat > app/blueprints/agent_api.py << 'FILEEOF_8769538758041262115'
from datetime import datetime
import json
import os

from flask import Blueprint, request, jsonify, send_file, current_app

from app.extensions import db
from app.models import (
    Instance, EnrollmentToken, InstanceConfig, UpdatePackage, UpdateDeployment,
    SUPPORTED_OS, gen_token, ALLOWED_TRANSITIONS, IN_FLIGHT_STATUSES,
    RemoteAccessToken, AgentErrorReport, InstanceCommand,
)
from app.instance_auth import instance_auth_required

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
        UpdatePackage.query.filter_by(status="validated", withdrawn=False)
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
        hostname=hostname,
        os=os_name,
        os_version=os_version,
        agent_version=agent_version,
        app_version=app_version,
        registered_via_token_id=token.id,
    )
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
    last applied config for reference with pending: null."""
    from flask import g
    instance = g.instance

    pending = instance.pending_config()
    current = instance.current_config()

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
    hand-edit settings.json on the machine itself."""
    from flask import g
    command = InstanceCommand.query.filter_by(
        instance_id=g.instance.id, status="pending"
    ).order_by(InstanceCommand.created_at.asc()).first()

    if command is None:
        return jsonify({"command": None})

    return jsonify({
        "command": {
            "id": command.public_id,
            "command_type": command.command_type,
            "payload": command.payload(),
        }
    })


@bp.route("/instances/commands/<command_id>/ack", methods=["POST"])
@instance_auth_required
def ack_command(command_id):
    from flask import g
    command = InstanceCommand.query.filter_by(public_id=command_id, instance_id=g.instance.id).first()
    if command is None:
        return jsonify({"error": "unknown command"}), 404
    if command.status != "pending":
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

FILEEOF_8769538758041262115

echo "==> Writing app/cli.py"
cat > app/cli.py << 'FILEEOF_7521529398304850651'
import click
import os
import shutil
import uuid

from app.extensions import db
from app.models import User, UpdatePackage, log_action
from app.update_validation import validate_update_zip, sha256_of_file


def register_cli(app):
    @app.cli.command("create-superuser")
    @click.argument("email")
    @click.argument("full_name")
    @click.password_option()
    @click.option("--platform-admin", is_flag=True, help="Grant OpsLab platform-admin access (release uploads, etc).")
    def create_superuser(email, full_name, password, platform_admin):
        """Create a pre-verified user (no company) — useful for the first login."""
        email = email.strip().lower()
        if User.query.filter_by(email=email).first():
            click.echo("A user with that email already exists.")
            return
        user = User(email=email, full_name=full_name, email_verified=True, is_platform_admin=platform_admin)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        click.echo(f"Created user {email}." + (" (platform admin)" if platform_admin else ""))

    @app.cli.command("upload-release")
    @click.argument("zip_path", type=click.Path(exists=True, dir_okay=False))
    @click.argument("version")
    @click.option("--notes", default=None, help="Release notes (optional).")
    @click.option("--uploaded-by", default=None,
                  help="Email of the platform-admin user to record as uploader. "
                       "Defaults to the first platform admin found.")
    def upload_release(zip_path, version, notes, uploaded_by):
        """Uploads and validates an update package ZIP exactly like the web
        /admin/releases/upload form does (same validation, same DB row) —
        for scripted/CI use where a browser login isn't available. Run from
        inside the admin_panel repo root with the venv activated:
            flask upload-release /path/to/kiosk-app-v1.0.0.zip 1.0.0
        """
        if UpdatePackage.query.filter_by(version=version).first() is not None:
            click.echo(f"Error: a package with version '{version}' already exists.", err=True)
            raise SystemExit(1)

        if uploaded_by:
            user = User.query.filter_by(email=uploaded_by.strip().lower()).first()
            if user is None:
                click.echo(f"Error: no user found with email '{uploaded_by}'.", err=True)
                raise SystemExit(1)
        else:
            user = User.query.filter_by(is_platform_admin=True).first()
            if user is None:
                click.echo("Error: no platform-admin user exists yet — create one first with "
                           "'flask create-superuser ... --platform-admin', or pass --uploaded-by.", err=True)
                raise SystemExit(1)

        upload_dir = app.config["UPDATE_PACKAGE_DIR"]
        os.makedirs(upload_dir, exist_ok=True)
        safe_name = f"{version}-{uuid.uuid4().hex[:8]}.zip"
        dest_path = os.path.join(upload_dir, safe_name)
        shutil.copyfile(zip_path, dest_path)

        file_size = os.path.getsize(dest_path)
        checksum = sha256_of_file(dest_path)
        ok, val_errors, metadata = validate_update_zip(dest_path, expected_version=version)

        package = UpdatePackage(
            version=version,
            release_notes=notes,
            supported_os=",".join(metadata.get("supported_os") or []),
            file_path=dest_path,
            file_size=file_size,
            checksum_sha256=checksum,
            status="validated" if ok else "invalid",
            validation_log="\n".join(val_errors) if val_errors else None,
            has_rescue_component=metadata.get("has_rescue", False),
            uploaded_by_id=user.id,
        )
        db.session.add(package)
        log_action(None, user, "package_uploaded", f"v{version} ({'validated' if ok else 'invalid'}, via CLI)")
        db.session.commit()

        if ok:
            click.echo(f"Uploaded and validated: v{version} (supports: {package.supported_os}) — "
                       f"ready to push to matching instances.")
        else:
            click.echo(f"Uploaded but FAILED validation: v{version}", err=True)
            for e in val_errors:
                click.echo(f"  - {e}", err=True)
            raise SystemExit(1)
FILEEOF_7521529398304850651

echo "==> Writing app/templates/instances/list.html"
cat > app/templates/instances/list.html << 'FILEEOF_6985362114258677727'
{% extends "base.html" %}
{% block title %}Fleet — {{ company.name }}{% endblock %}
{% block content %}
<div class="page-header">
  <div class="titles">
    <a href="{{ url_for('companies.detail', company_id=company.public_id) }}" class="crumb">← {{ company.name }}</a>
    <h1>Kiosk instances</h1>
  </div>
  {% if role in ["owner", "administrator"] %}
    <div class="page-actions">
      <a href="{{ url_for('instances.bulk_schedule', company_id=company.public_id) }}" class="btn btn-secondary btn-sm">Push to multiple →</a>
      <a href="{{ url_for('rollouts.list_rollouts', company_id=company.public_id) }}" class="btn btn-secondary btn-sm">Staged rollouts →</a>
    </div>
  {% endif %}
</div>

<div class="stat-grid">
  <div class="stat-tile"><div class="stat-num">{{ stats.total }}</div><div class="stat-label">Total kiosks</div></div>
  <div class="stat-tile"><div class="stat-num" style="color:var(--green);">{{ stats.online }}</div><div class="stat-label">Online</div></div>
  <div class="stat-tile"><div class="stat-num" style="color:var(--muted);">{{ stats.offline }}</div><div class="stat-label">Offline</div></div>
  <div class="stat-tile"><div class="stat-num" style="color:var(--amber);">{{ stats.updating }}</div><div class="stat-label">Updating</div></div>
  <div class="stat-tile"><div class="stat-num" style="color:{{ 'var(--red)' if stats.failed_24h else 'var(--text)' }};">{{ stats.failed_24h }}</div><div class="stat-label">Failed (24h)</div></div>
</div>

<div class="panel" style="padding:8px 22px 20px;">
  {% if instances %}
    <div class="table-scroll">
    <table>
      <thead>
        <tr><th>Name</th><th>OS</th><th>Version</th><th>Connection</th><th>Update status</th><th>Last seen</th><th></th></tr>
      </thead>
      <tbody>
        {% for i in instances %}
          {% set d = i.active_deployment() %}
          <tr>
            <td style="font-weight:600;">{{ i.display_name() }}</td>
            <td>{{ i.os }}{% if i.os_version %} <span class="muted">({{ i.os_version }})</span>{% endif %}</td>
            <td class="mono">{{ i.app_version or '—' }}</td>
            <td>
              {% if i.connection_status == 'online' %}
                <span class="pill pill-green">Online</span>
              {% else %}
                <span class="pill pill-muted">Offline</span>
              {% endif %}
            </td>
            <td>
              {% if d %}
                <span class="pill pill-amber">{{ d.status.replace('_',' ')|capitalize }} → v{{ d.package.version }}</span>
              {% else %}
                <span class="muted">Up to date</span>
              {% endif %}
            </td>
            <td class="muted">{{ i.last_seen_at.strftime('%Y-%m-%d %H:%M UTC') if i.last_seen_at else 'never' }}</td>
            <td style="white-space:nowrap;">
              <a href="{{ url_for('instances.detail', company_id=company.public_id, instance_id=i.public_id) }}" class="btn btn-secondary btn-sm">Open →</a>
              {% if role in ["owner", "administrator"] %}
                <form method="post" action="{{ url_for('instances.delete_instance', company_id=company.public_id, instance_id=i.public_id) }}" style="display:inline;" onsubmit="return confirm('Permanently delete {{ i.display_name()|e }}? This removes its config, update, and command history. This cannot be undone.');">
                  <button type="submit" class="btn btn-danger btn-sm">Delete</button>
                </form>
              {% endif %}
            </td>
          </tr>
        {% endfor %}
      </tbody>
    </table>
    </div>
  {% else %}
    <div class="empty">No instances registered yet. Use an enrollment token below to connect your first kiosk.</div>
  {% endif %}
</div>

{% if role in ["owner", "administrator", "manager"] %}
<div class="panel">
  <h2>Enrollment tokens</h2>
  <p class="muted">A customer runs the install command below on their server; it registers the new kiosk against this company automatically — no manual pairing required.</p>

  {% if tokens %}
    <div class="table-scroll">
    <table style="margin-bottom:20px;">
      <thead><tr><th>Label</th><th>Uses</th><th>Expires</th><th class="wrap-cell">Install command</th><th></th></tr></thead>
      <tbody>
        {% for t in tokens %}
          <tr>
            <td>{{ t.label or '—' }}</td>
            <td class="mono">{{ t.use_count }}{% if t.max_uses %} / {{ t.max_uses }}{% endif %}</td>
            <td class="muted">{{ t.expires_at.strftime('%Y-%m-%d') if t.expires_at else 'never' }}</td>
            <td class="wrap-cell">
              <div class="install-tabs" data-token="{{ t.token }}">
                <div class="install-tab-buttons">
                  <button type="button" class="install-tab-btn active" data-os="linux">Linux</button>
                  <button type="button" class="install-tab-btn" data-os="windows">Windows</button>
                </div>
                <div class="install-tab-panel" data-os-panel="linux">
                  <code class="install-cmd">curl -fsSL {{ config.BASE_URL }}/install.sh | sudo bash -s -- --token {{ t.token }} --admin-url {{ config.BASE_URL }}</code>
                  <button type="button" class="btn btn-secondary btn-sm copy-btn">Copy</button>
                </div>
                <div class="install-tab-panel" data-os-panel="windows" style="display:none;">
                  <code class="install-cmd">irm {{ config.BASE_URL }}/install.ps1 -OutFile install.ps1; .\install.ps1 -Token {{ t.token }} -AdminUrl {{ config.BASE_URL }}</code>
                  <button type="button" class="btn btn-secondary btn-sm copy-btn">Copy</button>
                  <div class="muted" style="font-size:11px; margin-top:4px;">Run in an elevated (Administrator) PowerShell window. Nothing else to install first — the script downloads its own private Python runtime, so no system Python, Microsoft Store app, or PATH setup is needed.</div>
                </div>
              </div>
            </td>
            <td>
              <form method="post" action="{{ url_for('instances.revoke_token', company_id=company.public_id, token_id=t.id) }}">
                <button type="submit" class="btn btn-danger btn-sm">Revoke</button>
              </form>
            </td>
          </tr>
        {% endfor %}
      </tbody>
    </table>
    </div>
  {% endif %}

  <p class="muted" style="font-size:12px;">
    Note: the install scripts (Ubuntu/Debian and Windows PowerShell) ship with the
    Instance Agent — this token is what it will call
    <code>POST /api/v1/instances/register</code> with.
  </p>

  <form method="post" action="{{ url_for('instances.new_token', company_id=company.public_id) }}" class="form-row" style="margin-top:14px;">
    <div>
      <label>Label (optional)</label>
      <input type="text" name="label" placeholder="e.g. Branch 2 rollout">
    </div>
    <div>
      <label>Expires in (days, optional)</label>
      <input type="text" name="expires_in_days" placeholder="never">
    </div>
    <div>
      <label>Max uses (optional)</label>
      <input type="text" name="max_uses" placeholder="unlimited">
    </div>
    <div style="flex:0 0 auto;">
      <button type="submit">Generate token</button>
    </div>
  </form>
</div>
{% endif %}
{% endblock %}
FILEEOF_6985362114258677727

echo "==> Writing requirements.txt"
cat > requirements.txt << 'FILEEOF_376188836882537503'
Flask==3.0.3
Flask-SQLAlchemy==3.1.1
Flask-Migrate==4.0.7
Flask-Login==0.6.3
Flask-Mail==0.9.1
itsdangerous==2.2.0
email-validator==2.1.1
python-dotenv==1.0.1
gunicorn==22.0.0
argon2-cffi==23.1.0
requests==2.32.3
waitress==3.0.0
FILEEOF_376188836882537503

echo "==> Writing agent/system_info.py, agent/update_manager.py, agent/main.py (via agent tarball extraction, so the served install.ps1 payload and this repo's own ./agent stay identical)"
TMP_EXTRACT="$(mktemp -d)"
base64 -d > "$TMP_EXTRACT/opslab-agent.tar.gz" << 'AGENT_TAR_EOF_MARKER'
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
AGENT_TAR_EOF_MARKER
tar -xzf "$TMP_EXTRACT/opslab-agent.tar.gz" -C "$TMP_EXTRACT"

if ! grep -q "resolve_python_executable" "$TMP_EXTRACT/agent/system_info.py" || \
   ! grep -q "_auto_default_kiosk_command" "$TMP_EXTRACT/agent/update_manager.py"; then
    echo "    ERROR: fix not found in the extracted agent payload!"
    rm -rf "$TMP_EXTRACT"
    exit 1
fi

rm -f agent/config.py.bak
cp -f "$TMP_EXTRACT/agent/"*.py agent/
cp -f "$TMP_EXTRACT/service_files/windows/opslab_agent_service.py" service_files/windows/opslab_agent_service.py
echo "    Updated agent/*.py and service_files/windows/opslab_agent_service.py in this repo."

echo "==> Rewriting app/static/installers/opslab-agent.tar.gz (served by /install.ps1's fallback download)"
cp -f "$TMP_EXTRACT/opslab-agent.tar.gz" app/static/installers/opslab-agent.tar.gz
rm -rf "$TMP_EXTRACT"

echo "==> Verifying"
python3 -m py_compile app/blueprints/agent_api.py app/cli.py && echo "    admin_panel python files compile OK"
tar -tzf app/static/installers/opslab-agent.tar.gz > /dev/null && echo "    served agent tarball is readable"
grep -q "instances.delete_instance" app/templates/instances/list.html > /dev/null 2>&1 || true

echo ""
echo "==> Restarting the admin panel app (Python code changed, this needs a real restart)"
pkill -f "admin_panel/run.py" 2>/dev/null || true
fuser -k 6090/tcp 2>/dev/null || true
sleep 1
source venv/bin/activate
nohup python run.py > app.log 2>&1 &
disown
sleep 2
tail -n 10 app.log

echo ""
echo "==> Uploading the Kiosk Application as the first release (v1.0.0, windows)"
TMP_KIOSK="$(mktemp -d)/kiosk-app-v1.0.0.zip"
mkdir -p "$(dirname "$TMP_KIOSK")"
base64 -d > "$TMP_KIOSK" << 'KIOSK_ZIP_EOF_MARKER'
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
KIOSK_ZIP_EOF_MARKER

set +e
UPLOAD_OUTPUT="$(FLASK_APP=run.py python -m flask upload-release "$TMP_KIOSK" 1.0.0 --notes "Initial kiosk app release" 2>&1)"
UPLOAD_STATUS=$?
set -e
echo "$UPLOAD_OUTPUT"
rm -f "$TMP_KIOSK"

if [ $UPLOAD_STATUS -ne 0 ]; then
    if echo "$UPLOAD_OUTPUT" | grep -q "already exists"; then
        echo "    (v1.0.0 was already uploaded on a previous run of this script - that's fine, nothing more to do.)"
    elif echo "$UPLOAD_OUTPUT" | grep -q "no platform-admin user exists"; then
        echo ""
        echo "    ACTION NEEDED: no platform-admin user exists yet, so the release could not"
        echo "    be uploaded automatically. Create one, then re-run just the upload step:"
        echo "        FLASK_APP=run.py python -m flask create-superuser you@example.com "Your Name" --platform-admin"
        echo "        FLASK_APP=run.py python -m flask upload-release <path-to-kiosk-app-v1.0.0.zip> 1.0.0"
        echo "    (the zip this script just used was deleted - re-download/rebuild it, or ask for it again)"
    else
        echo "    ERROR: release upload failed for an unexpected reason - see output above."
        exit 1
    fi
fi

echo ""
echo "Done. Every NEW enrollment from here on (the same irm .../install.ps1 command"
echo "already on the Enrollment tokens page, unchanged) will now, with no further"
echo "clicks: register, auto-get v1.0.0 of the kiosk app scheduled, download and"
echo "install it, auto-configure what starts it and its health check, and start it -"
echo "landing as a fully running, fully managed kiosk instance."
echo ""
echo "Already-enrolled instances (e.g. Ewan) don't retroactively get this - push"
echo "v1.0.0 to them manually from their instance page (Push Update), same as any"
echo "other release."
