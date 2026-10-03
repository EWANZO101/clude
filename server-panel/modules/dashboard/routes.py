import threading
import time

from flask import Blueprint, render_template
from flask_login import login_required, current_user
from flask_socketio import emit

from extensions import socketio
from services import system_service, security_service as sec
from services import ddos_service as ddos

dashboard_bp = Blueprint("dashboard", __name__, template_folder="templates")

_emitter_started = False
_emitter_lock = threading.Lock()

# Populated every second by _background_stats_loop. get_full_snapshot() does
# a system-wide psutil.net_connections() scan, which isn't free — it was
# being run twice on every dashboard visit (once here, once in the loop)
# for data that's already at most ~1s stale. The route now reuses whatever
# the loop last produced, and only falls back to computing fresh if the
# panel just started and the loop hasn't emitted anything yet.
_last_snapshot = None
_last_snapshot_lock = threading.Lock()


@dashboard_bp.route("/dashboard")
@login_required
def index():
    with _last_snapshot_lock:
        snapshot = _last_snapshot
    if snapshot is None:
        snapshot = system_service.get_full_snapshot()

    security_summary = None
    if current_user.has_permission("security.view"):
        ddos_status = ddos.get_status()
        security_summary = {
            "ssh_session_count": len(sec.get_ssh_sessions()),
            "blocked_ip_count": len(sec.get_blocked_ips()),
            "ddos_status": ddos_status,
            "health": sec.compute_health(snapshot, ddos_status),
        }

    return render_template("dashboard.html", snapshot=snapshot, security=security_summary)


@dashboard_bp.route("/")
@login_required
def root():
    return index()


def _background_stats_loop(app):
    """Pushes a fresh stats snapshot to all connected clients every second."""
    global _last_snapshot
    with app.app_context():
        while True:
            try:
                snapshot = system_service.get_full_snapshot()
                with _last_snapshot_lock:
                    _last_snapshot = snapshot
                socketio.emit("stats_update", snapshot, namespace="/dashboard")
            except Exception as exc:  # noqa: BLE001 - keep the loop alive no matter what
                app.logger.warning("Stats emitter error: %s", exc)
            socketio.sleep(1)


def start_stats_emitter(app):
    global _emitter_started
    with _emitter_lock:
        if _emitter_started:
            return
        _emitter_started = True
        socketio.start_background_task(_background_stats_loop, app)


@socketio.on("connect", namespace="/dashboard")
def handle_connect():
    with _last_snapshot_lock:
        snapshot = _last_snapshot
    if snapshot is None:
        snapshot = system_service.get_full_snapshot()
    emit("stats_update", snapshot)
