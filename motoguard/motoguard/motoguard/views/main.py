"""Landing page, dashboard, stolen map, notifications."""
from flask import Blueprint, render_template, jsonify, redirect, url_for, request
from flask_login import login_required, current_user
from ..extensions import db
from ..models import Vehicle, Sighting, Notification, ForumPost

bp = Blueprint("main", __name__)


@bp.route("/")
def index():
    if current_user.is_authenticated:
        return redirect(url_for("main.dashboard"))
    stolen_count = Vehicle.query.filter_by(status="stolen").count()
    recovered = Vehicle.query.filter_by(status="recovered").count()
    recent_stolen = (Vehicle.query.filter_by(status="stolen")
                     .order_by(Vehicle.stolen_at.desc()).limit(12).all())
    return render_template("index.html", stolen_count=stolen_count, recovered=recovered,
                           recent_stolen=recent_stolen)


@bp.route("/about")
def about():
    return render_template("about.html")


@bp.route("/privacy")
def privacy():
    return render_template("legal/privacy.html")


@bp.route("/terms")
def terms():
    return render_template("legal/terms.html")


@bp.route("/geo/search")
def geo_search():
    from ..services import geonames
    rows, err = geonames.search(request.args.get("q", ""))
    if err:
        return jsonify({"ok": False, "error": err, "results": []})
    return jsonify({"ok": True, "results": rows or []})


@bp.route("/dashboard")
@login_required
def dashboard():
    my_bikes = current_user.vehicles.all()
    my_bike_ids = [b.id for b in my_bikes]
    recent_sightings = []
    if my_bike_ids:
        recent_sightings = (Sighting.query
                            .filter(Sighting.vehicle_id.in_(my_bike_ids))
                            .order_by(Sighting.created_at.desc()).limit(10).all())
    stolen_nearby = Vehicle.query.filter_by(status="stolen").order_by(
        Vehicle.stolen_at.desc()).limit(8).all()
    return render_template("dashboard.html", my_bikes=my_bikes,
                           recent_sightings=recent_sightings, stolen_nearby=stolen_nearby)


@bp.route("/map")
def stolen_map():
    return render_template("map.html")


@bp.route("/api/stolen.json")
def stolen_json():
    rows = Vehicle.query.filter_by(status="stolen").all()
    return jsonify([
        {"id": v.id, "title": v.title, "reg": v.reg_number,
         "lat": v.last_lat, "lng": v.last_lng, "area": v.public_location,
         "url": url_for("vehicles.detail", vehicle_id=v.id)}
        for v in rows if v.last_lat and v.last_lng
    ])


@bp.route("/notifications")
@login_required
def notifications():
    notes = (Notification.query.filter_by(user_id=current_user.id)
             .order_by(Notification.created_at.desc()).limit(50).all())
    Notification.query.filter_by(user_id=current_user.id, is_read=False).update(
        {"is_read": True})
    db.session.commit()
    return render_template("notifications.html", notes=notes)
