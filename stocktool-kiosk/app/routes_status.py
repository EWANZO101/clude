from flask import Blueprint, jsonify, current_app
from app.models import db, Item, Tool, Project, SyncLog, ActivityEvent
from app.settings import load_settings

status_bp = Blueprint("status", __name__, url_prefix="/api/status")


@status_bp.route("", methods=["GET"])
def status():
    try:
        db.session.execute(db.text("SELECT 1"))
        db_ok = True
    except Exception:
        db_ok = False

    settings = load_settings(current_app.config["DATA_DIR"])

    return jsonify({
        "ok": db_ok,
        "version": current_app.config.get("KIOSK_VERSION", "unknown"),
        "release_date": current_app.config.get("KIOSK_RELEASE_DATE"),
        "counts": {
            "items": Item.query.count(),
            "tools": Tool.query.count(),
            "projects": Project.query.count(),
        },
        "cloud_api": current_app.config.get("CLOUD_API_BASE"),
        # Exposure info only — never includes the Cloudflare tunnel
        # token or anything else from settings.json.
        "exposure": {
            "bind_mode": settings.get("bind_mode", "local"),
            "port": settings.get("port", 8420),
        },
    }), 200


@status_bp.route("/sync-log", methods=["GET"])
def sync_log():
    """Placeholder surface for Part 3 — returns the most recent sync
    attempts so the UI can show a status indicator even before the sync
    engine itself exists."""
    rows = SyncLog.query.order_by(SyncLog.created_at.desc()).limit(20).all()
    return jsonify([r.to_dict() for r in rows]), 200


@status_bp.route("/activity", methods=["GET"])
def activity():
    """Real stock/tool activity (item adjustments, checkouts, checkins)
    -- NOT sync events. See ActivityEvent's docstring in models.py for
    why this is a separate table/endpoint from sync-log above."""
    rows = ActivityEvent.query.order_by(ActivityEvent.created_at.desc()).limit(20).all()
    return jsonify([r.to_dict() for r in rows]), 200


@status_bp.route("/update", methods=["GET"])
def update_status():
    """No auth required -- this needs to be checkable from the login
    screen too, since an update applying restarts the whole kiosk
    regardless of who's logged in (or whether anyone is)."""
    from app.update_notifier import get_status
    return jsonify(get_status()), 200