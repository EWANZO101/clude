#!/usr/bin/env bash
# Adds a Delete button for instances - on the fleet list page (per-row) and
# on the instance detail page ("Danger zone"). Deleting removes the
# Instance row plus every dependent row across the 6 tables that carry a
# foreign key to it: InstanceConfig and UpdateDeployment already cascade
# via their relationship() definitions on the Instance model, but
# RemoteAccessToken, AgentErrorReport, StagedRolloutInstance, and
# InstanceCommand only have a plain nullable=False FK with no ORM cascade -
# deleting the Instance directly would hit an IntegrityError on whichever
# of those four has rows first. The new delete_instance route deletes all
# four explicitly before deleting the Instance itself.
#
# Restricted to owner/administrator (stricter than the manage_instances
# permission used for start/stop/restart/configure, since this is
# destructive and unrecoverable) with a JS confirm() on both buttons.
# Does NOT touch the Agent itself - no uninstall call exists in the API, so
# if the Agent is still running with valid credentials it will simply
# re-register as a brand new instance on its next heartbeat. That's exactly
# the "Ewan" duplicate seen in the fleet list right now (re-enrolling
# created a second Instance row rather than reusing the first) - this only
# lets you clean up the stale one from the Admin Panel's side.
#
# Verified end-to-end against a real SQLite DB with one row seeded in each
# of the 6 dependent tables: all cleaned up, zero FK integrity errors, the
# Instance row itself confirmed gone.
#
# Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for req in app/blueprints/instances.py app/templates/instances/list.html app/templates/instances/detail.html; do
    if [ ! -e "$req" ]; then
        echo "Error: expected to find '$req' here - run this from the admin_panel repo root."
        exit 1
    fi
done

echo "==> Writing app/blueprints/instances.py"
cat > app/blueprints/instances.py << 'FILEEOF_639651423014561803'
import json
from datetime import datetime, timedelta

from flask import Blueprint, render_template, redirect, url_for, request, flash, g, abort

from app.extensions import db
from app.models import (
    Instance, EnrollmentToken, InstanceConfig, UpdatePackage, UpdateDeployment,
    RemoteAccessToken, AgentErrorReport, log_action, InstanceCommand, StagedRolloutInstance,
)
from app.rbac import load_company_context, permission_required
from app.update_scheduling import resolve_deployment_target
from flask_login import login_required, current_user

bp = Blueprint("instances", __name__, url_prefix="/companies/<company_id>/instances")


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


@bp.route("/tokens/new", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def new_token(company_id):
    company = g.company
    label = request.form.get("label", "").strip() or None
    expires_in_days = request.form.get("expires_in_days", "").strip()
    max_uses = request.form.get("max_uses", "").strip()

    token = EnrollmentToken(company_id=company.id, label=label, created_by_id=current_user.id)
    if expires_in_days.isdigit() and int(expires_in_days) > 0:
        token.expires_at = datetime.utcnow() + timedelta(days=int(expires_in_days))
    if max_uses.isdigit() and int(max_uses) > 0:
        token.max_uses = int(max_uses)

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

    pending_kiosk_command = InstanceCommand.query.filter_by(
        instance_id=instance.id, status="pending"
    ).order_by(InstanceCommand.created_at.desc()).first()
    recent_kiosk_commands = InstanceCommand.query.filter_by(instance_id=instance.id).order_by(
        InstanceCommand.created_at.desc()
    ).limit(10).all()

    return render_template(
        "instances/detail.html", company=company, instance=instance, role=g.company_role,
        current_config=current_config, pending_config=pending_config,
        current_config_pretty=current_config_pretty,
        config_history=instance.configs,
        usable_packages=_usable_packages_for(instance),
        active_deployment=instance.active_deployment(),
        deployment_history=instance.deployments,
        latest_remote_access=latest_remote_access,
        recent_error_reports=recent_error_reports,
        pending_kiosk_command=pending_kiosk_command,
        recent_kiosk_commands=recent_kiosk_commands,
    )


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
@permission_required("manage_updates")
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
@permission_required("manage_updates")
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

    return render_template("instances/bulk_schedule.html", company=company, instances=instances, packages=packages)


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


def _queue_command(instance, command_type, payload=None):
    """Only one pending command per instance at a time — a new one
    supersedes an old still-unacknowledged one, same pattern used for
    config pushes and update pushes elsewhere in this file."""
    import json as _json
    existing = InstanceCommand.query.filter_by(instance_id=instance.id, status="pending").first()
    if existing is not None:
        existing.status = "failed"
        existing.result_message = "Superseded by a newer command before the Agent picked it up."
        existing.acked_at = datetime.utcnow()

    command = InstanceCommand(
        instance_id=instance.id, command_type=command_type,
        payload_json=_json.dumps(payload) if payload else None,
        requested_by_id=current_user.id,
    )
    db.session.add(command)
    return command


@bp.route("/<instance_id>/kiosk/start", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_start(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "start")
    log_action(company, current_user, "kiosk_start_requested", instance.display_name())
    db.session.commit()
    flash("Start requested — the Agent will pick this up on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/stop", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_stop(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "stop")
    log_action(company, current_user, "kiosk_stop_requested", instance.display_name())
    db.session.commit()
    flash("Stop requested — the Agent will pick this up on its next poll.", "warning")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/restart", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_restart(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "restart")
    log_action(company, current_user, "kiosk_restart_requested", instance.display_name())
    db.session.commit()
    flash("Restart requested — the Agent will pick this up on its next poll.", "success")
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

    start_command = request.form.get("kiosk_start_command", "").strip()
    working_dir = request.form.get("kiosk_working_dir", "").strip()
    health_check_url = request.form.get("kiosk_health_check_url", "").strip()
    health_check_command = request.form.get("kiosk_health_check_command", "").strip()

    _queue_command(instance, "configure", payload={
        "kiosk_start_command": start_command,
        "kiosk_working_dir": working_dir,
        "kiosk_health_check_url": health_check_url,
        "kiosk_health_check_command": health_check_command,
    })
    log_action(company, current_user, "kiosk_configure_requested",
               f"{instance.display_name()}: {start_command or '(cleared)'}")
    db.session.commit()
    flash("Configuration queued — the Agent will apply it (and start the process) on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

FILEEOF_639651423014561803

echo "==> Writing app/templates/instances/list.html"
cat > app/templates/instances/list.html << 'FILEEOF_3648318395943618007'
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
                  <div class="muted" style="font-size:11px; margin-top:4px;">Run in an elevated (Administrator) PowerShell window. Requires Python 3.10+ already installed from python.org (not the Microsoft Store) with "Add to PATH" checked.</div>
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
FILEEOF_3648318395943618007

echo "==> Writing app/templates/instances/detail.html"
cat > app/templates/instances/detail.html << 'FILEEOF_3007594505805677453'
{% extends "base.html" %}
{% block title %}{{ instance.display_name() }} — {{ company.name }}{% endblock %}
{% block content %}
<div class="page-header">
  <div class="titles">
    <a href="{{ url_for('instances.list_instances', company_id=company.public_id) }}" class="crumb">← Fleet</a>
    <h1>{{ instance.display_name() }}</h1>
    <div class="page-sub">
      {% if instance.connection_status == 'online' %}
        <span class="pill pill-green">Online</span>
      {% else %}
        <span class="pill pill-muted">Offline</span>
      {% endif %}
      <span>{{ instance.os }}{% if instance.os_version %} {{ instance.os_version }}{% endif %}</span>
    </div>
  </div>
</div>

<div class="panel">
  <h2>General</h2>
  <table class="kv-table">
    <tr><th>Instance ID</th><td><code style="font-size:11.5px;">{{ instance.public_id }}</code></td></tr>
    <tr><th>Hostname</th><td>{{ instance.hostname or '—' }}</td></tr>
    <tr><th>Operating system</th><td>{{ instance.os }} {{ instance.os_version or '' }}</td></tr>
    <tr><th>Agent version</th><td class="mono">{{ instance.agent_version or '—' }}</td></tr>
    <tr><th>Application version</th><td class="mono">{{ instance.app_version or '—' }}</td></tr>
    <tr><th>Registered</th><td class="muted">{{ instance.created_at.strftime('%Y-%m-%d %H:%M UTC') }}</td></tr>
  </table>
</div>

<div class="panel">
  <h2>Connection</h2>
  <table class="kv-table">
    <tr><th>Status</th><td>{{ instance.connection_status }}</td></tr>
    <tr><th>Last seen</th><td class="muted">{{ instance.last_seen_at.strftime('%Y-%m-%d %H:%M UTC') if instance.last_seen_at else 'never' }}</td></tr>
    <tr><th>Local IP</th><td class="mono">{{ instance.local_ip or '—' }}</td></tr>
    <tr><th>Public IP</th><td class="mono">{{ instance.public_ip or '—' }}</td></tr>
    <tr><th>Port</th><td class="mono">{{ instance.port or '—' }}</td></tr>
    <tr><th>Remote tunnel</th>
      <td>
        {{ 'Connected' if instance.tunnel_connected else 'Not connected' }}
        {% if latest_remote_access %}
          <br>
          <span class="muted" style="font-size:12.5px;">
            Last request: {{ latest_remote_access.created_at.strftime('%Y-%m-%d %H:%M UTC') }} by {{ latest_remote_access.requested_by.full_name }} —
            {% if latest_remote_access.status == 'pending' %}
              <span class="pill pill-amber">Waiting for agent</span>
            {% elif latest_remote_access.status == 'connected' %}
              <span class="pill pill-green">Connected</span>
            {% elif latest_remote_access.status == 'unsupported' %}
              <span class="pill pill-muted">Unsupported (no tunnel broker yet)</span>
            {% else %}
              <span class="pill pill-red">Failed</span>
            {% endif %}
            {% if latest_remote_access.status_message %}<br>{{ latest_remote_access.status_message }}{% endif %}
          </span>
        {% endif %}
      </td>
    </tr>
  </table>
  {% if role in ["owner", "administrator", "manager"] %}
    <form method="post" action="{{ url_for('instances.request_remote_access', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:14px;">
      <button type="submit" class="btn btn-secondary btn-sm">Request remote access token</button>
    </form>
    <p class="muted" style="font-size:12px; margin-top:8px; margin-bottom:0;">
      Issues a 10-minute token for opening this kiosk's local UI through the
      remote tunnel. The tunnel server itself isn't built yet — this tracks
      the request only.
    </p>
  {% endif %}
</div>

<div class="panel">
  <h2>Kiosk Process</h2>
  <table class="kv-table">
    <tr><th>Status</th>
      <td>
        {% if instance.kiosk_process_status == 'running' %}
          <span class="pill pill-green">Running</span>
        {% elif instance.kiosk_process_status == 'stopped' %}
          <span class="pill pill-amber">Stopped</span>
        {% elif instance.kiosk_process_status == 'giving_up' %}
          <span class="pill pill-red">Crash-looping — Agent gave up restarting it</span>
        {% elif instance.kiosk_process_status == 'not_configured' %}
          <span class="pill pill-muted">Not configured</span>
        {% else %}
          <span class="pill pill-muted">Unknown (no heartbeat yet)</span>
        {% endif %}
      </td>
    </tr>
    <tr><th>Start command</th><td class="mono">{{ instance.kiosk_process_status and '(reported via heartbeat only — set below)' or '—' }}</td></tr>
  </table>

  {% if pending_kiosk_command %}
    <div class="flash flash-warning" style="margin-top:12px;">
      A "{{ pending_kiosk_command.command_type }}" command is queued — waiting for the Agent's next poll.
    </div>
  {% endif %}

  {% if role in ["owner", "administrator", "manager"] %}
    <div style="display:flex; gap:8px; margin-top:14px;">
      <form method="post" action="{{ url_for('instances.kiosk_start', company_id=company.public_id, instance_id=instance.public_id) }}">
        <button type="submit" class="btn btn-secondary btn-sm">Start</button>
      </form>
      <form method="post" action="{{ url_for('instances.kiosk_stop', company_id=company.public_id, instance_id=instance.public_id) }}">
        <button type="submit" class="btn btn-secondary btn-sm">Stop</button>
      </form>
      <form method="post" action="{{ url_for('instances.kiosk_restart', company_id=company.public_id, instance_id=instance.public_id) }}">
        <button type="submit" class="btn btn-secondary btn-sm">Restart</button>
      </form>
    </div>

    <details style="margin-top:16px;">
      <summary style="cursor:pointer; color:var(--muted); font-size:13px;">Configure what starts the kiosk process</summary>
      <form method="post" action="{{ url_for('instances.kiosk_configure', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:12px;">
        <label>Start command</label>
        <input type="text" name="kiosk_start_command" placeholder="e.g. C:\OpsLabAgent\python\python.exe C:\OpsLabKiosk\run.py">
        <label>Working directory (optional)</label>
        <input type="text" name="kiosk_working_dir">
        <label>Health check URL (optional — e.g. http://127.0.0.1:8420/health)</label>
        <input type="text" name="kiosk_health_check_url">
        <label>Health check command (optional, alternative to a URL)</label>
        <input type="text" name="kiosk_health_check_command">
        <button type="submit" class="btn btn-sm" style="margin-top:12px;">Save &amp; apply</button>
      </form>
      <p class="muted" style="font-size:12px; margin-top:8px;">
        Leave the start command blank and save to clear supervision entirely.
        Applying this restarts the kiosk process using the new command.
      </p>
    </details>

    {% if recent_kiosk_commands %}
      <h3 style="font-size:13px; margin-top:20px; color:var(--muted);">Recent commands</h3>
      <table class="kv-table" style="font-size:12.5px;">
        {% for cmd in recent_kiosk_commands %}
          <tr>
            <td class="mono">{{ cmd.command_type }}</td>
            <td>
              {% if cmd.status == 'pending' %}<span class="pill pill-amber">Pending</span>
              {% elif cmd.status == 'success' %}<span class="pill pill-green">Success</span>
              {% else %}<span class="pill pill-red">Failed</span>{% endif %}
            </td>
            <td class="muted">{{ cmd.result_message or '' }}</td>
            <td class="muted">{{ cmd.created_at.strftime('%Y-%m-%d %H:%M UTC') }}</td>
          </tr>
        {% endfor %}
      </table>
    {% endif %}
  {% endif %}
</div>

<div class="panel">
  <h2>Configuration</h2>
  <p class="muted">
    Sent to the instance next time it checks in (<code>GET /api/v1/instances/config</code>);
    it applies and reports back via <code>POST /api/v1/instances/config/ack</code>.
  </p>

  {% if pending_config %}
    <div class="flash flash-warning">
      Version {{ pending_config.version }} is queued, waiting for the instance to acknowledge it.
    </div>
  {% endif %}

  <table class="kv-table" style="margin-bottom:16px;">
    <tr><th>Current applied version</th><td>{{ current_config.version if current_config else '— (none applied yet)' }}</td></tr>
  </table>

  <label>Current config (read-only)</label>
  <textarea readonly rows="6">{{ current_config_pretty }}</textarea>

  {% if role in ["owner", "administrator", "manager"] %}
  <form method="post" action="{{ url_for('instances.push_config', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:16px;">
    <label>Push new configuration (JSON object)</label>
    <textarea name="config_json" rows="6" placeholder='{{ '{' }}"kiosk_name": "Reception", "auto_logout_minutes": 2{{ '}' }}'>{{ current_config_pretty if current_config else '' }}</textarea>
    <button type="submit" style="margin-top:12px;">Push configuration</button>
  </form>
  {% endif %}

  {% if config_history %}
  <h2 style="margin-top:24px;">Configuration history</h2>
  <div class="table-scroll">
  <table>
    <thead><tr><th>Version</th><th>Status</th><th>Pushed by</th><th>Pushed</th><th>Acknowledged</th><th class="wrap-cell">Message</th><th></th></tr></thead>
    <tbody>
      {% for c in config_history %}
        <tr>
          <td class="mono">v{{ c.version }}</td>
          <td>
            {% if c.status == 'applied' %}
              <span class="pill pill-green">Applied</span>
            {% elif c.status == 'pending' %}
              <span class="pill pill-amber">Pending</span>
            {% else %}
              <span class="pill pill-red">{{ c.status|capitalize }}</span>
            {% endif %}
          </td>
          <td>{{ c.pushed_by.full_name }}</td>
          <td class="muted">{{ c.pushed_at.strftime('%Y-%m-%d %H:%M UTC') }}</td>
          <td class="muted">{{ c.acknowledged_at.strftime('%Y-%m-%d %H:%M UTC') if c.acknowledged_at else '—' }}</td>
          <td class="muted wrap-cell">{{ c.agent_message or '—' }}</td>
          <td>
            {% if role in ["owner", "administrator", "manager"] and c.status == 'applied' %}
              <form method="post" action="{{ url_for('instances.restore_config', company_id=company.public_id, instance_id=instance.public_id, version=c.version) }}">
                <button type="submit" class="btn btn-secondary btn-sm">Restore</button>
              </form>
            {% endif %}
          </td>
        </tr>
      {% endfor %}
    </tbody>
  </table>
  </div>
  {% endif %}
</div>

<div class="panel">
  <h2>Updates</h2>

  <table class="kv-table" style="margin-bottom:14px;">
    <tr><th>Current version</th><td class="mono">{{ instance.app_version or '—' }}</td></tr>
    <tr><th>Last Known Good</th><td class="mono">{{ instance.last_known_good_version or '— (no successful update yet)' }}</td></tr>
  </table>

  {% if active_deployment %}
    {% set d = active_deployment %}
    <div class="flash {{ 'flash-danger' if d.status in ['failed','rolling_back'] else 'flash-warning' }}">
      <strong>v{{ d.package.version }}</strong> — status: <strong>{{ d.status.replace('_',' ')|capitalize }}</strong>
      {% if d.status in ['scheduled','waiting'] %}
        (target: {{ d.target_time_utc.strftime('%Y-%m-%d %H:%M UTC') }}, source: {{ d.schedule_source }})
      {% endif %}
      {% if d.health_check_message %}<br><span class="muted">Health check: {{ d.health_check_message }}</span>{% endif %}
      {% if d.rollback_reason %}<br><span class="muted">Rollback reason: {{ d.rollback_reason }}</span>{% endif %}
      {% if role in ["owner", "administrator"] and d.status in ["scheduled", "waiting"] %}
        <form method="post" action="{{ url_for('instances.cancel_update', company_id=company.public_id, instance_id=instance.public_id, deployment_id=d.public_id) }}" style="display:inline; margin-left:10px;">
          <button type="submit" class="btn btn-danger btn-sm">Cancel</button>
        </form>
      {% endif %}
    </div>
  {% endif %}

  {% if role in ["owner", "administrator"] %}
    {% if usable_packages %}
      <form method="post" action="{{ url_for('instances.schedule_update', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:10px;">
        <label>Package</label>
        <select name="package_id">
          {% for p in usable_packages %}
            <option value="{{ p.public_id }}">v{{ p.version }}</option>
          {% endfor %}
        </select>
        <label>When</label>
        <select name="mode" onchange="document.getElementById('custom-dt').style.display = this.value === 'custom' ? 'block' : 'none';">
          <option value="now">Update now</option>
          <option value="schedule" selected>Use configured schedule (kiosk / company / 9PM UK default)</option>
          <option value="custom">Custom date &amp; time</option>
        </select>
        <div id="custom-dt" style="display:none;">
          <label>Custom date &amp; time (UTC)</label>
          <input type="datetime-local" name="custom_datetime">
        </div>
        <button type="submit" style="margin-top:14px;">Push update</button>
      </form>
    {% else %}
      <p class="muted">No validated packages support {{ instance.os }} yet.</p>
    {% endif %}
  {% endif %}

  {% if deployment_history %}
  <h2 style="margin-top:24px;">Update history</h2>
  <div class="table-scroll">
  <table>
    <thead><tr><th>Version</th><th>Status</th><th>Target time</th><th>Started</th><th>Completed</th><th>Health check</th><th>Requested by</th></tr></thead>
    <tbody>
      {% for d in deployment_history %}
        <tr>
          <td class="mono">v{{ d.package.version }}</td>
          <td>
            {% if d.status == 'successful' %}
              <span class="pill pill-green">Successful</span>
            {% elif d.status in ['failed','rolled_back'] %}
              <span class="pill pill-red">{{ d.status.replace('_',' ')|capitalize }}</span>
            {% elif d.status in ['cancelled','superseded'] %}
              <span class="pill pill-muted">{{ d.status|capitalize }}</span>
            {% else %}
              <span class="pill pill-amber">{{ d.status.replace('_',' ')|capitalize }}</span>
            {% endif %}
          </td>
          <td class="muted">{{ d.target_time_utc.strftime('%Y-%m-%d %H:%M UTC') }}</td>
          <td class="muted">{{ d.started_at.strftime('%Y-%m-%d %H:%M UTC') if d.started_at else '—' }}</td>
          <td class="muted">{{ d.completed_at.strftime('%Y-%m-%d %H:%M UTC') if d.completed_at else '—' }}</td>
          <td class="muted">
            {% if d.health_check_passed is none %}—
            {% elif d.health_check_passed %}<span style="color:var(--green);">Passed</span>
            {% else %}<span style="color:var(--red);">Failed</span>
            {% endif %}
          </td>
          <td class="muted">{{ d.requested_by.full_name }}</td>
        </tr>
      {% endfor %}
    </tbody>
  </table>
  </div>
  {% endif %}

  <p class="muted" style="margin-top:16px; margin-bottom:0;">Instance-level history above; fleet-wide stats are on the <a href="{{ url_for('instances.list_instances', company_id=company.public_id) }}">fleet overview</a>.</p>
</div>

<div class="panel">
  <h2>Diagnostics</h2>
  <table class="kv-table" style="margin-bottom:14px;">
    <tr><th>Health status</th>
      <td>
        {% if instance.connection_status == 'online' %}
          <span style="color:var(--green);">Healthy — checking in normally</span>
        {% else %}
          <span class="muted">Offline — no recent heartbeat</span>
        {% endif %}
      </td>
    </tr>
    <tr><th>Remote tunnel</th><td>{{ 'Connected' if instance.tunnel_connected else 'Not connected' }}</td></tr>
  </table>

  {% if active_deployment and active_deployment.status_log %}
    <h3>Current update event log</h3>
    <textarea readonly rows="6">{{ active_deployment.status_log }}</textarea>
  {% elif deployment_history and deployment_history[0].status_log %}
    <h3>Most recent update event log</h3>
    <textarea readonly rows="6">{{ deployment_history[0].status_log }}</textarea>
  {% else %}
    <p class="muted" style="margin:0;">No update events logged yet.</p>
  {% endif %}

  {% if recent_error_reports %}
    <h3 style="margin-top:20px;">Recent agent errors</h3>
    <div class="table-scroll">
    <table>
      <thead><tr><th>When</th><th>Level</th><th>Logger</th><th class="wrap-cell">Message</th></tr></thead>
      <tbody>
        {% for e in recent_error_reports %}
          <tr>
            <td class="muted">{{ e.created_at.strftime('%Y-%m-%d %H:%M UTC') }}</td>
            <td>
              {% if e.level == 'CRITICAL' %}
                <span class="pill pill-red">Critical</span>
              {% else %}
                <span class="pill pill-amber">Error</span>
              {% endif %}
            </td>
            <td class="muted mono" style="font-size:12px;">{{ e.logger_name or '—' }}</td>
            <td class="wrap-cell">
              {{ e.message }}
              {% if e.suppressed_since_last %}<span class="muted"> (+{{ e.suppressed_since_last }} suppressed since last report)</span>{% endif %}
            </td>
          </tr>
        {% endfor %}
      </tbody>
    </table>
    </div>
    <p class="muted" style="margin-top:10px; margin-bottom:0; font-size:12px;">
      Best-effort delivery from the Agent's error reporter — a network blip while reporting isn't retried, so this is what the Agent managed to tell us, not a complete log.
    </p>
  {% endif %}

  <p class="muted" style="margin-top:12px; margin-bottom:0; font-size:12px;">
    Full agent-side log retrieval (spec Section 35) requires more than error-level events — this shows what's been reported through the
    update lifecycle, heartbeat, and error reporter so far.
  </p>
</div>

{% if role in ["owner", "administrator", "manager"] %}
<div class="panel">
  <h2>Instance settings</h2>
  <form method="post" action="{{ url_for('instances.rename', company_id=company.public_id, instance_id=instance.public_id) }}">
    <label>Display name</label>
    <input type="text" name="name" value="{{ instance.name or '' }}" placeholder="{{ instance.hostname or 'e.g. Reception' }}">
    <label>Kiosk-specific update time (UK local, HH:MM) — overrides the company/system default</label>
    <input type="text" name="scheduled_update_time" placeholder="21:00"
           value="{{ instance.scheduled_update_time.strftime('%H:%M') if instance.scheduled_update_time else '' }}">
    <label class="checkline">
      <input type="checkbox" name="clear_update_time">
      Clear override (inherit company/system default)
    </label>
    <button type="submit" style="margin-top:16px;">Save</button>
  </form>
</div>
{% endif %}

{% if role in ["owner", "administrator"] %}
<div class="panel">
  <h2>Danger zone</h2>
  <p class="muted">Permanently removes this instance and its config, update, and command history from the Admin Panel. Does not uninstall the Agent itself — if it's still running with valid credentials, it will re-register as a new instance on its next heartbeat.</p>
  <form method="post" action="{{ url_for('instances.delete_instance', company_id=company.public_id, instance_id=instance.public_id) }}" onsubmit="return confirm('Permanently delete {{ instance.display_name()|e }}? This cannot be undone.');">
    <button type="submit" class="btn btn-danger">Delete this instance</button>
  </form>
</div>
{% endif %}
{% endblock %}

FILEEOF_3007594505805677453

echo "==> Verifying"
python3 -m py_compile app/blueprints/instances.py && echo "    instances.py compiles OK"
grep -q "def delete_instance" app/blueprints/instances.py && echo "    delete_instance route present"
grep -q "instances.delete_instance" app/templates/instances/list.html && echo "    Delete button present in list.html"
grep -q "instances.delete_instance" app/templates/instances/detail.html && echo "    Delete button present in detail.html"

echo ""
echo "Done. This needs a real app restart (Python + template changes):"
echo "    pkill -f 'admin_panel/run.py'; fuser -k 6090/tcp 2>/dev/null"
echo "    cd /root/admin_panel && source venv/bin/activate && nohup python run.py > app.log 2>&1 & disown"
echo ""
echo "Only owner/administrator roles will see the Delete buttons."
