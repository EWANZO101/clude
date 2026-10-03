"""Admin-managed service packages, shown on /services/<slug> pages."""
from flask import Blueprint

packages_bp = Blueprint("packages", __name__)

from . import routes  # noqa: E402,F401
