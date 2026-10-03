import json

from flask import Blueprint, redirect, render_template, request, url_for

from ..extensions import db
from ..models import Brand
from ..services.ai import refine_brand

bp = Blueprint("brand", __name__, url_prefix="/brand")


@bp.route("/<int:brand_id>")
def show(brand_id):
    brand = Brand.query.get_or_404(brand_id)
    return render_template("brand.html", brand=brand)


@bp.route("/<int:brand_id>/refine", methods=["POST"])
def refine(brand_id):
    brand = Brand.query.get_or_404(brand_id)
    instruction = request.form.get("instruction", "")
    updates = refine_brand(brand, instruction)

    for field in ["bio", "voice", "cta", "display_name"]:
        if updates.get(field):
            setattr(brand, field, updates[field])
    for field in ["colors", "fonts", "content_pillars"]:
        if updates.get(field):
            setattr(brand, field, json.dumps(updates[field]))

    db.session.commit()
    return redirect(url_for("brand.show", brand_id=brand.id))
