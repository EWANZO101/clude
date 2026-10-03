from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_required, current_user
from app.extensions import db
from app.models.notification import Notification, NotificationPreference

notifications_bp = Blueprint("notifications", __name__, template_folder="../templates/notifications")


@notifications_bp.route("/")
@login_required
def list_notifications():
    items = Notification.query.filter_by(user_id=current_user.id).order_by(Notification.created_at.desc()).limit(100).all()
    return render_template("notifications/list.html", items=items)


@notifications_bp.route("/<notification_id>/read", methods=["POST"])
@login_required
def mark_read(notification_id):
    n = Notification.query.filter_by(id=notification_id, user_id=current_user.id).first_or_404()
    n.is_read = True
    db.session.commit()
    return redirect(request.referrer or url_for("notifications.list_notifications"))


@notifications_bp.route("/mark-all-read", methods=["POST"])
@login_required
def mark_all_read():
    Notification.query.filter_by(user_id=current_user.id, is_read=False).update({"is_read": True})
    db.session.commit()
    flash("All notifications marked as read.", "success")
    return redirect(url_for("notifications.list_notifications"))


@notifications_bp.route("/preferences", methods=["GET", "POST"])
@login_required
def preferences():
    pref = NotificationPreference.query.get(current_user.id)
    if pref is None:
        pref = NotificationPreference(user_id=current_user.id)
        db.session.add(pref)
        db.session.commit()

    if request.method == "POST":
        for field in ["notify_overdue_invoices", "notify_upcoming_bills", "notify_integration_failures",
                      "notify_audit_warnings", "notify_backup_failures", "notify_sync_failures"]:
            setattr(pref, field, bool(request.form.get(field)))
        db.session.commit()
        flash("Notification preferences saved.", "success")
        return redirect(url_for("notifications.preferences"))

    return render_template("notifications/preferences.html", pref=pref)
