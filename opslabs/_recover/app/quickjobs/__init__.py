"""Quick Jobs: admin-created shareable jobs with public scheduling links."""
from flask import Blueprint

quickjobs_bp = Blueprint("quickjobs", __name__)

from . import routes  # noqa: E402,F401
