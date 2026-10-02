from flask import Blueprint

docs_bp = Blueprint("docs", __name__, template_folder="templates")

from app.docs import routes  # noqa: E402,F401
