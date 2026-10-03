from flask import Blueprint, render_template, request, jsonify

from models.service_definition import ServiceDefinition
from services import env_files_service as envsvc
from utils.permissions import require_permission

envfiles_bp = Blueprint("envfiles", __name__, template_folder="templates")


@envfiles_bp.route("/envfiles")
@require_permission("envfiles.manage")
def index():
    return render_template("envfiles_index.html")


@envfiles_bp.route("/envfiles/api/scan")
@require_permission("envfiles.manage")
def api_scan():
    known_dirs = [s.working_dir for s in ServiceDefinition.query.all() if s.working_dir]
    files = envsvc.discover_env_files(extra_dirs=known_dirs)

    known_by_dir = {s.working_dir: s.app_name for s in ServiceDefinition.query.all() if s.working_dir}
    for f in files:
        f["service"] = known_by_dir.get(f["dir"])

    return jsonify({"ok": True, "files": files})


@envfiles_bp.route("/envfiles/api/browse")
@require_permission("envfiles.manage")
def api_browse():
    path = request.args.get("path", "/home")
    try:
        result = envsvc.list_directory_all(path)
        return jsonify({"ok": True, **result})
    except envsvc.EnvFilesError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@envfiles_bp.route("/envfiles/api/file", methods=["GET"])
@require_permission("envfiles.manage")
def api_read_file():
    path = request.args.get("path", "")
    if not path:
        return jsonify({"ok": False, "error": "No file path given."}), 400
    try:
        content = envsvc.read_env_file(path)
        return jsonify({"ok": True, "path": path, "content": content})
    except envsvc.fb.FileBrowserError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@envfiles_bp.route("/envfiles/api/file", methods=["POST"])
@require_permission("envfiles.manage")
def api_write_file():
    data = request.get_json(silent=True) or {}
    path = (data.get("path") or "").strip()
    content = data.get("content", "")
    if not path:
        return jsonify({"ok": False, "error": "No file path given."}), 400
    try:
        envsvc.write_env_file(path, content)
        return jsonify({"ok": True})
    except envsvc.fb.FileBrowserError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@envfiles_bp.route("/envfiles/api/new", methods=["POST"])
@require_permission("envfiles.manage")
def api_new_file():
    data = request.get_json(silent=True) or {}
    path = (data.get("path") or "").strip()
    if not path:
        return jsonify({"ok": False, "error": "No file path given."}), 400
    try:
        envsvc.create_env_file(path)
        return jsonify({"ok": True, "path": path})
    except envsvc.EnvFilesError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@envfiles_bp.route("/envfiles/api/backup", methods=["POST"])
@require_permission("envfiles.manage")
def api_backup_file():
    data = request.get_json(silent=True) or {}
    path = (data.get("path") or "").strip()
    if not path:
        return jsonify({"ok": False, "error": "No file path given."}), 400
    try:
        backup_path = envsvc.backup_env_file(path)
        return jsonify({"ok": True, "backup_path": backup_path})
    except envsvc.EnvFilesError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400


@envfiles_bp.route("/envfiles/api/delete", methods=["POST"])
@require_permission("envfiles.manage")
def api_delete_file():
    data = request.get_json(silent=True) or {}
    path = (data.get("path") or "").strip()
    if not path:
        return jsonify({"ok": False, "error": "No file path given."}), 400
    try:
        envsvc.delete_env_file(path)
        return jsonify({"ok": True})
    except envsvc.EnvFilesError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400
