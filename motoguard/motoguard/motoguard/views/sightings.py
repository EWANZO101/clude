"""Sighting reports linked to stolen bikes."""
import os
import uuid
from datetime import datetime
from flask import (Blueprint, render_template, redirect, url_for, request,
                   flash, abort, current_app)
from flask_login import current_user
from ..extensions import db
from ..models import Vehicle, Sighting
from ..services import notify
from ..services.mailer import send_email

bp = Blueprint("sightings", __name__)


def _save_image(file_storage):
    if not file_storage or not file_storage.filename:
        return None
    ext = file_storage.filename.rsplit(".", 1)[-1].lower()
    if ext not in current_app.config["ALLOWED_IMAGE_EXT"]:
        return None
    name = f"{uuid.uuid4().hex}.{ext}"
    file_storage.save(os.path.join(current_app.config["UPLOAD_FOLDER"], name))
    return name


@bp.route("/report/<int:vehicle_id>", methods=["GET", "POST"])
def report(vehicle_id):
    v = db.session.get(Vehicle, vehicle_id) or abort(404)
    if v.status != "stolen":
        flash("This bike is not currently reported stolen.", "warning")
        return redirect(url_for("vehicles.detail", vehicle_id=v.id))

    if request.method == "POST":
        if request.form.get("website"):  # honeypot
            abort(400)
        s = Sighting(vehicle_id=v.id)
        s.reporter_id = current_user.id if current_user.is_authenticated else None
        s.seen_city = (request.form.get("seen_city") or "").strip() or None
        s.seen_region = (request.form.get("seen_region") or "").strip() or None
        s.notes = (request.form.get("notes") or "").strip()
        s.contact_pref = request.form.get("contact_pref") or "anonymous"
        seen = (request.form.get("seen_at") or "").strip()
        if seen:
            try:
                s.seen_at = datetime.fromisoformat(seen)
            except ValueError:
                s.seen_at = None
        s.photo = _save_image(request.files.get("photo"))
        db.session.add(s)
        db.session.commit()

        # Notify owner instantly (in-app + email)
        notify(v.owner_id, f"New sighting reported for {v.title}",
               url_for("vehicles.detail", vehicle_id=v.id))
        owner = v.owner
        send_email(
            owner.email, f"Sighting reported: {v.title}",
            f"<p>A sighting was reported for <strong>{v.title}</strong> "
            f"({v.reg_number or 'no reg'}).</p>"
            f"<p>Area: {s.seen_city or 'n/a'}, {s.seen_region or ''}</p>"
            f"<p>Notes: {s.notes or 'none'}</p>",
            f"Sighting for {v.title} at {s.seen_city or 'n/a'}.")
        flash("Thank you. The owner has been notified.", "success")
        return redirect(url_for("vehicles.detail", vehicle_id=v.id))

    return render_template("sightings/report.html", v=v)
