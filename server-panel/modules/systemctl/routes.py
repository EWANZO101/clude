import subprocess
import threading

from flask import Blueprint, render_template, redirect, url_for, flash, jsonify, request
from flask_login import login_required
from flask_socketio import emit, join_room, leave_room

from extensions import socketio
from database import db
from models.service_definition import ServiceDefinition
from services import systemctl_service as svc
from services import file_browser_service as fb
from modules.systemctl.forms import CreateServiceForm
from utils.permissions import require_permission

systemctl_bp = Blueprint("systemctl", __name__, template_folder="templates")


@systemctl_bp.route("/systemctl")
@require_permission("services.manage")
def index():
    error = None
    services = []
    try:
        services = svc.list_services()
    except svc.ServiceCommandError as exc:
        error = str(exc)
    return render_template("systemctl_index.html", services=services, error=error)


@systemctl_bp.route("/systemctl/<path:name>/<action>", methods=["POST"])
@require_permission("services.manage")
def control(name, action):
    own_unit = svc.get_own_unit_name()
    try:
        target_unit = svc._validate_service_name(name)  # noqa: SLF001 - internal reuse
    except svc.ServiceCommandError:
        target_unit = None

    if action in svc.SELF_DEFERRED_ACTIONS and own_unit and target_unit == own_unit:
        try:
            svc.schedule_self_action(name, action)
            flash(
                f"{target_unit} is the panel's own service — {action}ing it in ~2s. "
                f"This page will drop the connection briefly; reload after a few seconds.",
                "success",
            )
        except svc.ServiceCommandError as exc:
            flash(str(exc), "error")
        return redirect(url_for("systemctl.index"))

    try:
        svc.control_service(name, action)
        flash(f"{action.capitalize()}ed {name}.", "success")
    except svc.ServiceCommandError as exc:
        flash(str(exc), "error")
    return redirect(url_for("systemctl.index"))


@systemctl_bp.route("/systemctl/create", methods=["GET", "POST"])
@require_permission("services.manage")
def create():
    form = CreateServiceForm()
    if form.validate_on_submit():
        exec_start = form.exec_start.data.strip()
        try:
            unit_filename, unit_text = svc.generate_unit_file(
                app_name=form.app_name.data,
                working_dir=form.working_dir.data.strip(),
                exec_start=exec_start,
                run_user=form.run_user.data.strip() or "root",
                description=form.description.data.strip(),
            )
            svc.install_unit_file(unit_filename, unit_text)
            svc.daemon_reload()
            svc.control_service(unit_filename, "enable")
            svc.control_service(unit_filename, "start")

            existing = ServiceDefinition.query.filter_by(unit_name=unit_filename).first()
            if existing is None:
                existing = ServiceDefinition(unit_name=unit_filename)
                db.session.add(existing)
            existing.app_name = form.app_name.data.strip()
            existing.working_dir = form.working_dir.data.strip()
            existing.runtime = form.runtime.data
            existing.port = form.port.data.strip()
            existing.exec_start = exec_start
            existing.run_user = form.run_user.data.strip() or "root"
            existing.description = form.description.data.strip()
            db.session.commit()

            flash(f"Created, enabled, and started {unit_filename}.", "success")
            return redirect(url_for("systemctl.index"))
        except svc.ServiceCommandError as exc:
            flash(str(exc), "error")

    return render_template("systemctl_create.html", form=form)


# ---- AJAX: entry-file detection, directory browsing, file read/save ----

@systemctl_bp.route("/systemctl/api/detect-entry", methods=["POST"])
@require_permission("services.manage")
def api_detect_entry():
    data = request.get_json(silent=True) or {}
    working_dir = (data.get("working_dir") or "").strip()
    runtime = (data.get("runtime") or "").strip()
    port = (data.get("port") or "").strip()

    if not working_dir:
        return jsonify({"ok": False, "error": "Enter a working directory first."}), 400

    explicit_entry = (data.get("entry_file") or "").strip() or None

    try:
        if explicit_entry:
            candidates = [explicit_entry]
        else:
            candidates = fb.detect_entry_files(working_dir, runtime)
    except fb.FileBrowserError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    best = candidates[0] if candidates else None
    suggested_exec = fb.build_exec_start(runtime, working_dir, best, port)

    return jsonify({
        "ok": True,
        "candidates": [c for c in candidates],
        "best_match": best,
        "suggested_exec_start": suggested_exec,
    })


@systemctl_bp.route("/systemctl/api/browse")
@require_permission("services.manage")
def api_browse():
    path = request.args.get("path", "/home")
    try:
        result = fb.list_directory(path)
        return jsonify({"ok": True, **result})
    except fb.FileBrowserError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@systemctl_bp.route("/systemctl/api/file", methods=["GET"])
@require_permission("services.manage")
def api_read_file():
    path = request.args.get("path", "")
    try:
        content = fb.read_file(path)
        return jsonify({"ok": True, "path": path, "content": content})
    except fb.FileBrowserError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@systemctl_bp.route("/systemctl/api/file", methods=["POST"])
@require_permission("services.manage")
def api_write_file():
    data = request.get_json(silent=True) or {}
    path = (data.get("path") or "").strip()
    content = data.get("content", "")
    if not path:
        return jsonify({"ok": False, "error": "No file path given."}), 400
    try:
        fb.write_file(path, content)
        return jsonify({"ok": True})
    except fb.FileBrowserError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@systemctl_bp.route("/systemctl/<path:name>/repair", methods=["POST"])
@require_permission("services.manage")
def repair(name):
    messages = []
    try:
        check = svc.verify_unit_file(name)
        messages.append("Unit file OK." if check["ok"] else f"Verify warnings: {check['output'][:300]}")
    except svc.ServiceCommandError as exc:
        messages.append(f"Check failed: {exc}")

    unit_name = name if name.endswith(".service") else f"{name}.service"

    definition = ServiceDefinition.query.filter_by(unit_name=unit_name).first()
    if definition:
        try:
            unit_filename, unit_text = svc.generate_unit_file(
                app_name=definition.app_name,
                working_dir=definition.working_dir,
                exec_start=definition.exec_start,
                run_user=definition.run_user,
                description=definition.description or "",
            )
            svc.install_unit_file(unit_filename, unit_text)
            messages.append("Regenerated unit file from saved definition (previous version backed up).")
        except svc.ServiceCommandError as exc:
            messages.append(f"Regenerate failed: {exc}")
    else:
        messages.append("No saved definition for this service — skipped regenerate (only services created through this panel's wizard can be regenerated).")

    own_unit = svc.get_own_unit_name()
    if own_unit and unit_name == own_unit:
        try:
            svc.daemon_reload()
            svc.schedule_self_action(name, "restart")
            messages.append(f"Daemon reloaded. Restarting {unit_name} in ~2s (this page will drop briefly — reload after a few seconds).")
            flash(" ".join(messages), "success")
        except svc.ServiceCommandError as exc:
            messages.append(f"Restart failed: {exc}")
            flash(" ".join(messages), "error")
        return redirect(url_for("systemctl.index"))

    try:
        svc.daemon_reload()
        svc.control_service(name, "restart")
        messages.append("Daemon reloaded and service restarted.")
        flash(" ".join(messages), "success")
    except svc.ServiceCommandError as exc:
        messages.append(f"Restart failed: {exc}")
        flash(" ".join(messages), "error")

    return redirect(url_for("systemctl.index"))


@systemctl_bp.route("/systemctl/<path:name>/logs")
@require_permission("services.manage")
def logs_page(name):
    return render_template("systemctl_logs.html", service_name=name)


# ---- Live log streaming over SocketIO ----
# Each browser tab joins a room named after the service; a background thread
# tails `journalctl -f -u <service>` and emits new lines only to that room.

_active_tails = {}
_tails_lock = threading.Lock()


def _tail_service_logs(app, service_unit, room):
    with app.app_context():
        try:
            unit = svc._validate_service_name(service_unit)  # noqa: SLF001 - internal reuse
        except svc.ServiceCommandError as exc:
            socketio.emit("log_line", {"line": f"[error] {exc}"}, room=room, namespace="/logs")
            return

        try:
            proc = subprocess.Popen(
                ["journalctl", "-u", unit, "-f", "-n", "50", "-o", "short-iso"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
            )
        except FileNotFoundError:
            socketio.emit("log_line", {"line": "[error] journalctl not available on this host."},
                           room=room, namespace="/logs")
            return

        with _tails_lock:
            _active_tails[room] = proc

        try:
            for line in proc.stdout:
                if _active_tails.get(room) is not proc:
                    break  # a newer tail replaced this one, or it was stopped
                socketio.emit("log_line", {"line": line.rstrip()}, room=room, namespace="/logs")
        finally:
            proc.terminate()
            with _tails_lock:
                if _active_tails.get(room) is proc:
                    del _active_tails[room]


@socketio.on("subscribe", namespace="/logs")
def handle_subscribe(data):
    from flask import current_app

    service_unit = (data or {}).get("service")
    if not service_unit:
        return
    room = f"logs-{service_unit}"
    join_room(room)
    emit("subscribed", {"service": service_unit})
    socketio.start_background_task(_tail_service_logs, current_app._get_current_object(), service_unit, room)


@socketio.on("unsubscribe", namespace="/logs")
def handle_unsubscribe(data):
    service_unit = (data or {}).get("service")
    if not service_unit:
        return
    room = f"logs-{service_unit}"
    leave_room(room)
    with _tails_lock:
        proc = _active_tails.pop(room, None)
    if proc is not None:
        proc.terminate()
