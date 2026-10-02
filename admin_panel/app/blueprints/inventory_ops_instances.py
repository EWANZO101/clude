"""Fleet management for the "inventory-ops" product — deliberately a small,
right-sized blueprint, not a clone of instances.py's ~2500 lines. Reuses the
exact same generic Instance/EnrollmentToken/InstanceCommand/UpdatePackage/
UpdateDeployment models and app/update_scheduling.py helper Kiosk's own
instances.py already relies on, filtered by product_id (see app/models.py's
Instance.product_id/EnrollmentToken.product_id/UpdatePackage.product_id).

Deliberately NOT ported from instances.py: InstanceConfig push, license
management, backup scheduling, run_command, equipment/local-users/roles/
scan-token/remote-access panels, bulk_schedule, audit log — none of those
concepts exist for inventory-ops (it manages its own settings locally via
its own Settings page; see inventory_ops/app/blueprints/settings.py), so
porting them would be scope creep, not parity.
"""
import json
from datetime import datetime, timedelta

from flask import Blueprint, render_template, redirect, url_for, request, flash, g, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models import (
    Instance, EnrollmentToken, InstanceCommand, UpdatePackage, UpdateDeployment,
    Product, log_action,
)
from app.rbac import load_company_context, permission_required, require_product_access
from app.update_scheduling import resolve_deployment_target

bp = Blueprint(
    "inventory_ops_instances", __name__, url_prefix="/companies/<company_id>/inventory-ops-instances",
)
bp.before_request(require_product_access("inventory-ops", "Inventory Ops"))

LIFECYCLE_COMMAND_TYPES = ("start", "stop", "restart", "configure")


def _inventory_ops_product() -> Product:
    product = Product.query.filter_by(slug="inventory-ops").first()
    if product is None:
        abort(404)
    return product


@bp.route("/")
@login_required
@load_company_context
def list_instances(company_id):
    company = g.company
    product = _inventory_ops_product()
    instances = Instance.query.filter_by(company_id=company.id, product_id=product.id).order_by(
        Instance.created_at.desc()
    ).all()
    tokens = EnrollmentToken.query.filter_by(
        company_id=company.id, product_id=product.id, revoked=False
    ).order_by(EnrollmentToken.created_at.desc()).all()

    return render_template(
        "inventory_ops_instances/list.html", company=company, instances=instances, tokens=tokens,
        role=g.company_role,
    )


@bp.route("/tokens/new", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def new_token(company_id):
    company = g.company
    product = _inventory_ops_product()
    label = request.form.get("label", "").strip() or None
    expires_in_days = request.form.get("expires_in_days", "").strip()
    max_uses = request.form.get("max_uses", "").strip()

    token = EnrollmentToken(
        company_id=company.id, product_id=product.id, label=label, created_by_id=current_user.id,
    )
    if expires_in_days.isdigit() and int(expires_in_days) > 0:
        token.expires_at = datetime.utcnow() + timedelta(days=int(expires_in_days))
    if max_uses.isdigit() and int(max_uses) > 0:
        token.max_uses = int(max_uses)

    db.session.add(token)
    log_action(company, current_user, "inventory_ops_enrollment_token_created", label or "(no label)")
    db.session.commit()

    flash("Enrollment token created. Copy the install command before leaving this page.", "success")
    return redirect(url_for("inventory_ops_instances.list_instances", company_id=company.public_id))


@bp.route("/tokens/<int:token_id>/revoke", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def revoke_token(company_id, token_id):
    company = g.company
    product = _inventory_ops_product()
    token = EnrollmentToken.query.filter_by(id=token_id, company_id=company.id, product_id=product.id).first()
    if token is None:
        abort(404)
    token.revoked = True
    log_action(company, current_user, "inventory_ops_enrollment_token_revoked", token.label or token.token[:8])
    db.session.commit()
    flash("Enrollment token revoked.", "info")
    return redirect(url_for("inventory_ops_instances.list_instances", company_id=company.public_id))


def _get_instance_or_404(company, instance_id):
    product = _inventory_ops_product()
    instance = Instance.query.filter_by(
        public_id=instance_id, company_id=company.id, product_id=product.id,
    ).first()
    if instance is None:
        abort(404)
    return instance


def _usable_packages_for(instance):
    return UpdatePackage.query.filter_by(
        status="validated", withdrawn=False, product_id=instance.product_id,
    ).filter(UpdatePackage.supported_os.contains(instance.os)).order_by(
        UpdatePackage.uploaded_at.desc()
    ).all()


@bp.route("/<instance_id>")
@login_required
@load_company_context
def detail(company_id, instance_id):
    company = g.company
    instance = _get_instance_or_404(company, instance_id)

    pending_command = InstanceCommand.query.filter(
        InstanceCommand.instance_id == instance.id,
        InstanceCommand.command_type.in_(LIFECYCLE_COMMAND_TYPES),
        InstanceCommand.status.in_(("pending", "in_progress")),
    ).order_by(InstanceCommand.created_at.desc()).first()
    recent_commands = InstanceCommand.query.filter_by(instance_id=instance.id).order_by(
        InstanceCommand.created_at.desc()
    ).limit(10).all()

    can_manage_instances = current_user.has_permission(company.id, "manage_instances")
    can_manage_updates = (
        current_user.has_permission(company.id, "manage_updates")
        or current_user.has_permission(company.id, "operate_kiosk_updates")
    )

    return render_template(
        "inventory_ops_instances/detail.html", company=company, instance=instance, role=g.company_role,
        can_manage_instances=can_manage_instances, can_manage_updates=can_manage_updates,
        pending_command=pending_command, recent_commands=recent_commands,
        usable_packages=_usable_packages_for(instance),
        active_deployment=instance.active_deployment(),
        deployment_history=instance.deployments,
    )


def _queue_command(instance, command_type, payload=None):
    existing = InstanceCommand.query.filter_by(instance_id=instance.id, status="pending").first()
    if existing is not None:
        existing.status = "failed"
        existing.result_message = "Superseded by a newer command before the Agent picked it up."
        existing.acked_at = datetime.utcnow()

    command = InstanceCommand(
        instance_id=instance.id, command_type=command_type,
        payload_json=json.dumps(payload) if payload else None,
        requested_by_id=current_user.id,
    )
    db.session.add(command)
    return command


@bp.route("/<instance_id>/start", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def start(company_id, instance_id):
    company = g.company
    instance = _get_instance_or_404(company, instance_id)
    _queue_command(instance, "start")
    log_action(company, current_user, "inventory_ops_start_queued", instance.display_name())
    db.session.commit()
    flash("Start queued — the Agent will pick it up on its next poll.", "success")
    return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/stop", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def stop(company_id, instance_id):
    company = g.company
    instance = _get_instance_or_404(company, instance_id)
    _queue_command(instance, "stop")
    log_action(company, current_user, "inventory_ops_stop_queued", instance.display_name())
    db.session.commit()
    flash("Stop queued — the Agent will pick it up on its next poll.", "success")
    return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/restart", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def restart(company_id, instance_id):
    company = g.company
    instance = _get_instance_or_404(company, instance_id)
    _queue_command(instance, "restart")
    log_action(company, current_user, "inventory_ops_restart_queued", instance.display_name())
    db.session.commit()
    flash("Restart queued — the Agent will pick it up on its next poll.", "success")
    return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/rename", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def rename(company_id, instance_id):
    company = g.company
    instance = _get_instance_or_404(company, instance_id)
    instance.name = request.form.get("name", "").strip() or None
    db.session.commit()
    flash("Instance renamed.", "success")
    return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def delete_instance(company_id, instance_id):
    company = g.company
    instance = _get_instance_or_404(company, instance_id)
    display_name = instance.display_name()

    InstanceCommand.query.filter_by(instance_id=instance.id).delete()
    log_action(company, current_user, "inventory_ops_instance_deleted", display_name)
    db.session.delete(instance)  # cascades to deployments via its relationship()
    db.session.commit()

    flash(f"{display_name} has been deleted.", "success")
    return redirect(url_for("inventory_ops_instances.list_instances", company_id=company.public_id))


@bp.route("/<instance_id>/updates/schedule", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_updates", "operate_kiosk_updates")
def schedule_update(company_id, instance_id):
    company = g.company
    instance = _get_instance_or_404(company, instance_id)

    package = UpdatePackage.query.filter_by(
        public_id=request.form.get("package_id"), product_id=instance.product_id,
    ).first()
    mode = request.form.get("mode", "now")
    if package is None:
        flash("Choose a package to push.", "danger")
        return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    if not package.is_usable():
        flash(f"Package v{package.version} is not usable (invalid or withdrawn).", "danger")
        return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))
    if instance.os not in package.supported_os_list():
        flash(f"Package v{package.version} does not support {instance.os}.", "danger")
        return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    existing = instance.active_deployment()
    if existing is not None:
        if existing.status in ("scheduled", "waiting"):
            existing.status = "superseded"
            existing.append_log("superseded", "replaced by a newer push before it started")
        else:
            flash(
                f"Instance already has an update in progress (v{existing.package.version}, "
                f"status: {existing.status}) — wait for it to finish before pushing another.",
                "danger",
            )
            return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    target_time_utc, source = resolve_deployment_target(instance, mode, None)
    deployment = UpdateDeployment(
        instance_id=instance.id, package_id=package.id, requested_by_id=current_user.id,
        target_time_utc=target_time_utc, schedule_source=source, previous_version=instance.app_version,
    )
    deployment.append_log("scheduled", f"requested by {current_user.email}, source={source}")
    db.session.add(deployment)
    log_action(company, current_user, "inventory_ops_update_pushed", f"{instance.display_name()} -> v{package.version} ({mode})")
    db.session.commit()
    flash(f"Update to v{package.version} pushed.", "success")
    return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/updates/<deployment_id>/cancel", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_updates", "operate_kiosk_updates")
def cancel_update(company_id, instance_id, deployment_id):
    company = g.company
    instance = _get_instance_or_404(company, instance_id)
    deployment = UpdateDeployment.query.filter_by(public_id=deployment_id, instance_id=instance.id).first()
    if deployment is None:
        abort(404)
    if deployment.status not in ("scheduled", "waiting"):
        flash("That update has already started and can no longer be cancelled from here.", "warning")
        return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    deployment.status = "cancelled"
    deployment.cancelled_at = datetime.utcnow()
    deployment.cancelled_by_id = current_user.id
    log_action(company, current_user, "inventory_ops_update_cancelled", f"{instance.display_name()} v{deployment.package.version}")
    db.session.commit()
    flash("Scheduled update cancelled.", "info")
    return redirect(url_for("inventory_ops_instances.detail", company_id=company.public_id, instance_id=instance.public_id))
