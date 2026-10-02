from flask import Blueprint, render_template, request
from flask_login import current_user
from flask_socketio import emit, disconnect
from flask_wtf.csrf import validate_csrf
from wtforms import ValidationError

from extensions import socketio
from services import terminal_service as term
from utils.permissions import require_permission

console_bp = Blueprint("console", __name__, template_folder="templates")


@console_bp.route("/console")
@require_permission("vps.console")
def index():
    return render_template("console_index.html")


# ---------------------------------------------------------------------------
# Socket.IO handlers — namespace /terminal.
#
# This is the one namespace in the app that gets its own explicit
# authentication + permission + CSRF checks, rather than relying on the
# session cookie alone (see the other namespaces in dashboard/security).
# The gap is deliberate: those hand out read-only stats. This hands out a
# root shell, and the app has cors_allowed_origins="*" set globally, so a
# malicious page could otherwise get an already-logged-in admin's browser
# to open this socket using their session cookie (a CSRF-style attack via
# WebSocket). Requiring a fresh CSRF token — minted by the /console page
# the browser had to actually load first — closes that gap.
# ---------------------------------------------------------------------------

def _authorized():
    return current_user.is_authenticated and current_user.has_permission("vps.console")


def _check_csrf(token):
    try:
        validate_csrf(token)
        return True
    except ValidationError:
        return False


@socketio.on("connect", namespace="/terminal")
def handle_connect():
    if not _authorized():
        return False  # reject the connection outright
    return True


@socketio.on("disconnect", namespace="/terminal")
def handle_disconnect():
    if current_user.is_authenticated:
        term.close_all_for_user(current_user.id)


@socketio.on("create_session", namespace="/terminal")
def handle_create_session(data):
    if not _authorized():
        disconnect()
        return
    if not _check_csrf((data or {}).get("csrf_token")):
        emit("error", {"message": "Session expired — reload the page and try again."})
        return

    sid = request.sid
    user_id = current_user.id

    def on_output(session_id, text):
        socketio.emit("output", {"session_id": session_id, "data": text}, to=sid, namespace="/terminal")

    try:
        session_id = term.open_session(user_id, on_output)
    except term.TerminalError as exc:
        emit("error", {"message": str(exc)})
        return

    current_app_logger = None
    try:
        from flask import current_app
        current_app.logger.warning(
            "VPS console session opened by user '%s' (id=%s), session=%s",
            current_user.username, user_id, session_id,
        )
    except Exception:
        pass

    emit("session_created", {"session_id": session_id})


@socketio.on("input", namespace="/terminal")
def handle_input(data):
    if not _authorized():
        disconnect()
        return
    session_id = (data or {}).get("session_id")
    text = (data or {}).get("data", "")
    if not session_id:
        return
    try:
        term.write_input(session_id, current_user.id, text)
    except term.TerminalError:
        emit("error", {"message": "That session is no longer active.", "session_id": session_id})


@socketio.on("resize", namespace="/terminal")
def handle_resize(data):
    if not _authorized():
        return
    data = data or {}
    session_id = data.get("session_id")
    rows, cols = data.get("rows"), data.get("cols")
    if session_id and rows and cols:
        term.resize(session_id, current_user.id, int(rows), int(cols))


@socketio.on("close_session", namespace="/terminal")
def handle_close_session(data):
    if not _authorized():
        return
    session_id = (data or {}).get("session_id")
    if session_id:
        term.close_session(session_id, current_user.id)
        from flask import current_app
        current_app.logger.warning(
            "VPS console session closed by user '%s', session=%s", current_user.username, session_id,
        )


def start_idle_sweeper(app):
    """Background loop closing terminal sessions idle past the timeout —
    started once from create_app(), same pattern as the dashboard/security
    background loops."""
    def _loop():
        with app.app_context():
            while True:
                socketio.sleep(60)
                try:
                    closed = term.sweep_idle_sessions()
                    if closed:
                        app.logger.info("Closed %d idle VPS console session(s).", closed)
                except Exception as exc:  # noqa: BLE001
                    app.logger.warning("Terminal idle sweeper error: %s", exc)

    socketio.start_background_task(_loop)
