"""Customer portal blueprint: dashboard, projects, appointments, invoices."""
from flask import Blueprint

portal_bp = Blueprint(
    "portal", __name__,
    template_folder="templates",  # falls back to app/templates/portal too
)

from . import routes  # noqa: E402,F401  (registers routes on import)
