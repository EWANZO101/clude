from flask import Blueprint

cloudloader_bp = Blueprint("cloudloader", __name__, template_folder="templates")

from app.cloudloader import routes  # noqa: E402,F401
