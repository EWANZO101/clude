from flask import Blueprint

developer_bp = Blueprint(
    "developer", __name__, template_folder="templates"
)

from app.developer import routes  # noqa: E402,F401
