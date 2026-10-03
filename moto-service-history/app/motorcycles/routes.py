from flask import (
    Blueprint, render_template, redirect, url_for, flash, request, abort, current_app
)
from flask_login import login_required, current_user

from app.extensions import db
from app.models import (
    Motorcycle, MotorcyclePhoto, ServiceRecord, Modification, PartNotFitted,
    Accident, MOTRecord, Document
)
from app.motorcycles.forms import (
    MotorcycleForm, ServiceRecordForm, ModificationForm, PartNotFittedForm,
    FitPartForm, AccidentForm, MOTLookupForm, ManualMOTForm, ShareSettingsForm
)
from app.utils import save_upload, save_uploads, delete_upload, apply_form
from app.mot.dvsa import lookup_mot_history, MOTLookupError

moto_bp = Blueprint("moto", __name__, url_prefix="/motorcycles")


def get_owned_motorcycle_or_404(moto_id):
    m = Motorcycle.query.get_or_404(moto_id)
    if m.user_id != current_user.id and not current_user.is_admin:
        abort(403)
    return m


# ---------- Motorcycle profile ----------

@moto_bp.route("/new", methods=["GET", "POST"])
@login_required
def new():
    form = MotorcycleForm()
    if form.validate_on_submit():
        m = Motorcycle(user_id=current_user.id)
        apply_form(form, m, exclude=("photos",))
        db.session.add(m)
        db.session.flush()
        for rel in save_uploads(form.photos.data, subfolder=f"moto_{m.id}"):
            db.session.add(MotorcyclePhoto(motorcycle_id=m.id, filename=rel))
        db.session.commit()
        flash("Motorcycle profile created.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/form.html", form=form, mode="new")


@moto_bp.route("/<moto_id>")
@login_required
def view(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    return render_template("motorcycles/view.html", m=m)


@moto_bp.route("/<moto_id>/timeline")
@login_required
def timeline(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    return render_template("motorcycles/timeline.html", m=m, events=m.timeline_events())


@moto_bp.route("/<moto_id>/edit", methods=["GET", "POST"])
@login_required
def edit(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    form = MotorcycleForm(obj=m)
    if form.validate_on_submit():
        apply_form(form, m, exclude=("photos",))
        for rel in save_uploads(form.photos.data, subfolder=f"moto_{m.id}"):
            db.session.add(MotorcyclePhoto(motorcycle_id=m.id, filename=rel))
        db.session.commit()
        flash("Motorcycle profile updated.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/form.html", form=form, mode="edit", m=m)


@moto_bp.route("/<moto_id>/delete", methods=["POST"])
@login_required
def delete(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    db.session.delete(m)
    db.session.commit()
    flash("Motorcycle profile deleted.", "info")
    return redirect(url_for("main.dashboard"))


@moto_bp.route("/<moto_id>/photos/<photo_id>/delete", methods=["POST"])
@login_required
def delete_photo(moto_id, photo_id):
    m = get_owned_motorcycle_or_404(moto_id)
    photo = MotorcyclePhoto.query.get_or_404(photo_id)
    if photo.motorcycle_id != m.id:
        abort(404)
    delete_upload(photo.filename)
    db.session.delete(photo)
    db.session.commit()
    return redirect(url_for("moto.view", moto_id=m.id))


# ---------- Service records ----------

@moto_bp.route("/<moto_id>/service/new", methods=["GET", "POST"])
@login_required
def service_new(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    form = ServiceRecordForm()
    if form.validate_on_submit():
        r = ServiceRecord(motorcycle_id=m.id)
        apply_form(form, r, exclude=("documents",))
        db.session.add(r)
        db.session.flush()
        for rel in save_uploads(form.documents.data, subfolder=f"moto_{m.id}/service"):
            db.session.add(Document(motorcycle_id=m.id, service_record_id=r.id, filename=rel, doc_type="service"))
        db.session.commit()
        flash("Service record added.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/record_form.html", form=form, m=m, title="Add service record", record_type="service")


@moto_bp.route("/<moto_id>/service/<record_id>/edit", methods=["GET", "POST"])
@login_required
def service_edit(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    r = ServiceRecord.query.get_or_404(record_id)
    form = ServiceRecordForm(obj=r)
    if form.validate_on_submit():
        apply_form(form, r, exclude=("documents",))
        for rel in save_uploads(form.documents.data, subfolder=f"moto_{m.id}/service"):
            db.session.add(Document(motorcycle_id=m.id, service_record_id=r.id, filename=rel, doc_type="service"))
        db.session.commit()
        flash("Service record updated.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/record_form.html", form=form, m=m, title="Edit service record", record_type="service", record=r)


@moto_bp.route("/<moto_id>/service/<record_id>/delete", methods=["POST"])
@login_required
def service_delete(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    r = ServiceRecord.query.get_or_404(record_id)
    db.session.delete(r)
    db.session.commit()
    flash("Service record removed.", "info")
    return redirect(url_for("moto.view", moto_id=m.id))


# ---------- Modifications ----------

@moto_bp.route("/<moto_id>/mods/new", methods=["GET", "POST"])
@login_required
def mod_new(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    form = ModificationForm()
    if form.validate_on_submit():
        mod = Modification(motorcycle_id=m.id)
        apply_form(form, mod, exclude=("documents",))
        db.session.add(mod)
        db.session.flush()
        for rel in save_uploads(form.documents.data, subfolder=f"moto_{m.id}/mods"):
            db.session.add(Document(motorcycle_id=m.id, modification_id=mod.id, filename=rel, doc_type="modification"))
        db.session.commit()
        flash("Modification added.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/record_form.html", form=form, m=m, title="Add modification / upgrade", record_type="modification")


@moto_bp.route("/<moto_id>/mods/<record_id>/edit", methods=["GET", "POST"])
@login_required
def mod_edit(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    mod = Modification.query.get_or_404(record_id)
    form = ModificationForm(obj=mod)
    if form.validate_on_submit():
        apply_form(form, mod, exclude=("documents",))
        for rel in save_uploads(form.documents.data, subfolder=f"moto_{m.id}/mods"):
            db.session.add(Document(motorcycle_id=m.id, modification_id=mod.id, filename=rel, doc_type="modification"))
        db.session.commit()
        flash("Modification updated.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/record_form.html", form=form, m=m, title="Edit modification", record_type="modification", record=mod)


@moto_bp.route("/<moto_id>/mods/<record_id>/delete", methods=["POST"])
@login_required
def mod_delete(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    mod = Modification.query.get_or_404(record_id)
    db.session.delete(mod)
    db.session.commit()
    flash("Modification removed.", "info")
    return redirect(url_for("moto.view", moto_id=m.id))


# ---------- Parts purchased, not yet fitted ----------

@moto_bp.route("/<moto_id>/parts/new", methods=["GET", "POST"])
@login_required
def part_new(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    form = PartNotFittedForm()
    if form.validate_on_submit():
        p = PartNotFitted(motorcycle_id=m.id)
        apply_form(form, p, exclude=("documents",))
        db.session.add(p)
        db.session.flush()
        for rel in save_uploads(form.documents.data, subfolder=f"moto_{m.id}/parts"):
            db.session.add(Document(motorcycle_id=m.id, part_id=p.id, filename=rel, doc_type="part"))
        db.session.commit()
        flash("Part added to stock.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/record_form.html", form=form, m=m, title="Add purchased part", record_type="part")


@moto_bp.route("/<moto_id>/parts/<record_id>/edit", methods=["GET", "POST"])
@login_required
def part_edit(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    p = PartNotFitted.query.get_or_404(record_id)
    form = PartNotFittedForm(obj=p)
    if form.validate_on_submit():
        apply_form(form, p, exclude=("documents",))
        for rel in save_uploads(form.documents.data, subfolder=f"moto_{m.id}/parts"):
            db.session.add(Document(motorcycle_id=m.id, part_id=p.id, filename=rel, doc_type="part"))
        db.session.commit()
        flash("Part updated.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/record_form.html", form=form, m=m, title="Edit purchased part", record_type="part", record=p)


@moto_bp.route("/<moto_id>/parts/<record_id>/delete", methods=["POST"])
@login_required
def part_delete(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    p = PartNotFitted.query.get_or_404(record_id)
    db.session.delete(p)
    db.session.commit()
    flash("Part removed.", "info")
    return redirect(url_for("moto.view", moto_id=m.id))


@moto_bp.route("/<moto_id>/parts/<record_id>/fit", methods=["GET", "POST"])
@login_required
def part_fit(moto_id, record_id):
    """Move a purchased-not-fitted part into the Modifications history."""
    m = get_owned_motorcycle_or_404(moto_id)
    p = PartNotFitted.query.get_or_404(record_id)
    form = FitPartForm()
    if form.validate_on_submit():
        mod = Modification(
            motorcycle_id=m.id,
            name=p.part_name,
            description=p.notes,
            date_fitted=form.date_fitted.data,
            mileage_fitted=form.mileage_fitted.data,
            manufacturer=p.manufacturer,
            part_number=p.part_number,
            cost=p.purchase_price,
            installation_cost=form.installation_cost.data,
            fitted_by=form.fitted_by.data,
            notes=f"Fitted from parts stock (purchased {p.purchase_date} from {p.supplier or 'unknown supplier'}).",
        )
        db.session.add(mod)
        db.session.flush()
        # move documents across
        for doc in p.documents:
            doc.part_id = None
            doc.modification_id = mod.id
        p.status = "fitted"
        p.fitted_as_modification_id = mod.id
        db.session.commit()
        flash(f"'{p.part_name}' moved to modification history.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/fit_part.html", form=form, m=m, part=p)


# ---------- Accidents ----------

@moto_bp.route("/<moto_id>/accidents/new", methods=["GET", "POST"])
@login_required
def accident_new(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    form = AccidentForm()
    if form.validate_on_submit():
        a = Accident(motorcycle_id=m.id)
        apply_form(form, a, exclude=("documents",))
        db.session.add(a)
        db.session.flush()
        for rel in save_uploads(form.documents.data, subfolder=f"moto_{m.id}/accidents"):
            db.session.add(Document(motorcycle_id=m.id, accident_id=a.id, filename=rel, doc_type="accident"))
        db.session.commit()
        flash("Accident record added.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/record_form.html", form=form, m=m, title="Add accident / damage record", record_type="accident")


@moto_bp.route("/<moto_id>/accidents/<record_id>/edit", methods=["GET", "POST"])
@login_required
def accident_edit(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    a = Accident.query.get_or_404(record_id)
    form = AccidentForm(obj=a)
    if form.validate_on_submit():
        apply_form(form, a, exclude=("documents",))
        for rel in save_uploads(form.documents.data, subfolder=f"moto_{m.id}/accidents"):
            db.session.add(Document(motorcycle_id=m.id, accident_id=a.id, filename=rel, doc_type="accident"))
        db.session.commit()
        flash("Accident record updated.", "success")
        return redirect(url_for("moto.view", moto_id=m.id))
    return render_template("motorcycles/record_form.html", form=form, m=m, title="Edit accident record", record_type="accident", record=a)


@moto_bp.route("/<moto_id>/accidents/<record_id>/delete", methods=["POST"])
@login_required
def accident_delete(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    a = Accident.query.get_or_404(record_id)
    db.session.delete(a)
    db.session.commit()
    flash("Accident record removed.", "info")
    return redirect(url_for("moto.view", moto_id=m.id))


# ---------- Documents (generic, per-motorcycle library) ----------

@moto_bp.route("/<moto_id>/documents/<doc_id>/delete", methods=["POST"])
@login_required
def document_delete(moto_id, doc_id):
    m = get_owned_motorcycle_or_404(moto_id)
    doc = Document.query.get_or_404(doc_id)
    if doc.motorcycle_id != m.id:
        abort(404)
    delete_upload(doc.filename)
    db.session.delete(doc)
    db.session.commit()
    flash("Document removed.", "info")
    return redirect(url_for("moto.view", moto_id=m.id))


@moto_bp.route("/<moto_id>/documents/<doc_id>/toggle-public", methods=["POST"])
@login_required
def document_toggle_public(moto_id, doc_id):
    m = get_owned_motorcycle_or_404(moto_id)
    doc = Document.query.get_or_404(doc_id)
    if doc.motorcycle_id != m.id:
        abort(404)
    doc.is_public = not doc.is_public
    db.session.commit()
    return redirect(url_for("moto.view", moto_id=m.id))


# ---------- MOT history ----------

@moto_bp.route("/<moto_id>/mot", methods=["GET", "POST"])
@login_required
def mot(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    lookup_form = MOTLookupForm(registration=m.registration)
    manual_form = ManualMOTForm()
    if lookup_form.validate_on_submit() and request.form.get("action") == "lookup":
        try:
            result = lookup_mot_history(lookup_form.registration.data)
            records = result["tests"]
            vehicle = result["vehicle"]

            filled = []
            if not m.registration and vehicle.get("registration"):
                m.registration = vehicle["registration"]
                filled.append("registration")
            if not m.make and vehicle.get("make"):
                m.make = vehicle["make"]
                filled.append("make")
            if not m.model and vehicle.get("model"):
                m.model = vehicle["model"]
                filled.append("model")
            if not m.colour and vehicle.get("colour"):
                m.colour = vehicle["colour"]
                filled.append("colour")
            if not m.year and vehicle.get("year"):
                m.year = vehicle["year"]
                filled.append("year")
            if not m.engine_info and (vehicle.get("engine_size") or vehicle.get("fuel_type")):
                bits = [b for b in [vehicle.get("engine_size"), vehicle.get("fuel_type")] if b]
                m.engine_info = " ".join(str(b) for b in bits)
                filled.append("engine info")

            added = 0
            for rec in records:
                exists = MOTRecord.query.filter_by(
                    motorcycle_id=m.id, test_number=rec.get("test_number")
                ).first()
                if exists:
                    continue
                db.session.add(MOTRecord(
                    motorcycle_id=m.id,
                    test_date=rec.get("test_date"),
                    expiry_date=rec.get("expiry_date"),
                    result=rec.get("result"),
                    mileage=rec.get("mileage"),
                    mileage_unit=rec.get("mileage_unit"),
                    test_number=rec.get("test_number"),
                    advisories=rec.get("advisories"),
                    failures=rec.get("failures"),
                    raw_source="dvsa_api",
                ))
                added += 1
            db.session.commit()

            msg = f"Retrieved MOT history — {added} new record(s) saved."
            if filled:
                msg += f" Auto-filled: {', '.join(filled)}."
            flash(msg, "success")
        except MOTLookupError as e:
            flash(f"MOT lookup failed: {e}", "error")
        return redirect(url_for("moto.mot", moto_id=m.id))

    if manual_form.validate_on_submit() and request.form.get("action") == "manual":
        db.session.add(MOTRecord(
            motorcycle_id=m.id,
            test_date=manual_form.test_date.data,
            expiry_date=manual_form.expiry_date.data,
            result=manual_form.result.data,
            mileage=manual_form.mileage.data,
            advisories=manual_form.advisories.data,
            failures=manual_form.failures.data,
            raw_source="manual",
        ))
        db.session.commit()
        flash("MOT record added manually.", "success")
        return redirect(url_for("moto.mot", moto_id=m.id))

    return render_template(
        "motorcycles/mot.html", m=m, lookup_form=lookup_form, manual_form=manual_form
    )


@moto_bp.route("/<moto_id>/mot/<record_id>/delete", methods=["POST"])
@login_required
def mot_delete(moto_id, record_id):
    m = get_owned_motorcycle_or_404(moto_id)
    rec = MOTRecord.query.get_or_404(record_id)
    db.session.delete(rec)
    db.session.commit()
    return redirect(url_for("moto.mot", moto_id=m.id))


# ---------- Public share settings ----------

@moto_bp.route("/<moto_id>/share", methods=["GET", "POST"])
@login_required
def share(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    form = ShareSettingsForm(obj=m)
    if form.validate_on_submit():
        form.populate_obj(m)
        db.session.commit()
        flash("Sharing settings updated.", "success")
        return redirect(url_for("moto.share", moto_id=m.id))
    return render_template("motorcycles/share.html", m=m, form=form)


@moto_bp.route("/<moto_id>/share/regenerate", methods=["POST"])
@login_required
def share_regenerate(moto_id):
    m = get_owned_motorcycle_or_404(moto_id)
    m.regenerate_share_token()
    db.session.commit()
    flash("New public link generated — the old link no longer works.", "info")
    return redirect(url_for("moto.share", moto_id=m.id))
