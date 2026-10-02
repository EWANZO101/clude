from flask import Blueprint, render_template, redirect, url_for
from flask_login import login_required, current_user

from app.extensions import db
from app.core.notifications.models import Notification

notifications_bp = Blueprint("notifications", __name__, url_prefix="/notifications",
                              template_folder="../../templates/notifications")


@notifications_bp.route("/")
@login_required
def index():
    items = Notification.query.filter_by(user_id=current_user.id).order_by(
        Notification.created_at.desc()
    ).limit(100).all()
    return render_template("notifications/index.html", items=items)


@notifications_bp.route("/<int:notification_id>/read", methods=["POST"])
@login_required
def mark_read(notification_id):
    n = Notification.query.filter_by(id=notification_id, user_id=current_user.id).first_or_404()
    n.read = True
    db.session.commit()
    return redirect(url_for("notifications.index"))


@notifications_bp.route("/read-all", methods=["POST"])
@login_required
def mark_all_read():
    Notification.query.filter_by(user_id=current_user.id, read=False).update({"read": True})
    db.session.commit()
    return redirect(url_for("notifications.index"))
