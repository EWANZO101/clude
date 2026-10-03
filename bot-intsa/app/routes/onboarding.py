import json

from flask import Blueprint, redirect, render_template, request, url_for

from ..extensions import db
from ..models import Brand
from ..services.ai import generate_brand_kit

bp = Blueprint("onboarding", __name__, url_prefix="/onboarding")


@bp.route("/")
def start():
    return render_template("onboarding.html")


@bp.route("/generate", methods=["POST"])
def generate():
    profile = {
        "name": request.form.get("name", ""),
        "niche": request.form.get("niche", ""),
        "audience": request.form.get("audience", ""),
        "location": request.form.get("location", ""),
        "goal": request.form.get("goal", ""),
        "style": request.form.get("style", ""),
    }
    kit = generate_brand_kit(profile)

    brand = Brand(
        name=profile["name"],
        niche=profile["niche"],
        location=profile["location"],
        audience=profile["audience"],
        goal=profile["goal"],
        style=profile["style"],
        display_name=kit.get("display_name", profile["name"]),
        username_suggestions=json.dumps(kit.get("usernames", [])),
        bio=kit.get("bio", ""),
        voice=kit.get("voice", ""),
        colors=json.dumps(kit.get("colors", [])),
        fonts=json.dumps(kit.get("fonts", [])),
        content_pillars=json.dumps(kit.get("content_pillars", [])),
        highlight_categories=json.dumps(kit.get("highlight_categories", [])),
        cta=kit.get("cta", ""),
    )
    db.session.add(brand)
    db.session.commit()
    return redirect(url_for("brand.show", brand_id=brand.id))
