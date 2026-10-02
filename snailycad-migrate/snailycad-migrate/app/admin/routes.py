import os
import shutil
from datetime import datetime, timedelta

from flask import Blueprint, render_template, redirect, url_for, flash, request, current_app
from flask_login import current_user
from itsdangerous import URLSafeTimedSerializer

from app.extensions import db
from app.models import (
    User, Export, ExportStatus, ImportJob, AuditLog, Setting, Role, ExportShareLink,
    RetentionExtensionRequest, ExtensionRequestStatus,
    SupportTicket, TicketMessage, TicketStatus, TicketPriority,
)
from app.support.forms import AdminNewTicketForm, ReplyForm
from app.admin.decorators import admin_required
from app.admin.forms import EditUserForm, SystemSettingsForm
from app.email import send_email
from app.auth.routes import log_action

admin_bp = Blueprint("admin", __name__, url_prefix="/admin")


@admin_bp.before_request
@admin_required
def _guard():
    """Applies admin_required (which also implies auth) to every route in this blueprint."""
    pass


def _dir_size_bytes(path):
    total = 0
    if not os.path.isdir(path):
        return 0
    for root, _dirs, files in os.walk(path):
        for fname in files:
            try:
                total += os.path.getsize(os.path.join(root, fname))
            except OSError:
                continue
    return total


@admin_bp.route("/")
def overview():
    user_count = User.query.count()
    active_temp = User.query.filter_by(is_temporary=True).count()
    export_count = Export.query.count()
    running_exports = Export.query.filter_by(status=ExportStatus.RUNNING).count()
    import_count = ImportJob.query.count()

    since = datetime.utcnow() - timedelta(hours=24)
    active_sessions = User.query.filter(User.last_login_at >= since).count()

    exports_dir = current_app.config["EXPORTS_DIR"]
    exports_size = _dir_size_bytes(exports_dir)

    try:
        disk_total, disk_used, disk_free = shutil.disk_usage(exports_dir)
    except OSError:
        disk_total = disk_used = disk_free = 0

    recent_logs = AuditLog.query.order_by(AuditLog.created_at.desc()).limit(15).all()

    return render_template(
        "admin/overview.html",
        user_count=user_count,
        active_temp=active_temp,
        export_count=export_count,
        running_exports=running_exports,
        import_count=import_count,
        active_sessions=active_sessions,
        exports_size=exports_size,
        disk_total=disk_total,
        disk_used=disk_used,
        disk_free=disk_free,
        recent_logs=recent_logs,
    )


# ---- User management --------------------------------------------------

@admin_bp.route("/users")
def users():
    q = request.args.get("q", "").strip()
    query = User.query
    if q:
        query = query.filter(User.email.ilike(f"%{q}%"))
    user_list = query.order_by(User.created_at.desc()).limit(200).all()
    return render_template("admin/users.html", users=user_list, q=q)


@admin_bp.route("/users/<user_id>", methods=["GET", "POST"])
def user_detail(user_id):
    user = User.query.get_or_404(user_id)
    form = EditUserForm(obj=user)

    if form.validate_on_submit():
        if user.id == current_user.id and form.role.data != Role.ADMIN:
            flash("You can't demote your own account.", "warning")
            return redirect(url_for("admin.user_detail", user_id=user_id))

        user.role = form.role.data
        user.is_suspended = form.is_suspended.data
        db.session.commit()
        log_action(current_user.id, "admin_user_updated", detail=user_id)
        flash("User updated.", "success")
        return redirect(url_for("admin.user_detail", user_id=user_id))

    exports = user.exports.order_by(Export.created_at.desc()).limit(20).all()
    extension_requests = RetentionExtensionRequest.query.filter_by(user_id=user.id).order_by(
        RetentionExtensionRequest.created_at.desc()
    ).limit(10).all()
    tickets = SupportTicket.query.filter_by(user_id=user.id).order_by(
        SupportTicket.updated_at.desc()
    ).limit(10).all()
    share_links = ExportShareLink.query.filter_by(created_by=user.id).order_by(
        ExportShareLink.created_at.desc()
    ).limit(10).all()
    recent_activity = AuditLog.query.filter_by(user_id=user.id).order_by(
        AuditLog.created_at.desc()
    ).limit(20).all()

    return render_template(
        "admin/user_detail.html", user=user, form=form, exports=exports,
        extension_requests=extension_requests, tickets=tickets,
        share_links=share_links, recent_activity=recent_activity,
    )


@admin_bp.route("/users/<user_id>/force-logout", methods=["POST"])
def force_logout(user_id):
    user = User.query.get_or_404(user_id)
    user.force_logout_at = datetime.utcnow()
    db.session.commit()
    log_action(current_user.id, "admin_force_logout", detail=user_id)
    flash(f"All sessions for {user.email} will be invalidated.", "info")
    return redirect(url_for("admin.user_detail", user_id=user_id))


@admin_bp.route("/users/<user_id>/reset-link", methods=["POST"])
def generate_reset_link(user_id):
    user = User.query.get_or_404(user_id)
    serializer = URLSafeTimedSerializer(current_app.config["SECRET_KEY"])
    token = serializer.dumps(user.email, salt="password-reset")
    reset_url = url_for("auth.reset_password", token=token, _external=True)

    sent = send_email(
        to=user.email,
        subject="Reset your SnailyCAD Migration Platform password",
        body_text=(
            f"An administrator generated a password reset link for this account.\n\n"
            f"Reset it here: {reset_url}\n\n"
            f"This link expires in 1 hour."
        ),
    )

    log_action(current_user.id, "admin_reset_link_generated", detail=user_id)
    if sent:
        flash(f"Reset email sent to {user.email}. Link (for support use): {reset_url}", "info")
    else:
        flash(f"Mail isn't configured — send this link to {user.email} directly: {reset_url}", "warning")
    return redirect(url_for("admin.user_detail", user_id=user_id))


@admin_bp.route("/users/<user_id>/delete", methods=["POST"])
def delete_user(user_id):
    user = User.query.get_or_404(user_id)
    if user.id == current_user.id:
        flash("You can't delete your own account.", "danger")
        return redirect(url_for("admin.user_detail", user_id=user_id))

    for export in user.exports.all():
        if export.file_path and os.path.exists(export.file_path):
            os.remove(export.file_path)

    db.session.delete(user)
    db.session.commit()
    log_action(current_user.id, "admin_user_deleted", detail=user_id)
    flash("User deleted.", "info")
    return redirect(url_for("admin.users"))


# ---- Export management --------------------------------------------------

@admin_bp.route("/exports")
def exports():
    status_filter = request.args.get("status", "")
    query = Export.query
    if status_filter:
        query = query.filter_by(status=status_filter)
    export_list = query.order_by(Export.created_at.desc()).limit(200).all()
    return render_template("admin/exports.html", exports=export_list, status_filter=status_filter,
                            statuses=[ExportStatus.PENDING, ExportStatus.RUNNING,
                                      ExportStatus.COMPLETE, ExportStatus.FAILED, ExportStatus.EXPIRED])


@admin_bp.route("/exports/<export_id>/delete", methods=["POST"])
def delete_export(export_id):
    export = Export.query.get_or_404(export_id)
    if export.file_path and os.path.exists(export.file_path):
        os.remove(export.file_path)
    sidecar = f"{export.file_path}.sha256" if export.file_path else None
    if sidecar and os.path.exists(sidecar):
        os.remove(sidecar)
    db.session.delete(export)
    db.session.commit()
    log_action(current_user.id, "admin_export_deleted", detail=export_id)
    flash("Export deleted.", "info")
    return redirect(url_for("admin.exports"))


@admin_bp.route("/exports/<export_id>/set-retention", methods=["POST"])
def set_export_retention(export_id):
    export = Export.query.get_or_404(export_id)
    raw = request.form.get("retention_override_days", "").strip()

    if not raw:
        export.retention_override_days = None
        flash("Retention override cleared — back to standard/approved-request rules.", "info")
    else:
        try:
            days = int(raw)
            if days < 1:
                raise ValueError
        except ValueError:
            flash("Enter a whole number of days (1 or more).", "danger")
            return redirect(url_for("admin.exports"))
        export.retention_override_days = days
        flash(f"Retention for this export set to {days} days, effective immediately.", "success")

    db.session.commit()
    log_action(current_user.id, "admin_retention_override_set", detail=f"{export_id} -> {raw or 'cleared'}")
    return redirect(url_for("admin.exports"))


@admin_bp.route("/exports/cleanup-expired", methods=["POST"])
def cleanup_expired_exports():
    standard_days = int(Setting.get("export_retention_days", "7"))
    candidates = Export.query.filter(Export.status == ExportStatus.COMPLETE).all()

    removed = 0
    now = datetime.utcnow()
    for export in candidates:
        effective_days = export.effective_retention_days(standard_days)
        if now - export.created_at < timedelta(days=effective_days):
            continue
        if export.file_path and os.path.exists(export.file_path):
            os.remove(export.file_path)
        export.status = ExportStatus.EXPIRED
        removed += 1
    db.session.commit()
    log_action(current_user.id, "admin_cleanup_expired", detail=f"{removed} export(s)")
    flash(f"Marked {removed} export(s) expired and removed their files "
          f"(standard {standard_days} days, longer where an extension was approved).", "success")
    return redirect(url_for("admin.exports"))


# ---- Import management --------------------------------------------------

@admin_bp.route("/imports")
def imports():
    import_list = ImportJob.query.order_by(ImportJob.created_at.desc()).limit(200).all()
    return render_template("admin/imports.html", imports=import_list)


# ---- Audit log --------------------------------------------------------

@admin_bp.route("/audit-logs")
def audit_logs():
    page = request.args.get("page", 1, type=int)
    pagination = AuditLog.query.order_by(AuditLog.created_at.desc()).paginate(
        page=page, per_page=50, error_out=False
    )
    return render_template("admin/audit_logs.html", pagination=pagination)


# ---- Settings --------------------------------------------------------

@admin_bp.route("/settings", methods=["GET", "POST"])
def settings():
    form = SystemSettingsForm()

    if form.validate_on_submit():
        Setting.set("export_retention_days", str(form.export_retention_days.data))
        Setting.set("temp_account_lifetime_hours", str(form.temp_account_lifetime_hours.data))
        Setting.set("cleanup_enabled", "true" if form.cleanup_enabled.data else "false")
        Setting.set("mail_server", form.mail_server.data or "")
        Setting.set("mail_from", form.mail_from.data or "")
        log_action(current_user.id, "admin_settings_updated")
        flash("Settings saved.", "success")
        return redirect(url_for("admin.settings"))

    if request.method == "GET":
        form.export_retention_days.data = int(Setting.get("export_retention_days", "7"))
        form.temp_account_lifetime_hours.data = int(Setting.get("temp_account_lifetime_hours", "12"))
        form.cleanup_enabled.data = Setting.get("cleanup_enabled", "true") == "true"
        form.mail_server.data = Setting.get("mail_server", "")
        form.mail_from.data = Setting.get("mail_from", "")

    return render_template("admin/settings.html", form=form)


# ---- Share link approval --------------------------------------------------

@admin_bp.route("/share-links")
def share_links():
    pending = ExportShareLink.query.filter_by(
        needs_approval=True, approved=False, revoked=False
    ).order_by(ExportShareLink.created_at.desc()).all()
    all_links = ExportShareLink.query.order_by(ExportShareLink.created_at.desc()).limit(200).all()
    return render_template("admin/share_links.html", pending=pending, all_links=all_links)


@admin_bp.route("/share-links/<link_id>/approve", methods=["POST"])
def approve_share_link(link_id):
    link = ExportShareLink.query.get_or_404(link_id)
    link.approved = True
    link.approved_by = current_user.id
    link.approved_at = datetime.utcnow()
    db.session.commit()
    log_action(current_user.id, "admin_share_link_approved", detail=link_id)
    flash("Share link approved — it's now active.", "success")
    return redirect(url_for("admin.share_links"))


@admin_bp.route("/share-links/<link_id>/deny", methods=["POST"])
def deny_share_link(link_id):
    link = ExportShareLink.query.get_or_404(link_id)
    link.revoked = True
    db.session.commit()
    log_action(current_user.id, "admin_share_link_denied", detail=link_id)
    flash("Share link request denied.", "info")
    return redirect(url_for("admin.share_links"))


# ---- Retention extension requests -----------------------------------------

@admin_bp.route("/extension-requests")
def extension_requests():
    pending = RetentionExtensionRequest.query.filter_by(
        status=ExtensionRequestStatus.PENDING
    ).order_by(RetentionExtensionRequest.created_at.desc()).all()
    all_requests = RetentionExtensionRequest.query.order_by(
        RetentionExtensionRequest.created_at.desc()
    ).limit(200).all()
    return render_template("admin/extension_requests.html", pending=pending, all_requests=all_requests)


@admin_bp.route("/extension-requests/<request_id>/approve", methods=["POST"])
def approve_extension_request(request_id):
    req = RetentionExtensionRequest.query.get_or_404(request_id)
    req.status = ExtensionRequestStatus.APPROVED
    req.reviewed_by = current_user.id
    req.reviewed_at = datetime.utcnow()
    req.admin_notes = request.form.get("admin_notes", "").strip() or None
    db.session.commit()
    log_action(current_user.id, "admin_extension_approved", detail=request_id)
    flash(f"Extension approved — export retained for {req.requested_days} days.", "success")
    return redirect(url_for("admin.extension_requests"))


@admin_bp.route("/extension-requests/<request_id>/decline", methods=["POST"])
def decline_extension_request(request_id):
    req = RetentionExtensionRequest.query.get_or_404(request_id)
    req.status = ExtensionRequestStatus.DECLINED
    req.reviewed_by = current_user.id
    req.reviewed_at = datetime.utcnow()
    req.admin_notes = request.form.get("admin_notes", "").strip() or None
    db.session.commit()
    log_action(current_user.id, "admin_extension_declined", detail=request_id)
    flash("Extension request declined.", "info")
    return redirect(url_for("admin.extension_requests"))


# ---- Support tickets --------------------------------------------------

@admin_bp.route("/support")
def support_tickets():
    status_filter = request.args.get("status", "")
    assigned_filter = request.args.get("assigned", "")

    query = SupportTicket.query
    if status_filter:
        query = query.filter_by(status=status_filter)
    if assigned_filter == "me":
        query = query.filter_by(assigned_to=current_user.id)
    elif assigned_filter == "unassigned":
        query = query.filter(SupportTicket.assigned_to.is_(None))

    tickets = query.order_by(SupportTicket.updated_at.desc()).limit(200).all()
    return render_template(
        "admin/support_list.html", tickets=tickets,
        status_filter=status_filter, assigned_filter=assigned_filter,
        statuses=[TicketStatus.OPEN, TicketStatus.PENDING_USER, TicketStatus.PENDING_SUPPORT,
                  TicketStatus.RESOLVED, TicketStatus.CLOSED],
    )


@admin_bp.route("/support/new", methods=["GET", "POST"])
def support_new_for_user():
    form = AdminNewTicketForm()
    if form.validate_on_submit():
        target_user = User.query.filter_by(email=form.user_email.data.lower()).first()
        if not target_user:
            flash(f"No user found with email {form.user_email.data}.", "danger")
            return render_template("admin/support_new.html", form=form)

        ticket = SupportTicket(
            user_id=target_user.id, subject=form.subject.data,
            created_by_admin=current_user.id, assigned_to=current_user.id,
        )
        db.session.add(ticket)
        db.session.flush()
        message = TicketMessage(
            ticket_id=ticket.id, sender_id=current_user.id,
            is_staff_reply=True, body=form.message.data,
        )
        db.session.add(message)
        db.session.commit()
        log_action(current_user.id, "admin_ticket_opened_for_user", detail=f"{ticket.id} ({target_user.email})")
        flash(f"Ticket opened for {target_user.email}.", "success")
        return redirect(url_for("admin.support_ticket_detail", ticket_id=ticket.id))

    return render_template("admin/support_new.html", form=form)


@admin_bp.route("/support/<ticket_id>", methods=["GET", "POST"])
def support_ticket_detail(ticket_id):
    ticket = SupportTicket.query.get_or_404(ticket_id)
    form = ReplyForm()

    if form.validate_on_submit():
        message = TicketMessage(
            ticket_id=ticket.id, sender_id=current_user.id,
            is_staff_reply=True, body=form.body.data,
        )
        db.session.add(message)
        ticket.status = TicketStatus.PENDING_USER
        if not ticket.assigned_to:
            ticket.assigned_to = current_user.id
        db.session.commit()
        log_action(current_user.id, "admin_ticket_replied", detail=ticket_id)
        return redirect(url_for("admin.support_ticket_detail", ticket_id=ticket_id))

    # context for the "full visibility" requirement: this user's exports/requests
    user_exports = Export.query.filter_by(user_id=ticket.user_id).order_by(
        Export.created_at.desc()
    ).limit(10).all()
    user_extension_requests = RetentionExtensionRequest.query.filter_by(
        user_id=ticket.user_id
    ).order_by(RetentionExtensionRequest.created_at.desc()).limit(10).all()

    admins = User.query.filter_by(role=Role.ADMIN).all()

    return render_template(
        "admin/support_detail.html", ticket=ticket, form=form,
        user_exports=user_exports, user_extension_requests=user_extension_requests,
        admins=admins, statuses=[TicketStatus.OPEN, TicketStatus.PENDING_USER,
                                  TicketStatus.PENDING_SUPPORT, TicketStatus.RESOLVED, TicketStatus.CLOSED],
        priorities=[TicketPriority.LOW, TicketPriority.NORMAL, TicketPriority.HIGH, TicketPriority.URGENT],
    )


@admin_bp.route("/support/<ticket_id>/assign", methods=["POST"])
def support_assign(ticket_id):
    ticket = SupportTicket.query.get_or_404(ticket_id)
    assignee_id = request.form.get("assigned_to") or None
    ticket.assigned_to = assignee_id
    db.session.commit()
    log_action(current_user.id, "admin_ticket_assigned", detail=f"{ticket_id} -> {assignee_id}")
    flash("Ticket assignment updated.", "success")
    return redirect(url_for("admin.support_ticket_detail", ticket_id=ticket_id))


@admin_bp.route("/support/<ticket_id>/status", methods=["POST"])
def support_set_status(ticket_id):
    ticket = SupportTicket.query.get_or_404(ticket_id)
    new_status = request.form.get("status")
    if new_status in (TicketStatus.OPEN, TicketStatus.PENDING_USER, TicketStatus.PENDING_SUPPORT,
                       TicketStatus.RESOLVED, TicketStatus.CLOSED):
        ticket.status = new_status
        if new_status in (TicketStatus.RESOLVED, TicketStatus.CLOSED):
            ticket.closed_at = datetime.utcnow()
        db.session.commit()
        log_action(current_user.id, "admin_ticket_status_changed", detail=f"{ticket_id} -> {new_status}")
        flash("Ticket status updated.", "success")
    return redirect(url_for("admin.support_ticket_detail", ticket_id=ticket_id))


@admin_bp.route("/support/<ticket_id>/priority", methods=["POST"])
def support_set_priority(ticket_id):
    ticket = SupportTicket.query.get_or_404(ticket_id)
    new_priority = request.form.get("priority")
    if new_priority in (TicketPriority.LOW, TicketPriority.NORMAL, TicketPriority.HIGH, TicketPriority.URGENT):
        ticket.priority = new_priority
        db.session.commit()
        log_action(current_user.id, "admin_ticket_priority_changed", detail=f"{ticket_id} -> {new_priority}")
        flash("Priority updated.", "success")
    return redirect(url_for("admin.support_ticket_detail", ticket_id=ticket_id))
