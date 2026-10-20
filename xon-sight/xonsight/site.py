from flask import Blueprint, redirect, render_template, url_for
from flask_login import current_user

from .models import Settings

site_bp = Blueprint("site", __name__)


@site_bp.route("/")
def welcome():
    if current_user.is_authenticated:
        return redirect(url_for("views.dashboard"))
    settings = Settings.get()
    return render_template("welcome.html", signup_mode=settings.signup_mode)


@site_bp.route("/api-docs")
def api_docs():
    return render_template("api_docs.html")


@site_bp.route("/docs")
def guide():
    return render_template("guide.html")
