from flask import Blueprint, jsonify, current_app

from app.settings import load_settings

backup_bp = Blueprint("backup", __name__, url_prefix="/api/backup")


@backup_bp.route("/status", methods=["GET"])
def backup_status():
    settings = load_settings(current_app.config["DATA_DIR"])
    paired = bool(settings.get("setup_installation_token"))
    return jsonify({
        "paired": paired,
        "setup_api_base": settings.get("setup_api_base") if paired else None,
        "paired_at": settings.get("setup_paired_at"),
    }), 200


@backup_bp.route("/trigger", methods=["POST"])
def backup_trigger():
    """Manual 'Backup Now' — wakes the background loop early instead of
    waiting for its next scheduled cycle. No-ops if not paired yet."""
    settings = load_settings(current_app.config["DATA_DIR"])
    if not settings.get("setup_installation_token"):
        return jsonify({"error": "Not paired with StockTool Setup yet — run 'StockTool Kiosk Setup'."}), 409

    from backup_loop import trigger_backup_now
    trigger_backup_now()
    return jsonify({"ok": True, "message": "Backup requested — it'll run within a few seconds."}), 202
