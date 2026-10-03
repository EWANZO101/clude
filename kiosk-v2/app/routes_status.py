from flask import Blueprint, jsonify, current_app
from app.models import db, Item, Tool, Project, SyncLog

status_bp = Blueprint("status", __name__, url_prefix="/api/status")


@status_bp.route("", methods=["GET"])
def status():
    try:
        db.session.execute(db.text("SELECT 1"))
        db_ok = True
    except Exception:
        db_ok = False

    return jsonify({
        "ok": db_ok,
        "version": current_app.config.get("KIOSK_VERSION", "2.0.0-dev"),
        "counts": {
            "items": Item.query.count(),
            "tools": Tool.query.count(),
            "projects": Project.query.count(),
        },
        "cloud_api": current_app.config.get("CLOUD_API_BASE"),
    }), 200


@status_bp.route("/sync-log", methods=["GET"])
def sync_log():
    """Placeholder surface for Part 3 — returns the most recent sync
    attempts so the UI can show a status indicator even before the sync
    engine itself exists."""
    rows = SyncLog.query.order_by(SyncLog.created_at.desc()).limit(20).all()
    return jsonify([r.to_dict() for r in rows]), 200
