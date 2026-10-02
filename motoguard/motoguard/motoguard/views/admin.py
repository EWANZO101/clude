"""Admin moderation tools."""
from functools import wraps
from flask import (Blueprint, render_template, redirect, url_for, request,
                   flash, abort)
from flask_login import login_required, current_user
from ..extensions import db
from ..models import (User, Vehicle, Sighting, Report, ForumPost, ForumComment,
                      Conversation)
from ..services import notify

bp = Blueprint("admin", __name__)


def admin_required(f):
    @wraps(f)
    @login_required
    def wrapper(*a, **kw):
        if not current_user.is_admin:
            abort(403)
        return f(*a, **kw)
    return wrapper


@bp.route("/")
@admin_required
def dashboard():
    stats = {
        "users": User.query.count(),
        "vehicles": Vehicle.query.count(),
        "stolen": Vehicle.query.filter_by(status="stolen").count(),
        "open_reports": Report.query.filter_by(status="open").count(),
        "pending_sightings": Sighting.query.filter_by(status="pending").count(),
    }
    return render_template("admin/dashboard.html", stats=stats)


@bp.route("/reports")
@admin_required
def reports():
    rows = Report.query.filter_by(status="open").order_by(Report.created_at.desc()).all()
    return render_template("admin/reports.html", reports=rows)


@bp.route("/reports/<int:report_id>/resolve", methods=["POST"])
@admin_required
def resolve_report(report_id):
    r = db.session.get(Report, report_id) or abort(404)
    action = request.form.get("action")
    if action == "hide" and r.target_type == "post":
        p = db.session.get(ForumPost, r.target_id)
        if p:
            p.is_hidden = True
    elif action == "hide" and r.target_type == "comment":
        c = db.session.get(ForumComment, r.target_id)
        if c:
            c.is_hidden = True
    r.status = "resolved"
    db.session.commit()
    flash("Report resolved.", "success")
    return redirect(url_for("admin.reports"))


@bp.route("/sightings")
@admin_required
def sightings():
    rows = Sighting.query.order_by(Sighting.created_at.desc()).limit(200).all()
    return render_template("admin/sightings.html", sightings=rows)


@bp.route("/sightings/<int:sighting_id>/<action>", methods=["POST"])
@admin_required
def moderate_sighting(sighting_id, action):
    s = db.session.get(Sighting, sighting_id) or abort(404)
    if action in ("verified", "dismissed", "pending"):
        s.status = action
        db.session.commit()
        if action == "verified":
            notify(s.vehicle.owner_id,
                   f"A sighting for {s.vehicle.title} was verified by moderators.",
                   url_for("vehicles.detail", vehicle_id=s.vehicle_id))
        flash(f"Sighting marked {action}.", "success")
    return redirect(url_for("admin.sightings"))


@bp.route("/users")
@admin_required
def users():
    rows = User.query.order_by(User.created_at.desc()).all()
    return render_template("admin/users.html", users=rows)


@bp.route("/users/<int:user_id>/<action>", methods=["POST"])
@admin_required
def moderate_user(user_id, action):
    u = db.session.get(User, user_id) or abort(404)
    if u.id == current_user.id:
        flash("You cannot moderate yourself.", "error")
        return redirect(url_for("admin.users"))
    if action == "ban":
        u.is_banned = True
    elif action == "unban":
        u.is_banned = False
    elif action == "promote":
        u.is_admin = True
    elif action == "demote":
        u.is_admin = False
    db.session.commit()
    flash("User updated.", "success")
    return redirect(url_for("admin.users"))


@bp.route("/users/<int:user_id>/email", methods=["POST"])
@admin_required
def set_user_email(user_id):
    u = db.session.get(User, user_id) or abort(404)
    new = (request.form.get("email") or "").strip().lower()
    if "@" not in new or "." not in new:
        flash("Enter a valid email address.", "error")
    elif User.query.filter(User.email == new, User.id != u.id).first():
        flash("That email is already in use.", "error")
    else:
        u.email = new
        db.session.commit()
        flash(f"Email updated for {u.username}.", "success")
    return redirect(url_for("admin.users"))


@bp.route("/users/<int:user_id>/password", methods=["POST"])
@admin_required
def set_user_password(user_id):
    u = db.session.get(User, user_id) or abort(404)
    new = request.form.get("password") or ""
    if len(new) < 8:
        flash("Password must be at least 8 characters.", "error")
    else:
        u.set_password(new)
        db.session.commit()
        flash(f"Password reset for {u.username}.", "success")
    return redirect(url_for("admin.users"))
