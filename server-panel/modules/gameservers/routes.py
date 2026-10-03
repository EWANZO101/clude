import threading

from flask import Blueprint, render_template, redirect, url_for, flash, jsonify, request
from flask_login import login_required
from flask_socketio import emit, join_room, leave_room

from extensions import socketio
from database import db
from models.game_server import GameServer
from services import fxserver_service as fx
from services import systemctl_service as svc
from modules.gameservers.forms import GameServerForm
from utils.permissions import require_permission

gameservers_bp = Blueprint("gameservers", __name__, template_folder="templates")


def _apply_form(server, form):
    server.name = form.name.data.strip()
    server.service_unit = (form.service_unit.data or "").strip() or None
    server.http_host = form.http_host.data.strip()
    server.http_port = form.http_port.data
    server.rcon_host = (form.rcon_host.data or "").strip() or None
    server.rcon_port = form.rcon_port.data or None
    # Only overwrite a saved password if a new one was actually typed, so
    # editing other fields doesn't force re-entering RCON creds every time.
    if form.rcon_password.data:
        server.rcon_password = form.rcon_password.data
    server.ban_resource_note = (form.ban_resource_note.data or "").strip() or None


@gameservers_bp.route("/gameservers")
@require_permission("gameservers.manage")
def index():
    servers = GameServer.query.order_by(GameServer.name).all()
    return render_template("gameservers_index.html", servers=servers)


@gameservers_bp.route("/gameservers/new", methods=["GET", "POST"])
@require_permission("gameservers.manage")
def create():
    form = GameServerForm()
    if form.validate_on_submit():
        server = GameServer()
        _apply_form(server, form)
        db.session.add(server)
        db.session.commit()
        flash(f"Added {server.name}.", "success")
        return redirect(url_for("gameservers.index"))
    return render_template("gameservers_form.html", form=form, server=None)


@gameservers_bp.route("/gameservers/<int:server_id>/edit", methods=["GET", "POST"])
@require_permission("gameservers.manage")
def edit(server_id):
    server = db.session.get(GameServer, server_id) or _abort_404()
    form = GameServerForm(obj=server)
    if request.method == "GET":
        form.rcon_password.data = ""  # never echo the stored password back
    if form.validate_on_submit():
        _apply_form(server, form)
        db.session.commit()
        flash(f"Updated {server.name}.", "success")
        return redirect(url_for("gameservers.index"))
    return render_template("gameservers_form.html", form=form, server=server)


@gameservers_bp.route("/gameservers/<int:server_id>/delete", methods=["POST"])
@require_permission("gameservers.manage")
def delete(server_id):
    server = db.session.get(GameServer, server_id) or _abort_404()
    name = server.name
    db.session.delete(server)
    db.session.commit()
    flash(f"Removed {name}. (This didn't touch the underlying service or game server.)", "success")
    return redirect(url_for("gameservers.index"))


@gameservers_bp.route("/gameservers/<int:server_id>")
@require_permission("gameservers.manage")
def detail(server_id):
    server = db.session.get(GameServer, server_id) or _abort_404()
    service_status = None
    if server.service_unit:
        try:
            service_status = svc.get_service_status(server.service_unit)
        except svc.ServiceCommandError as exc:
            service_status = {"error": str(exc)}
    return render_template("gameservers_detail.html", server=server, service_status=service_status)


def _abort_404():
    from flask import abort
    abort(404)


# ---- Service control passthrough (reuses the systemctl module's logic) ----

@gameservers_bp.route("/gameservers/<int:server_id>/service/<action>", methods=["POST"])
@require_permission("gameservers.manage")
def service_control(server_id, action):
    server = db.session.get(GameServer, server_id) or _abort_404()
    if not server.service_unit:
        flash("No systemd unit linked to this server.", "error")
        return redirect(url_for("gameservers.detail", server_id=server_id))
    try:
        svc.control_service(server.service_unit, action)
        flash(f"{action.capitalize()}ed {server.service_unit}.", "success")
    except svc.ServiceCommandError as exc:
        flash(str(exc), "error")
    return redirect(url_for("gameservers.detail", server_id=server_id))


# ---- Status snapshot (used both by the detail page's initial render and
# by the JS poller for repeated refreshes without a full page reload) ----

@gameservers_bp.route("/gameservers/<int:server_id>/api/status")
@require_permission("gameservers.manage")
def api_status(server_id):
    server = db.session.get(GameServer, server_id) or _abort_404()
    snapshot = fx.get_status_snapshot(server)
    return jsonify(snapshot)


# ---- RCON ----

@gameservers_bp.route("/gameservers/<int:server_id>/api/rcon/test", methods=["POST"])
@require_permission("gameservers.manage")
def api_rcon_test(server_id):
    server = db.session.get(GameServer, server_id) or _abort_404()
    try:
        output = fx.test_rcon(server)
        return jsonify({"ok": True, "output": output or "(empty response — likely still correct)"})
    except fx.FXServerError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@gameservers_bp.route("/gameservers/<int:server_id>/api/rcon", methods=["POST"])
@require_permission("gameservers.manage")
def api_rcon_command(server_id):
    server = db.session.get(GameServer, server_id) or _abort_404()
    data = request.get_json(silent=True) or {}
    command = (data.get("command") or "").strip()
    if not command:
        return jsonify({"ok": False, "error": "No command given."}), 400
    try:
        output = fx.send_rcon_command(
            server.effective_rcon_host(), server.effective_rcon_port(),
            server.rcon_password, command,
        )
        return jsonify({"ok": True, "output": output})
    except fx.FXServerError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


# ---- Live status over SocketIO ----
# Each open detail page joins a room named after the server; a background
# thread polls the FXServer HTTP endpoints every few seconds and pushes the
# snapshot only to that room, same pattern as the systemctl log tailer.

_active_polls = {}
_polls_lock = threading.Lock()
POLL_INTERVAL_SECONDS = 5


def _poll_server_status(app, server_id, room):
    with app.app_context():
        while True:
            with _polls_lock:
                if _active_polls.get(room) != threading.current_thread():
                    return  # a newer poller replaced this one, or it was stopped
            server = db.session.get(GameServer, server_id)
            if server is None:
                break
            try:
                snapshot = fx.get_status_snapshot(server)
                socketio.emit("status_update", snapshot, room=room, namespace="/gameservers")
            except Exception as exc:  # noqa: BLE001 - keep the poller alive
                socketio.emit(
                    "status_update",
                    {"online": False, "error": str(exc)},
                    room=room, namespace="/gameservers",
                )
            socketio.sleep(POLL_INTERVAL_SECONDS)


@socketio.on("subscribe", namespace="/gameservers")
def handle_subscribe(data):
    from flask import current_app

    server_id = (data or {}).get("server_id")
    if not server_id:
        return
    room = f"gameserver-{server_id}"
    join_room(room)
    emit("subscribed", {"server_id": server_id})
    with _polls_lock:
        _active_polls[room] = threading.current_thread()  # placeholder; replaced by the started task below
    socketio.start_background_task(_start_poll_marker, current_app._get_current_object(), server_id, room)


def _start_poll_marker(app, server_id, room):
    # Register this background task itself as the "current" poller for the
    # room (threading.current_thread() inside start_background_task is the
    # actual worker thread, unlike the one captured in handle_subscribe).
    with _polls_lock:
        _active_polls[room] = threading.current_thread()
    _poll_server_status(app, server_id, room)


@socketio.on("unsubscribe", namespace="/gameservers")
def handle_unsubscribe(data):
    server_id = (data or {}).get("server_id")
    if not server_id:
        return
    room = f"gameserver-{server_id}"
    leave_room(room)
    with _polls_lock:
        _active_polls.pop(room, None)
