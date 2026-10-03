from flask import Blueprint

services_bp = Blueprint("services", __name__, url_prefix="/services")

from . import routes  # noqa: E402,F401
