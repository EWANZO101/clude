import os
from flask import Blueprint, render_template, redirect, url_for, current_app, send_from_directory, abort
from flask_login import login_required, current_user

main_bp = Blueprint("main", __name__)


@main_bp.route("/")
def index():
    if current_user.is_authenticated:
        return redirect(url_for("main.dashboard"))
    return render_template("landing.html")


@main_bp.route("/dashboard")
@login_required
def dashboard():
    motorcycles = current_user.motorcycles.all()
    return render_template("dashboard.html", motorcycles=motorcycles)


@main_bp.route("/robots.txt")
def robots():
    from flask import Response
    return Response("User-agent: *\nDisallow: /uploads/\nDisallow: /admin/\nDisallow: /dashboard\n", mimetype="text/plain")


@main_bp.route("/favicon.ico")
def favicon():
    from flask import Response
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
        '<rect width="32" height="32" rx="6" fill="#14171A"/>'
        '<text x="16" y="22" font-family="monospace" font-size="14" font-weight="700" '
        'fill="#F2A93B" text-anchor="middle">SB</text></svg>'
    )
    return Response(svg, mimetype="image/svg+xml")


@main_bp.route("/uploads/<path:filename>")
@login_required
def serve_upload(filename):
    """Serve a privately-uploaded file. Only the owner of the motorcycle it
    belongs to (or an admin) may view it."""
    from app.models import Motorcycle
    from app.extensions import db

    moto_id = None
    if filename.startswith("moto_"):
        moto_id = filename.split("/", 1)[0][len("moto_"):]
    m = db.session.get(Motorcycle, moto_id) if moto_id else None
    if m is None or (m.user_id != current_user.id and not current_user.is_admin):
        abort(403)
    directory = current_app.config["UPLOAD_FOLDER"]
    return send_from_directory(directory, filename)
