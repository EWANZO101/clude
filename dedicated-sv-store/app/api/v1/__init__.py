from flask import Blueprint

from app.api.v1.helpers import api_success

api_v1_bp = Blueprint("api_v1", __name__)


@api_v1_bp.route("/health")
def health():
    return api_success({"status": "ok"})


from app.api.v1 import servers, hardware, orders, account, admin, webhooks, openapi  # noqa: E402,F401
