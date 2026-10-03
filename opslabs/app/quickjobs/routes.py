"""
Quick Jobs routes.

Admin (staff+):   /admin/jobs ...           create, view, schedule, delete
Public (no auth): /j/<token>                view details + (optionally) pick a day
"""
from datetime import datetime, date

from flask import (render_template, request, redirect, url_for, flash, abort)
from flask_login import login_required, current_user

from . import quickjobs_bp
from .. import db
from ..models_business import QuickJob, QuickJobItem, QUICKJOB_STATUS_META, Notification, AuditLog
from ..rbac import require_role, STAFF, require_admin_page, is_staff_plus
from .. import billing


def _parse_price(raw):
    raw = (raw or "").strip().replace("£", "").replace(",", "")
    if not raw:
        return None
    try:
        return int(round(float(raw) * 100))
    except ValueError:
        return None


def _parse_day(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    except ValueError:
        return None


def _parse_qty(raw, default=1):
    try:
        return max(1, min(999, int(float(raw))))
    except (TypeError, ValueError):
        return default


def _notify_admin(job, title, msg):
    if job.created_by_id:
        Notification.push(job.created_by_id, title, msg,
                          url=url_for("quickjobs.admin_detail", job_id=job.id),
                          category="job")


# ════════════════════════════════════════════════ ADMIN ════════════════════
@quickjobs_bp.route("/admin/jobs")
@require_admin_page("jobs")
def admin_list():
    status = request.args.get("status") or ""
    q = QuickJob.query
    if status in QUICKJOB_STATUS_META:
        q = q.filter_by(status=status)
    jobs = q.order_by(QuickJob.created_at.desc()).all()
    return render_template("admin/jobs/list.html", jobs=jobs,
                           status_meta=QUICKJOB_STATUS_META, status=status)


@quickjobs_bp.route("/admin/jobs/new", methods=["GET", "POST"])
@require_admin_page("jobs")
def admin_new():
    if request.method == "POST":
        title = (request.form.get("title") or "").strip()
        if not title:
            flash("Give the job a title.", "error")
            return render_template("admin/jobs/form.html", job=None)
        job = QuickJob(
            token=QuickJob.gen_token(),
            title=title,
            details=(request.form.get("details") or "").strip() or None,
            location=(request.form.get("location") or "").strip() or None,
            contact_phone=(request.form.get("contact_phone") or "").strip() or None,
            price_cents=_parse_price(request.form.get("price")),
            client_name=(request.form.get("client_name") or "").strip() or None,
            client_email=(request.form.get("client_email") or "").strip() or None,
            client_phone=(request.form.get("client_phone") or "").strip() or None,
            allow_client_scheduling=bool(request.form.get("allow_client_scheduling")),
            allow_client_edits=bool(request.form.get("allow_client_edits")),
            created_by_id=current_user.id,
        )
        # Optional admin-set day at creation
        day = _parse_day(request.form.get("scheduled_day"))
        if day:
            job.scheduled_day = day
            job.scheduled_time = (request.form.get("scheduled_time") or "").strip() or None
            job.scheduled_by = "admin"
            job.status = "scheduled"
        db.session.add(job)
        db.session.flush()
        AuditLog.log("quickjob.create", actor=current_user, target_type="quick_job",
                     target_id=job.id, ip=request.remote_addr)
        db.session.commit()
        flash("Job created — share the link below.", "success")
        return redirect(url_for("quickjobs.admin_detail", job_id=job.id))
    return render_template("admin/jobs/form.html", job=None)


@quickjobs_bp.route("/admin/jobs/<int:job_id>")
@require_admin_page("jobs")
def admin_detail(job_id):
    job = QuickJob.query.get_or_404(job_id)
    share_url = url_for("quickjobs.public_view", token=job.token, _external=True)
    return render_template("admin/jobs/detail.html", job=job, share_url=share_url,
                           status_meta=QUICKJOB_STATUS_META,
                           stripe_on=billing.is_configured())


@quickjobs_bp.route("/admin/jobs/<int:job_id>/mark-paid", methods=["POST"])
@require_admin_page("jobs")
def admin_mark_paid(job_id):
    job = QuickJob.query.get_or_404(job_id)
    paid = request.form.get("paid") == "1"
    job.is_paid = paid
    job.paid_at = datetime.utcnow() if paid else None
    job.paid_via = "manual" if paid else None
    AuditLog.log("quickjob.mark_paid" if paid else "quickjob.mark_unpaid",
                 actor=current_user, target_type="quick_job", target_id=job.id,
                 ip=request.remote_addr)
    db.session.commit()
    flash("Marked as paid." if paid else "Marked as unpaid.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/edit", methods=["POST"])
@require_admin_page("jobs")
def admin_edit(job_id):
    job = QuickJob.query.get_or_404(job_id)
    job.title = (request.form.get("title") or job.title).strip()
    job.details = (request.form.get("details") or "").strip() or None
    job.location = (request.form.get("location") or "").strip() or None
    job.contact_phone = (request.form.get("contact_phone") or "").strip() or None
    job.price_cents = _parse_price(request.form.get("price"))
    job.client_name = (request.form.get("client_name") or "").strip() or None
    job.client_email = (request.form.get("client_email") or "").strip() or None
    job.client_phone = (request.form.get("client_phone") or "").strip() or None
    job.allow_client_scheduling = bool(request.form.get("allow_client_scheduling"))
    job.allow_client_edits = bool(request.form.get("allow_client_edits"))
    db.session.commit()
    flash("Job updated.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/items/add", methods=["POST"])
@require_admin_page("jobs")
def admin_item_add(job_id):
    job = QuickJob.query.get_or_404(job_id)
    label = (request.form.get("label") or "").strip()
    unit = _parse_price(request.form.get("unit_price")) or 0
    qty = _parse_qty(request.form.get("quantity"))
    if label:
        db.session.add(QuickJobItem(job_id=job.id, label=label[:200],
                                    unit_cents=unit, quantity=qty, source="admin"))
        db.session.commit()
        flash("Item added.", "success")
    else:
        flash("Give the item a name.", "error")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/items/<int:item_id>/remove", methods=["POST"])
@require_admin_page("jobs")
def admin_item_remove(job_id, item_id):
    job = QuickJob.query.get_or_404(job_id)
    item = QuickJobItem.query.filter_by(id=item_id, job_id=job.id).first_or_404()
    db.session.delete(item)
    db.session.commit()
    flash("Item removed.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/schedule", methods=["POST"])
@require_admin_page("jobs")
def admin_schedule(job_id):
    job = QuickJob.query.get_or_404(job_id)
    day = _parse_day(request.form.get("scheduled_day"))
    if day:
        job.scheduled_day = day
        job.scheduled_time = (request.form.get("scheduled_time") or "").strip() or None
        job.scheduled_by = "admin"
        if job.status == "new":
            job.status = "scheduled"
    else:
        # clearing the day reopens it
        job.scheduled_day = None
        job.scheduled_time = None
        job.scheduled_by = None
        if job.status == "scheduled":
            job.status = "new"
    AuditLog.log("quickjob.schedule", actor=current_user, target_type="quick_job",
                 target_id=job.id, meta={"day": str(job.scheduled_day)}, ip=request.remote_addr)
    db.session.commit()
    flash("Schedule updated.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/status", methods=["POST"])
@require_admin_page("jobs")
def admin_status(job_id):
    job = QuickJob.query.get_or_404(job_id)
    new = request.form.get("status")
    if new in QUICKJOB_STATUS_META:
        job.status = new
        db.session.commit()
        flash(f"Marked {QUICKJOB_STATUS_META[new]['label'].lower()}.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/regen-link", methods=["POST"])
@require_admin_page("jobs")
def admin_regen(job_id):
    job = QuickJob.query.get_or_404(job_id)
    job.token = QuickJob.gen_token()
    db.session.commit()
    flash("Share link regenerated — the old link no longer works.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/delete", methods=["POST"])
@require_admin_page("jobs")
def admin_delete(job_id):
    job = QuickJob.query.get_or_404(job_id)
    db.session.delete(job)
    AuditLog.log("quickjob.delete", actor=current_user, target_type="quick_job",
                 target_id=job_id, ip=request.remote_addr)
    db.session.commit()
    flash("Job deleted.", "success")
    return redirect(url_for("quickjobs.admin_list"))


# ════════════════════════════════════════════════ PUBLIC ═══════════════════
@quickjobs_bp.route("/j/<token>")
def public_view(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    return render_template("public/job.html", job=job, today=date.today().isoformat(),
                           stripe_on=billing.is_configured())


@quickjobs_bp.route("/j/<token>/pay", methods=["POST"])
def public_pay(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    if not job.is_payable_online:
        flash("This job isn't payable.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    success = url_for("quickjobs.public_view", token=token, paid=1, _external=True)
    cancel = url_for("quickjobs.public_view", token=token, _external=True)
    session, err = billing.create_checkout_for_quickjob(job, success, cancel)
    if err:
        flash(err, "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    return redirect(session.url, code=303)


@quickjobs_bp.route("/j/<token>/schedule", methods=["POST"])
def public_schedule(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    if not job.is_open_for_scheduling:
        flash("This job can't be scheduled here.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    day = _parse_day(request.form.get("scheduled_day"))
    if not day or day < date.today():
        flash("Please choose a valid date (today or later).", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    job.scheduled_day = day
    job.scheduled_time = (request.form.get("scheduled_time") or "").strip() or None
    job.scheduled_by = "client"
    job.status = "scheduled"
    # let the admin who created it know
    if job.created_by_id:
        when = job.scheduled_day.strftime("%d %b %Y") + (f" {job.scheduled_time}" if job.scheduled_time else "")
        Notification.push(job.created_by_id, "Job scheduled by client",
                          f"“{job.title}” booked for {when}.",
                          url=url_for("quickjobs.admin_detail", job_id=job.id),
                          category="job")
    AuditLog.log("quickjob.client_schedule", target_type="quick_job", target_id=job.id,
                 meta={"day": str(day)}, ip=request.remote_addr)
    db.session.commit()
    return redirect(url_for("quickjobs.public_view", token=token))


def _client_guard(job):
    """Returns a redirect response if the client may not edit, else None."""
    if not job.client_can_edit:
        flash("This job can no longer be changed online.", "error")
        return redirect(url_for("quickjobs.public_view", token=job.token))
    return None


@quickjobs_bp.route("/j/<token>/items/add", methods=["POST"])
def public_item_add(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    label = (request.form.get("label") or "").strip()
    unit = _parse_price(request.form.get("unit_price")) or 0
    qty = _parse_qty(request.form.get("quantity"))
    if not label:
        flash("Give the item a name.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    db.session.add(QuickJobItem(job_id=job.id, label=label[:200],
                                unit_cents=unit, quantity=qty, source="client"))
    _notify_admin(job, "Client added an item", f"“{label}” added to “{job.title}”.")
    AuditLog.log("quickjob.client_item_add", target_type="quick_job", target_id=job.id,
                 meta={"label": label}, ip=request.remote_addr)
    db.session.commit()
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/items/<int:item_id>/remove", methods=["POST"])
def public_item_remove(token, item_id):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    item = QuickJobItem.query.filter_by(id=item_id, job_id=job.id).first_or_404()
    db.session.delete(item)
    db.session.commit()
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/items/<int:item_id>/qty", methods=["POST"])
def public_item_qty(token, item_id):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    item = QuickJobItem.query.filter_by(id=item_id, job_id=job.id).first_or_404()
    action = request.form.get("action")
    if action == "inc":
        item.quantity = min(999, (item.quantity or 1) + 1)
    elif action == "dec":
        item.quantity = max(1, (item.quantity or 1) - 1)
    else:
        item.quantity = _parse_qty(request.form.get("quantity"), item.quantity or 1)
    db.session.commit()
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/details", methods=["POST"])
def public_details(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    job.client_name = (request.form.get("client_name") or "").strip() or None
    job.client_email = (request.form.get("client_email") or "").strip() or None
    job.client_phone = (request.form.get("client_phone") or "").strip() or None
    job.location = (request.form.get("location") or "").strip() or None
    _notify_admin(job, "Client updated their details", f"Contact/address changed on “{job.title}”.")
    AuditLog.log("quickjob.client_details", target_type="quick_job", target_id=job.id,
                 ip=request.remote_addr)
    db.session.commit()
    flash("Your details were saved.", "success")
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/reschedule", methods=["POST"])
def public_reschedule(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    day = _parse_day(request.form.get("scheduled_day"))
    if not day or day < date.today():
        flash("Please choose a valid date (today or later).", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    job.scheduled_day = day
    job.scheduled_time = (request.form.get("scheduled_time") or "").strip() or None
    job.scheduled_by = "client"
    if job.status == "new":
        job.status = "scheduled"
    when = day.strftime("%d %b %Y") + (f" {job.scheduled_time}" if job.scheduled_time else "")
    _notify_admin(job, "Client rescheduled", f"“{job.title}” now set for {when}.")
    AuditLog.log("quickjob.client_reschedule", target_type="quick_job", target_id=job.id,
                 meta={"day": str(day)}, ip=request.remote_addr)
    db.session.commit()
    flash("Your day was updated.", "success")
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/cancel", methods=["POST"])
def public_cancel(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    if job.is_paid:
        flash("This job is already paid — please contact us to cancel.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    if job.status == "cancelled":
        return redirect(url_for("quickjobs.public_view", token=token))
    if not job.allow_client_edits:
        flash("This job can't be cancelled online.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    job.status = "cancelled"
    _notify_admin(job, "Client cancelled a job", f"“{job.title}” was cancelled by the client.")
    AuditLog.log("quickjob.client_cancel", target_type="quick_job", target_id=job.id,
                 ip=request.remote_addr)
    db.session.commit()
    flash("This job has been cancelled.", "success")
    return redirect(url_for("quickjobs.public_view", token=token))
