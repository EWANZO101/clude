"""Entry gateway + on-site services page (kept separate from main.py)."""
from flask import Blueprint

site_bp = Blueprint("site", __name__)

from . import routes  # noqa: E402,F401
