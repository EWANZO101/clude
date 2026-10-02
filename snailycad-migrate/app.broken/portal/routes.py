"""
Portal routes — customer-facing, with staff overrides via RBAC.
Times stored UTC; displayed Europe/London in 24h (see to_local / fmt).
"""
from datetime import datetime, timedelta, time, date
from zoneinfo import ZoneInfo

from flask import (render_template, request, redirect, url_for, flash,
                   abort, jsonify)
from flask_login import login_required, current_user

from . import portal_bp
from .. import db
from ..models import Ticket, Company, User, normalise_status
from ..models_business import (
    Service, Project, ProjectMilestone, ProjectEvent, PROJECT_STAGES,
    PROJECT_STAGE_META, Appointment, WorkingHours, BlackoutDate,
    Invoice, InvoiceLineItem, Payment, Notification, Announcement, AuditLog,
)
from ..rbac import require_permission, has_permission, is_staff_plus, STAFF
from .. import billing

LONDON = ZoneInfo("Europe/London")
UTC = ZoneInfo("UTC")
OPEN_TICKET = ("seen", "pending", "in_progress", "open")


# ───────────────────────────── tz / format helpers ─────────────────────────
def to_local(dt):
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(LONDON)


def fmt(dt, with_time=True):
    loc = to_local(dt)
    if not loc:
        return "—"
    return loc.strftime("%d %b %Y · %H:%M") if with_time else loc.strftime("%d %b %Y")


def local_to_utc(d: date, hhmm: str):
    """'14:30' on a date (London) → naive UTC datetime for storage."""
    h, m = (int(x) for x in hhmm.split(":"))
    local_dt = datetime(d.year, d.month, d.day, h, m, tzinfo=LONDON)
    return local_dt.astimezone(UTC).replace(tzinfo=None)


@portal_bp.app_template_filter("dt")
def _jinja_dt(value):
    return fmt(value)


@portal_bp.app_template_filter("dtdate")
def _jinja_dtdate(value):
    return fmt(value, with_time=False)


# Inject portal-wide context (unread notifications, announcements)
@portal_bp.app_context_processor
def _portal_ctx():
    if not current_user.is_authenticated:
        return {}
    return dict(
        portal_unread=Notification.unread_count(current_user.id),
        portal_announcements=Announcement.active(),
        portal_is_staff=is_staff_plus(current_user),
        can=has_permission,  # use {{ can(current_user, 'invoice.manage') }}
    )


def _owned_or_staff(query, owner_col):
    """Limit a query to the current user's rows unless they're staff+."""
    if is_staff_plus(current_user):
        return query
    return query.filter(owner_col == current_user.id)


# ════════════════════════════════════ DASHBOARD ════════════════════════════
@portal_bp.route("/")
@login_required
def dashboard():
    uid = current_user.id

    svc_counts = {s: Service.query.filter_by(owner_id=uid, status=s).count()
                  for s in ("active", "pending", "suspended", "expired")}

    proj_q = Project.query.filter_by(owner_id=uid)
    proj_counts = {
        "active": proj_q.filter(~Project.stage.in_(["completed"])).count(),
        "completed": proj_q.filter_by(stage="completed").count(),
    }
    recent_projects = (Project.query.filter_by(owner_id=uid)
                       .order_by(Project.updated_at.desc()).limit(5).all())

    outstanding = (Invoice.query.filter_by(owner_id=uid)
                   .filter(Invoice.status.in_(["sent", "overdue"])).all())
    outstanding_total = sum(i.total_cents for i in outstanding)
    recent_payments = (Payment.query.filter_by(owner_id=uid)
                       .order_by(Payment.created_at.desc()).limit(5).all())

    upcoming_appts = (Appointment.query.filter_by(owner_id=uid)
                      .filter(Appointment.starts_at >= datetime.utcnow(),
                              Appointment.status.in_(["requested", "confirmed", "rescheduled"]))
                      .order_by(Appointment.starts_at.asc()).limit(5).all())

    open_tickets = (Ticket.query.filter_by(user_id=uid)
                    .filter(Ticket.status.in_(OPEN_TICKET)).count())

    return render_template("portal/dashboard.html",
        svc_counts=svc_counts, proj_counts=proj_counts,
        recent_projects=recent_projects, outstanding=outstanding,
        outstanding_total=outstanding_total, recent_payments=recent_payments,
        upcoming_appts=upcoming_appts, open_tickets=open_tickets)


# ════════════════════════════════════ PROJECTS ═════════════════════════════
@portal_bp.route("/projects")
@login_required
def projects():
    q = _owned_or_staff(Project.query, Project.owner_id)
    items = q.order_by(Project.updated_at.desc()).all()
    return render_template("portal/projects.html", projects=items, stage_meta=PROJECT_STAGE_META)


@portal_bp.route("/projects/new", methods=["GET", "POST"])
@login_required
def project_new():
    companies = Company.query.filter_by(is_active=True).all()
    if request.method == "POST":
        title = (request.form.get("title") or "").strip()
        if not title:
            flash("Give your project a title.", "error")
            return render_template("portal/project_new.html", companies=companies)
        p = Project(
            owner_id=current_user.id,
            company_id=(request.form.get("company_id") or None),
            title=title,
            summary=(request.form.get("summary") or "").strip() or None,
            requirements=(request.form.get("requirements") or "").strip() or None,
            stage="submitted",
        )
        db.session.add(p)
        db.session.flush()
        p.log_event("created", "Project submitted.", actor=current_user)
        Notification.push(current_user.id, "Project submitted",
                          f"“{p.title}” is now in the queue.",
                          url=f"/portal/projects/{p.id}", category="project")
        AuditLog.log("project.create", actor=current_user, target_type="project",
                     target_id=p.id, ip=request.remote_addr)
        db.session.commit()
        flash("Project submitted.", "success")
        return redirect(url_for("portal.project_detail", pid=p.id))
    return render_template("portal/project_new.html", companies=companies)


@portal_bp.route("/projects/<int:pid>")
@login_required
def project_detail(pid):
    p = Project.query.get_or_404(pid)
    if p.owner_id != current_user.id and not is_staff_plus(current_user):
        abort(403)
    staff = User.query.filter(User.role.in_(["staff", "admin", "super_admin", "support"])).all() \
        if is_staff_plus(current_user) else []
    return render_template("portal/project_detail.html", p=p,
                           stages=PROJECT_STAGES, stage_meta=PROJECT_STAGE_META,
                           events=p.events.all(), milestones=p.milestones.all(),
                           staff=staff)


@portal_bp.route("/projects/<int:pid>/update", methods=["POST"])
@require_permission("project.manage")
def project_update(pid):
    p = Project.query.get_or_404(pid)
    new_stage = request.form.get("stage")
    pct = request.form.get("percent_complete")
    note = (request.form.get("note") or "").strip()

    if new_stage and new_stage in PROJECT_STAGES and new_stage != p.stage:
        p.stage = new_stage
        p.percent_complete = PROJECT_STAGE_META[new_stage].get("pct", p.percent_complete)
        p.log_event("stage_change", f"Stage → {PROJECT_STAGE_META[new_stage]['label']}",
                    actor=current_user)
    if pct:
        try:
            p.percent_complete = max(0, min(100, int(pct)))
        except ValueError:
            pass
    sid = request.form.get("assigned_staff_id")
    if sid is not None:
        p.assigned_staff_id = int(sid) if sid else None
    est = request.form.get("estimated_completion")
    if est:
        try:
            p.estimated_completion = datetime.strptime(est, "%Y-%m-%d")
        except ValueError:
            pass
    if note:
        p.log_event("staff_update", note, actor=current_user)

    Notification.push(p.owner_id, "Project updated",
                      f"“{p.title}” — {p.stage_meta['label']} ({p.effective_percent}%).",
                      url=f"/portal/projects/{p.id}", category="project")
    AuditLog.log("project.update", actor=current_user, target_type="project",
                 target_id=p.id, meta={"stage": p.stage}, ip=request.remote_addr)
    db.session.commit()
    flash("Project updated.", "success")
    return redirect(url_for("portal.project_detail", pid=p.id))


@portal_bp.route("/projects/<int:pid>/comment", methods=["POST"])
@login_required
def project_comment(pid):
    p = Project.query.get_or_404(pid)
    if p.owner_id != current_user.id and not is_staff_plus(current_user):
        abort(403)
    text = (request.form.get("text") or "").strip()
    if text:
        kind = "staff_update" if is_staff_plus(current_user) else "client_update"
        p.log_event(kind, text, actor=current_user)
        # notify the other party
        notify_uid = p.owner_id if is_staff_plus(current_user) else (p.assigned_staff_id or p.owner_id)
        if notify_uid and notify_uid != current_user.id:
            Notification.push(notify_uid, "New project comment",
                              text[:120], url=f"/portal/projects/{p.id}", category="project")
        db.session.commit()
        flash("Comment added.", "success")
    return redirect(url_for("portal.project_detail", pid=p.id))


# ═════════════════════════════════ APPOINTMENTS ════════════════════════════
def _working_hours_map():
    rows = WorkingHours.query.all()
    if not rows:  # sensible default Mon–Fri 09:00–17:00
        return {wd: ("09:00", "17:00") for wd in range(5)}
    return {r.weekday: (r.start_time, r.end_time) for r in rows if r.is_open}


def _slots_for(day: date, duration_min=30):
    """Return list of free 'HH:MM' start slots for a London date."""
    wh = _working_hours_map().get(day.weekday())
    if not wh:
        return []
    if BlackoutDate.query.filter_by(day=day).first():
        return []
    start_h, start_m = (int(x) for x in wh[0].split(":"))
    end_h, end_m = (int(x) for x in wh[1].split(":"))
    cursor = datetime.combine(day, time(start_h, start_m))
    end = datetime.combine(day, time(end_h, end_m))
    out = []
    step = timedelta(minutes=duration_min)
    now_local = datetime.now(LONDON).replace(tzinfo=None)
    while cursor + step <= end:
        s_utc = local_to_utc(day, cursor.strftime("%H:%M"))
        e_utc = s_utc + step
        if cursor > now_local and not Appointment.has_conflict(s_utc, e_utc):
            out.append(cursor.strftime("%H:%M"))
        cursor += step
    return out


@portal_bp.route("/appointments")
@login_required
def appointments():
    q = _owned_or_staff(Appointment.query, Appointment.owner_id)
    upcoming = q.filter(Appointment.starts_at >= datetime.utcnow()) \
        .order_by(Appointment.starts_at.asc()).all()
    past = q.filter(Appointment.starts_at < datetime.utcnow()) \
        .order_by(Appointment.starts_at.desc()).limit(20).all()
    return render_template("portal/appointments.html", upcoming=upcoming, past=past)


@portal_bp.route("/appointments/book", methods=["GET", "POST"])
@login_required
def appointment_book():
    if request.method == "POST":
        subject = (request.form.get("subject") or "").strip()
        day_str = request.form.get("day")
        hhmm = request.form.get("slot")
        dur = int(request.form.get("duration") or 30)
        if not (subject and day_str and hhmm):
            flash("Pick a subject, date and time.", "error")
            return redirect(url_for("portal.appointment_book"))
        try:
            day = datetime.strptime(day_str, "%Y-%m-%d").date()
        except ValueError:
            flash("Invalid date.", "error")
            return redirect(url_for("portal.appointment_book"))
        s_utc = local_to_utc(day, hhmm)
        e_utc = s_utc + timedelta(minutes=dur)
        if Appointment.has_conflict(s_utc, e_utc):
            flash("That slot was just taken — please pick another.", "error")
            return redirect(url_for("portal.appointment_book", day=day_str))
        appt = Appointment(owner_id=current_user.id, subject=subject,
                           notes=(request.form.get("notes") or "").strip() or None,
                           starts_at=s_utc, ends_at=e_utc, status="requested")
        db.session.add(appt)
        db.session.flush()
        Notification.push(current_user.id, "Appointment requested",
                          f"{subject} — {fmt(s_utc)}",
                          url="/portal/appointments", category="appointment")
        AuditLog.log("appointment.create", actor=current_user, target_type="appointment",
                     target_id=appt.id, ip=request.remote_addr)
        db.session.commit()
        flash("Appointment requested.", "success")
        return redirect(url_for("portal.appointments"))

    # GET — show booking form for a chosen day (default: next open day)
    day_str = request.args.get("day")
    if day_str:
        try:
            day = datetime.strptime(day_str, "%Y-%m-%d").date()
        except ValueError:
            day = date.today()
    else:
        day = date.today()
    slots = _slots_for(day)
    return render_template("portal/appointment_book.html",
                           day=day, day_str=day.strftime("%Y-%m-%d"), slots=slots)


@portal_bp.route("/appointments/<int:aid>/cancel", methods=["POST"])
@login_required
def appointment_cancel(aid):
    appt = Appointment.query.get_or_404(aid)
    if appt.owner_id != current_user.id and not is_staff_plus(current_user):
        abort(403)
    appt.status = "cancelled"
    AuditLog.log("appointment.cancel", actor=current_user, target_type="appointment",
                 target_id=appt.id, ip=request.remote_addr)
    db.session.commit()
    flash("Appointment cancelled.", "success")
    return redirect(url_for("portal.appointments"))


# ════════════════════════════════════ INVOICES ═════════════════════════════
@portal_bp.route("/invoices")
@login_required
def invoices():
    q = _owned_or_staff(Invoice.query, Invoice.owner_id)
    items = q.order_by(Invoice.created_at.desc()).all()
    return render_template("portal/invoices.html", invoices=items)


@portal_bp.route("/invoices/<int:iid>")
@login_required
def invoice_detail(iid):
    inv = Invoice.query.get_or_404(iid)
    if inv.owner_id != current_user.id and not is_staff_plus(current_user):
        abort(403)
    return render_template("portal/invoice_detail.html", inv=inv,
                           stripe_pk=billing.publishable_key(),
                           stripe_on=billing.is_configured())


@portal_bp.route("/invoices/<int:iid>/pay", methods=["POST"])
@login_required
def invoice_pay(iid):
    inv = Invoice.query.get_or_404(iid)
    if inv.owner_id != current_user.id:
        abort(403)
    if not inv.is_payable:
        flash("This invoice isn't payable.", "warning")
        return redirect(url_for("portal.invoice_detail", iid=inv.id))
    success = url_for("portal.invoice_detail", iid=inv.id, paid=1, _external=True)
    cancel = url_for("portal.invoice_detail", iid=inv.id, _external=True)
    session, err = billing.create_checkout_session(inv, success, cancel)
    if err:
        flash(err, "error")
        return redirect(url_for("portal.invoice_detail", iid=inv.id))
    return redirect(session.url, code=303)


# ═════════════════════════════════ NOTIFICATIONS ═══════════════════════════
@portal_bp.route("/notifications")
@login_required
def notifications():
    items = (Notification.query.filter_by(user_id=current_user.id)
             .order_by(Notification.created_at.desc()).limit(100).all())
    return render_template("portal/notifications.html", items=items)


@portal_bp.route("/notifications/read-all", methods=["POST"])
@login_required
def notifications_read_all():
    Notification.query.filter_by(user_id=current_user.id, is_read=False) \
        .update({"is_read": True})
    db.session.commit()
    if request.headers.get("X-Requested-With") == "fetch":
        return jsonify(ok=True)
    return redirect(url_for("portal.notifications"))
