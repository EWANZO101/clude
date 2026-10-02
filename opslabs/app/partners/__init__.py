from flask import Blueprint

partners_bp = Blueprint("partners", __name__)

from . import routes  # noqa: E402,F401
