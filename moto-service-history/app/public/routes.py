from flask import Blueprint, render_template, abort, send_from_directory, current_app

from app.models import Motorcycle, MotorcyclePhoto, Document

public_bp = Blueprint("public", __name__, url_prefix="/share")


@public_bp.route("/<token>")
def profile(token):
    m = Motorcycle.query.filter_by(share_token=token, share_enabled=True).first()
    if not m:
        abort(404)

    events = []
    if m.share_show_purchase_info and m.purchase_date:
        events.append({
            "date": m.purchase_date, "kind": "purchase", "title": "Motorcycle purchased",
            "detail": None, "cost": m.purchase_price if m.share_show_purchase_info else None,
        })
    if m.share_show_service:
        for r in m.service_records:
            events.append({
                "date": r.date, "kind": "service", "title": r.work_type or "Service",
                "detail": r.description, "cost": r.total_cost,
            })
    if m.share_show_mods:
        for mod in m.modifications:
            events.append({
                "date": mod.date_fitted, "kind": "modification", "title": mod.name,
                "detail": mod.description, "cost": (mod.cost or 0) + (mod.installation_cost or 0),
            })
    if m.share_show_accidents:
        for a in m.accidents:
            events.append({
                "date": a.date, "kind": "accident", "title": "Accident / damage",
                "detail": a.description, "cost": a.repair_cost,
            })
    if m.share_show_mot:
        for mot in m.mot_records:
            events.append({
                "date": mot.test_date, "kind": "mot", "title": f"MOT {mot.result or ''}".strip(),
                "detail": f"Mileage: {mot.mileage}" if mot.mileage else None, "cost": None,
            })
    events = [e for e in events if e["date"]]
    events.sort(key=lambda e: e["date"], reverse=True)

    public_photos = m.photos.filter_by(is_public=True).all()
    public_docs = []
    if m.share_show_documents:
        public_docs = m.documents.filter_by(is_public=True).all()

    return render_template(
        "public/profile.html", m=m, events=events, photos=public_photos, documents=public_docs
    )


@public_bp.route("/<token>/uploads/<path:filename>")
def serve_public_upload(token, filename):
    m = Motorcycle.query.filter_by(share_token=token, share_enabled=True).first()
    if not m:
        abort(404)
    is_public_file = (
        MotorcyclePhoto.query.filter_by(motorcycle_id=m.id, filename=filename, is_public=True).first()
        or (m.share_show_documents and Document.query.filter_by(motorcycle_id=m.id, filename=filename, is_public=True).first())
    )
    if not is_public_file:
        abort(403)
    return send_from_directory(current_app.config["UPLOAD_FOLDER"], filename)
