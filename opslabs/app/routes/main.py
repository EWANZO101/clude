from flask import Blueprint, render_template, redirect, url_for

main_bp = Blueprint("main", __name__)


@main_bp.route("/")
def index():
    """The OpsLab Systems hub homepage — a landing page that presents the
    six dedicated service sites and directs visitors to the right one."""
    return render_template("index.html")


@main_bp.route("/about")
def about():
    """About content now lives on the homepage itself."""
    return redirect(url_for("main.index", _anchor="about"))
