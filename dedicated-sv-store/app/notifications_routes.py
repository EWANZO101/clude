from flask import Blueprint, jsonify, redirect, url_for, request
from flask_login import login_required, current_user

from app.extensions import db
from app.models.notification import Notification

notifications_bp = Blueprint("notifications", __name__, url_prefix="/notifications")


@notifications_bp.route("/")
@login_required
def list_json():
    items = (
        Notification.query.filter_by(user_id=current_user.id)
        .order_by(Notification.created_at.desc())
        .limit(20)
        .all()
    )
    unread_count = Notification.query.filter_by(user_id=current_user.id, is_read=False).count()
    return jsonify(
        {
            "success": True,
            "data": {
                "unread_count": unread_count,
                "items": [
                    {
                        "id": n.id,
                        "type": n.type,
                        "title": n.title,
                        "body": n.body,
                        "link": n.link,
                        "is_read": n.is_read,
                        "created_at": n.created_at.isoformat(),
                    }
                    for n in items
                ],
            },
        }
    )


@notifications_bp.route("/<int:notification_id>/read", methods=["POST"])
@login_required
def mark_read(notification_id):
    n = Notification.query.filter_by(id=notification_id, user_id=current_user.id).first()
    if n:
        n.is_read = True
        db.session.commit()
    if request.is_json:
        return jsonify({"success": True})
    return redirect(n.link if n and n.link else url_for("marketplace.index"))


@notifications_bp.route("/mark-all-read", methods=["POST"])
@login_required
def mark_all_read():
    Notification.query.filter_by(user_id=current_user.id, is_read=False).update({"is_read": True})
    db.session.commit()
    return jsonify({"success": True})
