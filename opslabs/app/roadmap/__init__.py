"""Public product roadmap: kanban-style board (/roadmap) + admin editor."""
from flask import Blueprint

roadmap_bp = Blueprint("roadmap", __name__)

from . import routes  # noqa: E402,F401
