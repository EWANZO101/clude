from flask import Blueprint, render_template, redirect, url_for
from flask_login import login_required

settings_bp = Blueprint("settings", __name__, template_folder="templates")


@settings_bp.route("/settings/")
@settings_bp.route("/settings")
@login_required
def index():
    return redirect(url_for("settings.appearance"))


@settings_bp.route("/settings/appearance")
@login_required
def appearance():
    return render_template("appearance.html")