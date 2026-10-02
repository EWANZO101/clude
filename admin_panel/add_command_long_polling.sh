#!/usr/bin/env bash
# Makes Start/Stop/Restart/Configure/Run-command feel instant instead of
# taking up to command_poll_interval_seconds (15s) to reach the Agent.
#
# GET /api/v1/instances/commands now supports long-polling via ?wait=<s>
# (capped at 25s): holds the connection open, re-checking every ~1s,
# until either a command shows up or the wait expires - instead of always
# returning immediately and making the caller sleep a full interval before
# trying again. The Agent's command-poll loop now uses this by default
# (20s), falling back to the ordinary interval only as a backoff after a
# real failure (server unreachable, auth error).
#
# run.py now passes threaded=True to app.run(). This matters more than
# usual here: without it, Werkzeug's dev server (still what every deploy
# in this project actually runs - nohup python run.py, not gunicorn)
# handles ONE request at a time, so a 20s long-poll from one instance
# would block every other request - other instances' polls, heartbeats,
# the Admin Panel's own pages - for up to 20 seconds. Verified this
# concretely: a quick request completed in 0.15s while a concurrent 5s
# long-poll was in flight, with threaded=True in place.
#
# Also verified: a command queued 3s into a 20s long-poll window is
# delivered in ~3.2s (not the full 20s); the "nothing queued" timeout case
# returns cleanly at the requested wait duration, not early or with an
# error.
#
# Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for req in agent requirements.txt service_files app/blueprints run.py; do
    if [ ! -e "$req" ]; then
        echo "Error: expected to find '$req' here - run this from the admin_panel repo root."
        exit 1
    fi
done

echo "==> Writing run.py"
cat > run.py << 'FILEEOF_5764892000531026216'
from app import create_app

app = create_app()

if __name__ == "__main__":
    # threaded=True matters more than usual here: get_pending_command below
    # now long-polls (holds the connection open for up to ~20s waiting for
    # a command) so Start/Stop/Restart/Run-command feel instant instead of
    # waiting for the next ~15s poll interval. Without threaded=True,
    # Werkzeug's dev server handles one request at a time — every other
    # request (heartbeats, other instances' polls, the Admin Panel's own
    # pages) would queue up behind whichever connection is mid-long-poll
    # for up to 20 seconds. This is still the Werkzeug dev server, not a
    # production WSGI server (gunicorn is in requirements.txt but nothing
    # in this deployment actually invokes it yet — every deploy so far has
    # used `nohup python run.py`) — a separate, known gap from this fix.
    app.run(debug=True, host="0.0.0.0", port=6090, threaded=True)
FILEEOF_5764892000531026216

echo "==> Writing app/blueprints/agent_api.py"
cat > app/blueprints/agent_api.py << 'FILEEOF_5903714368462734817'
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

    while True:
        command = InstanceCommand.query.filter_by(
            instance_id=g.instance.id, status="pending"
        ).order_by(InstanceCommand.created_at.asc()).first()

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

FILEEOF_5903714368462734817

echo "==> Extracting fixed agent/ into this repo (long-polling client side)"
TMP_EXTRACT="$(mktemp -d)"
base64 -d > "$TMP_EXTRACT/opslab-agent.tar.gz" << 'AGENT_TAR_EOF_MARKER'
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
AGENT_TAR_EOF_MARKER
tar -xzf "$TMP_EXTRACT/opslab-agent.tar.gz" -C "$TMP_EXTRACT"

if ! grep -q "long_poll_wait_seconds" "$TMP_EXTRACT/agent/commands.py"; then
    echo "    ERROR: fix not found in the extracted agent payload!"
    rm -rf "$TMP_EXTRACT"
    exit 1
fi

rm -f agent/config.py.bak
cp -f "$TMP_EXTRACT/agent/"*.py agent/
echo "    Updated agent/*.py in this repo."

echo "==> Rewriting app/static/installers/opslab-agent.tar.gz (served by /install.ps1)"
cp -f "$TMP_EXTRACT/opslab-agent.tar.gz" app/static/installers/opslab-agent.tar.gz
rm -rf "$TMP_EXTRACT"

echo "==> Verifying"
python3 -m py_compile run.py app/blueprints/agent_api.py && echo "    admin_panel python files compile OK"
tar -tzf app/static/installers/opslab-agent.tar.gz > /dev/null && echo "    served agent tarball is readable"

echo ""
echo "==> Restarting the admin panel app (run.py changed - needs threaded=True to take effect)"
pkill -f "admin_panel/run.py" 2>/dev/null || true
fuser -k 6090/tcp 2>/dev/null || true
sleep 1
source venv/bin/activate
nohup python run.py > app.log 2>&1 &
disown
sleep 2
tail -n 10 app.log

echo ""
echo "Done. On Ewan, re-enroll once more to pick up the Agent-side change:"
echo "    irm https://kiosksys.opslabsystems.cloud/install.ps1 -OutFile install.ps1; .\\install.ps1 -Token <fresh-token> -AdminUrl https://kiosksys.opslabsystems.cloud"
echo ""
echo "After that, clicking Start/Stop/Restart in the panel should take effect in"
echo "about a second, not up to 15."
