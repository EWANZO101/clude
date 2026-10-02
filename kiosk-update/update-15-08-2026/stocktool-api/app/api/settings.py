from flask import Blueprint, request, jsonify
from flask_jwt_extended import jwt_required, current_user
from app.extensions import db
from app.models.settings import Settings
from app.models.audit_log import AuditAction
from app.utils.decorators import admin_required
from app.utils.audit import log_action

api_settings_bp = Blueprint("api_settings", __name__, url_prefix="/api/settings")


@api_settings_bp.route("/", methods=["GET"])
@jwt_required()
def get_settings():
    return jsonify(Settings.get().to_dict()), 200


@api_settings_bp.route("/", methods=["PUT"])
@jwt_required()
@admin_required
def update_settings():
    settings = Settings.get()
    data = request.get_json(silent=True) or {}

    if "app_name" in data and data["app_name"].strip():
        settings.app_name = data["app_name"].strip()
    if "default_low_stock_threshold" in data:
        settings.default_low_stock_threshold = max(0, int(data["default_low_stock_threshold"]))
    if "kiosk_idle_timeout_seconds" in data:
        settings.kiosk_idle_timeout_seconds = max(10, int(data["kiosk_idle_timeout_seconds"]))
    if "kiosk_token_expires_minutes" in data:
        settings.kiosk_token_expires_minutes = max(1, int(data["kiosk_token_expires_minutes"]))
    if "max_checkout_hours" in data:
        settings.max_checkout_hours = max(1, int(data["max_checkout_hours"]))
    if "kiosk_home_screen" in data and data["kiosk_home_screen"] in ("scan", "browse"):
        settings.kiosk_home_screen = data["kiosk_home_screen"]

    log_action(AuditAction.SYSTEM_INIT, "settings", settings.id, "settings",
               f"Settings updated by {current_user.username}", user=current_user)
    db.session.commit()
    return jsonify(settings.to_dict()), 200
