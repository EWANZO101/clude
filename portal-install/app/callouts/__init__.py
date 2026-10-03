"""Public 'Book a call-out' / meeting requests + admin handling."""
from flask import Blueprint

callouts_bp = Blueprint("callouts", __name__)

from . import routes  # noqa: E402,F401
