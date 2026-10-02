from flask import Blueprint, render_template

ui_bp = Blueprint("ui", __name__, url_prefix="/ui", template_folder="templates", static_folder="static")


@ui_bp.route("/")
def index():
    return render_template("index.html")


@ui_bp.route("/pastel")
def pastel_setup():
    return render_template("pastel_setup.html")
