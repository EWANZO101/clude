import os

from flask import Blueprint, abort, current_app, redirect, render_template, send_file, url_for
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
    return render_template("guide.html", tenant_base_domain=current_app.config.get("TENANT_BASE_DOMAIN", ""))


@site_bp.route("/docs/install")
def install():
    """A short, skimmable alternative to guide.html's full walkthrough -
    just "which resource, download it, edit three lines, restart" for
    someone who wants the bodycam running in a couple of minutes, not the
    architecture/requirements/comparison tour."""
    return render_template("install.html")


@site_bp.route("/docs/bodycam")
def bodycam_slides():
    return render_template("bodycam_slides.html")


@site_bp.route("/tools/upload-companion.py")
def upload_companion_download():
    """The standalone media upload companion script (opslabs-bodycam/tools/) - served directly
    so the "video unavailable" banner can link straight to a download, not just a code path in
    the zip. Lives in the FiveM resource bundle, a sibling of this app's own package directory."""
    path = os.path.join(current_app.root_path, "..", "fivem-resource", "opslabs-bodycam", "tools", "upload-companion.py")
    if not os.path.isfile(path):
        abort(404)
    return send_file(path, mimetype="text/x-python", as_attachment=True, download_name="upload-companion.py")
