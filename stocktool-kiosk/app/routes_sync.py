from flask import Blueprint, jsonify, current_app
from app.models import SyncState, SyncLog

sync_status_bp = Blueprint("sync_status", __name__, url_prefix="/api/sync")


@sync_status_bp.route("/status", methods=["GET"])
def status():
    state = SyncState.get()
    recent = SyncLog.query.order_by(SyncLog.created_at.desc()).limit(20).all()
    return jsonify({
        "state": state.to_dict(),
        "recent_log": [r.to_dict() for r in recent],
    }), 200


@sync_status_bp.route("/trigger", methods=["POST"])
def trigger():
    """Manual 'Sync Now' — runs registration (if needed), pull, then
    push, synchronously, and reports what happened. Useful for a UI
    button and for troubleshooting connectivity issues on the spot."""
    engine = current_app.config.get("SYNC_ENGINE")
    if not engine:
        return jsonify({"error": "Sync engine not initialized."}), 503

    registered = engine.ensure_registered()
    if not registered:
        return jsonify({"ok": False, "step": "register", "message": "Could not reach the cloud API."}), 502

    pull_ok = engine.pull()
    push_ok = engine.push()
    engine.fetch_config()

    return jsonify({
        "ok": pull_ok and push_ok,
        "pull_ok": pull_ok,
        "push_ok": push_ok,
    }), 200
