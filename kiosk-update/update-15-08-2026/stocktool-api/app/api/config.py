from flask import Blueprint, jsonify
from app.models import Settings
from app.utils.install_auth import install_token_required

api_kiosk_config_bp = Blueprint("api_kiosk_config", __name__, url_prefix="/api/config")


@api_kiosk_config_bp.route("", methods=["GET"])
@install_token_required
def get_config():
    """
    Configuration the desktop client needs at startup / periodically:
    existing admin-managed settings, plus sync/update-check cadence.
    Kept separate from the admin-facing /api/settings endpoint (which
    manages a broader set of admin-console settings) so the desktop
    client only ever sees the subset relevant to it.
    """
    settings = Settings.get()
    return jsonify({
        "app_name": settings.app_name,
        "default_low_stock_threshold": settings.default_low_stock_threshold,
        "sync_interval_seconds": 120,
        "update_check_interval_seconds": 3600,
        "heartbeat_interval_seconds": 300,
    }), 200
