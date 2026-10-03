from datetime import datetime

from flask import Blueprint, render_template, redirect, url_for, request, flash, g, abort
from flask_login import login_required, current_user

from app.extensions import db
from app.models import Instance, UpdatePackage, StagedRollout, StagedRolloutInstance, log_action
from app.rbac import load_company_context, permission_required, require_product_access
from app.blueprints.instances import _schedule_update, _usable_packages_for

bp = Blueprint("rollouts", __name__, url_prefix="/companies/<company_id>/rollouts")
bp.before_request(require_product_access("kiosk", "the Kiosk System"))


@bp.route("/")
@login_required
@load_company_context
def list_rollouts(company_id):
    company = g.company
    rollouts = StagedRollout.query.filter_by(company_id=company.id).order_by(
        StagedRollout.created_at.desc()
    ).all()
    return render_template("rollouts/list.html", company=company, rollouts=rollouts, role=g.company_role)


def _push_batch(rollout, batch_number, user):
    """Pushes every not-yet-pushed member of the given batch. Returns
    (succeeded_names, failed_pairs) — one instance's rejection never stops
    the rest of the batch (same principle as bulk push, spec Section 41)."""
    succeeded, failed = [], []
    for member in rollout.members:
        if member.batch_number != batch_number or member.deployment_id is not None:
            continue
        deployment, error = _schedule_update(member.instance, rollout.package, rollout.mode, None, user)
        if error:
            failed.append((member.instance.display_name(), error))
        else:
            db.session.flush()  # get deployment.id
            member.deployment_id = deployment.id
            succeeded.append(member.instance.display_name())
    return succeeded, failed


@bp.route("/new", methods=["GET", "POST"])
@login_required
@load_company_context
@permission_required("manage_updates")
def new_rollout(company_id):
    company = g.company
    instances = Instance.query.filter_by(company_id=company.id).order_by(Instance.created_at.desc()).all()
    packages = UpdatePackage.query.filter_by(status="validated", withdrawn=False).order_by(
        UpdatePackage.uploaded_at.desc()
    ).all()

    if request.method == "POST":
        package = UpdatePackage.query.filter_by(public_id=request.form.get("package_id")).first()
        mode = request.form.get("mode", "now")
        batch_size_raw = request.form.get("batch_size", "").strip()
        instance_ids = request.form.getlist("instance_ids")  # order = form/checkbox order

        if package is None or not batch_size_raw.isdigit() or int(batch_size_raw) < 1 or not instance_ids:
            flash("Choose a package, a batch size of at least 1, and at least one instance.", "danger")
            return redirect(url_for("rollouts.new_rollout", company_id=company.public_id))

        batch_size = int(batch_size_raw)
        selected = [Instance.query.filter_by(public_id=pid, company_id=company.id).first() for pid in instance_ids]
        selected = [i for i in selected if i is not None]

        rollout = StagedRollout(
            company_id=company.id, package_id=package.id, batch_size=batch_size,
            mode=mode, created_by_id=current_user.id,
        )
        db.session.add(rollout)
        db.session.flush()

        for idx, instance in enumerate(selected):
            batch_number = (idx // batch_size) + 1
            db.session.add(StagedRolloutInstance(
                rollout_id=rollout.id, instance_id=instance.id, batch_number=batch_number,
            ))
        db.session.flush()

        succeeded, failed = _push_batch(rollout, 1, current_user)
        log_action(company, current_user, "staged_rollout_created",
                   f"{package.version}, {len(selected)} instances, batch size {batch_size}")
        db.session.commit()

        flash(f"Rollout created — batch 1 pushed to {len(succeeded)} instance(s).", "success")
        for name, error in failed:
            flash(f"{name}: {error}", "danger")

        return redirect(url_for("rollouts.detail", company_id=company.public_id, rollout_id=rollout.public_id))

    return render_template("rollouts/new.html", company=company, instances=instances, packages=packages)


@bp.route("/<rollout_id>")
@login_required
@load_company_context
def detail(company_id, rollout_id):
    company = g.company
    rollout = StagedRollout.query.filter_by(public_id=rollout_id, company_id=company.id).first()
    if rollout is None:
        abort(404)
    return render_template("rollouts/detail.html", company=company, rollout=rollout, role=g.company_role)


@bp.route("/<rollout_id>/advance", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_updates")
def advance(company_id, rollout_id):
    company = g.company
    rollout = StagedRollout.query.filter_by(public_id=rollout_id, company_id=company.id).first()
    if rollout is None:
        abort(404)

    if rollout.status != "in_progress":
        flash("This rollout is no longer in progress.", "warning")
        return redirect(url_for("rollouts.detail", company_id=company.public_id, rollout_id=rollout.public_id))

    next_batch = rollout.highest_pushed_batch() + 1
    if next_batch > rollout.total_batches():
        flash("There is no next batch.", "warning")
        return redirect(url_for("rollouts.detail", company_id=company.public_id, rollout_id=rollout.public_id))

    succeeded, failed = _push_batch(rollout, next_batch, current_user)

    if next_batch >= rollout.total_batches():
        rollout.status = "completed"

    log_action(company, current_user, "staged_rollout_advanced", f"batch {next_batch} of {rollout.public_id}")
    db.session.commit()

    flash(f"Batch {next_batch} pushed to {len(succeeded)} instance(s).", "success")
    for name, error in failed:
        flash(f"{name}: {error}", "danger")
    return redirect(url_for("rollouts.detail", company_id=company.public_id, rollout_id=rollout.public_id))


@bp.route("/<rollout_id>/halt", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_updates")
def halt(company_id, rollout_id):
    company = g.company
    rollout = StagedRollout.query.filter_by(public_id=rollout_id, company_id=company.id).first()
    if rollout is None:
        abort(404)
    rollout.status = "halted"
    log_action(company, current_user, "staged_rollout_halted", rollout.public_id)
    db.session.commit()
    flash("Rollout halted — no further batches will be pushed.", "info")
    return redirect(url_for("rollouts.detail", company_id=company.public_id, rollout_id=rollout.public_id))
