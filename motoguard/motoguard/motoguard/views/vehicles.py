"""Vehicle registration, profiles, and stolen/recovered status handling."""
import os
import uuid
from datetime import datetime
from werkzeug.utils import secure_filename
from flask import (Blueprint, render_template, redirect, url_for, request,
                   flash, abort, current_app, jsonify)
from flask_login import login_required, current_user
from ..extensions import db
from ..models import Vehicle, VehiclePhoto, ForumPost, ForumCategory, Sighting
from ..services import notify
from ..services.geo import to_float

bp = Blueprint("vehicles", __name__)


def _save_image(file_storage):
    if not file_storage or not file_storage.filename:
        return None
    ext = file_storage.filename.rsplit(".", 1)[-1].lower()
    if ext not in current_app.config["ALLOWED_IMAGE_EXT"]:
        return None
    name = f"{uuid.uuid4().hex}.{ext}"
    file_storage.save(os.path.join(current_app.config["UPLOAD_FOLDER"], name))
    return name


@bp.route("/lookup")
@login_required
def lookup():
    from ..services.mot import lookup_registration
    from ..services import ves
    reg = request.args.get("reg", "")
    vehicle, err = lookup_registration(reg)
    if err:
        return jsonify({"ok": False, "error": err})

    # Tax + MOT status box (DVLA VES) — optional, only if configured
    tax = None
    mot_box = None
    if ves.is_configured():
        info, verr = ves.lookup(reg)
        if info:
            tax = {"status": info.get("tax_status"), "due": info.get("tax_due")}
            mot_box = {"status": info.get("mot_status"), "expiry": info.get("mot_expiry")}
    # Fall back to MOT-history-derived validity if VES gave us nothing
    if mot_box is None and vehicle.get("mot_valid") is not None:
        mot_box = {"status": "Valid" if vehicle["mot_valid"] else "Not valid",
                   "expiry": vehicle.get("mot_expiry")}
    return jsonify({"ok": True, "vehicle": vehicle, "tax": tax, "mot": mot_box})


@bp.route("/register", methods=["GET", "POST"])
@login_required
def register():
    if request.method == "POST":
        v = Vehicle(owner_id=current_user.id)
        v.make = (request.form.get("make") or "").strip()
        v.model = (request.form.get("model") or "").strip()
        v.color = (request.form.get("color") or "").strip()
        v.reg_number = (request.form.get("reg_number") or "").strip().upper()
        v.vin = (request.form.get("vin") or "").strip()
        v.description = (request.form.get("description") or "").strip()
        v.privacy = request.form.get("privacy") or "public_when_stolen"
        yr = (request.form.get("year") or "").strip()
        v.year = int(yr) if yr.isdigit() else None
        v.last_city = (request.form.get("last_city") or "").strip() or None
        v.last_region = (request.form.get("last_region") or "").strip() or None
        v.last_country = (request.form.get("last_country") or "").strip() or None
        for fld in ("last_lat", "last_lng"):
            setattr(v, fld, to_float(request.form.get(fld)))
        db.session.add(v)
        db.session.commit()
        for f in request.files.getlist("photos"):
            fn = _save_image(f)
            if fn:
                db.session.add(VehiclePhoto(vehicle_id=v.id, filename=fn))
        db.session.commit()
        flash("Bike registered.", "success")
        return redirect(url_for("vehicles.detail", vehicle_id=v.id))
    return render_template("vehicles/register.html")


@bp.route("/mine")
@login_required
def mine():
    bikes = current_user.vehicles.order_by(Vehicle.created_at.desc()).all()
    return render_template("vehicles/mine.html", bikes=bikes)


@bp.route("/<int:vehicle_id>/edit", methods=["GET", "POST"])
@login_required
def edit(vehicle_id):
    v = db.session.get(Vehicle, vehicle_id) or abort(404)
    if v.owner_id != current_user.id and not current_user.is_admin:
        abort(403)
    if request.method == "POST":
        v.make = (request.form.get("make") or "").strip()
        v.model = (request.form.get("model") or "").strip()
        v.color = (request.form.get("color") or "").strip()
        v.reg_number = (request.form.get("reg_number") or "").strip().upper()
        v.vin = (request.form.get("vin") or "").strip()
        v.description = (request.form.get("description") or "").strip()
        v.privacy = request.form.get("privacy") or v.privacy
        yr = (request.form.get("year") or "").strip()
        v.year = int(yr) if yr.isdigit() else None
        v.last_city = (request.form.get("last_city") or "").strip() or None
        v.last_region = (request.form.get("last_region") or "").strip() or None
        v.last_country = (request.form.get("last_country") or "").strip() or None
        for fld in ("last_lat", "last_lng"):
            setattr(v, fld, to_float(request.form.get(fld)))
        # remove selected existing photos
        for pid in request.form.getlist("delete_photo"):
            if pid.isdigit():
                ph = db.session.get(VehiclePhoto, int(pid))
                if ph and ph.vehicle_id == v.id:
                    try:
                        os.remove(os.path.join(current_app.config["UPLOAD_FOLDER"], ph.filename))
                    except OSError:
                        pass
                    db.session.delete(ph)
        # add any new photos
        for f in request.files.getlist("photos"):
            fn = _save_image(f)
            if fn:
                db.session.add(VehiclePhoto(vehicle_id=v.id, filename=fn))
        db.session.commit()
        flash("Bike details updated.", "success")
        return redirect(url_for("vehicles.detail", vehicle_id=v.id))
    return render_template("vehicles/edit.html", v=v)


@bp.route("/<int:vehicle_id>")
def detail(vehicle_id):
    v = db.session.get(Vehicle, vehicle_id) or abort(404)
    is_owner = current_user.is_authenticated and current_user.id == v.owner_id
    if not v.is_visible_public and not is_owner and not (
            current_user.is_authenticated and current_user.is_admin):
        abort(403)
    sightings = v.sightings.order_by(Sighting.created_at.desc()).all()
    social_post = None
    if is_owner and v.status == "stolen":
        from ..services import build_social_post
        social_post = build_social_post(v)
    return render_template("vehicles/detail.html", v=v, is_owner=is_owner,
                           sightings=sightings, social_post=social_post)


@bp.route("/<int:vehicle_id>/stolen", methods=["POST"])
@login_required
def mark_stolen(vehicle_id):
    v = db.session.get(Vehicle, vehicle_id) or abort(404)
    if v.owner_id != current_user.id:
        abort(403)
    v.status = "stolen"
    v.stolen_at = datetime.utcnow()
    v.alerts_sent = 0
    # allow updating last-seen at point of theft
    v.last_city = (request.form.get("last_city") or v.last_city)
    v.last_region = (request.form.get("last_region") or v.last_region)
    v.last_country = (request.form.get("last_country") or v.last_country)
    for fld in ("last_lat", "last_lng"):
        fv = to_float(request.form.get(fld))
        if fv is not None:
            setattr(v, fld, fv)
    db.session.commit()

    # Owner-triggered alert dispatch (opt-in users in radius, capped per event)
    from ..services import dispatch_stolen_alerts, email_owner_stolen_pack
    sent = dispatch_stolen_alerts(v)
    email_owner_stolen_pack(v)

    # Optional auto forum thread
    if request.form.get("auto_forum"):
        cat = ForumCategory.query.filter_by(slug="stolen-bikes").first()
        if cat:
            p = ForumPost(category_id=cat.id, author_id=current_user.id, vehicle_id=v.id,
                          title=f"STOLEN: {v.title} ({v.reg_number or 'no reg'})",
                          body=(v.description or "") + f"\n\nLast seen: {v.public_location}")
            db.session.add(p)
            db.session.commit()
    flash(f"Marked stolen. {sent} local alert(s) dispatched.", "success")
    return redirect(url_for("vehicles.detail", vehicle_id=v.id))


@bp.route("/<int:vehicle_id>/recovered", methods=["POST"])
@login_required
def mark_recovered(vehicle_id):
    v = db.session.get(Vehicle, vehicle_id) or abort(404)
    if v.owner_id != current_user.id:
        abort(403)
    v.status = "recovered"
    v.recovered_at = datetime.utcnow()
    db.session.commit()
    flash("Marked as recovered. Glad it's back!", "success")
    return redirect(url_for("vehicles.detail", vehicle_id=v.id))


@bp.route("/<int:vehicle_id>/reactivate", methods=["POST"])
@login_required
def reactivate(vehicle_id):
    v = db.session.get(Vehicle, vehicle_id) or abort(404)
    if v.owner_id != current_user.id:
        abort(403)
    v.status = "active"
    v.stolen_at = None
    db.session.commit()
    return redirect(url_for("vehicles.detail", vehicle_id=v.id))


@bp.route("/<int:vehicle_id>/delete", methods=["POST"])
@login_required
def delete(vehicle_id):
    v = db.session.get(Vehicle, vehicle_id) or abort(404)
    if v.owner_id != current_user.id and not current_user.is_admin:
        abort(403)
    db.session.delete(v)
    db.session.commit()
    flash("Bike removed.", "success")
    return redirect(url_for("vehicles.mine"))
