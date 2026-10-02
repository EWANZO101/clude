import json
import os
import secrets
import tempfile
import zipfile
from datetime import datetime

from flask import (
    Blueprint, render_template, redirect, url_for, flash, request,
    current_app, jsonify, send_file, abort,
)
from flask_login import login_required, current_user

from app.extensions import db, csrf
from app.models import (
    AgentJob, AgentJobKind, AgentJobStatus,
    Export, ExportStatus, ImportJob, ImportStatus,
)
from app.agent.forms import AgentExportForm, AgentImportForm
from app.exports.service import (
    sha256_of_file, KNOWN_CONFIG_PATHS, KNOWN_UPLOAD_DIRS, KNOWN_CAD_CONFIG_PATHS,
)
from app.auth.routes import log_action

agent_bp = Blueprint("agent", __name__, url_prefix="/agent")

# The agent authenticates with a bearer-style token instead of a browser
# session/cookie, so there's no CSRF token to send — exempt this whole
# blueprint's API surface from CSRF checks. The UI routes below still sit
# behind @login_required and normal form CSRF where they render a <form>.
csrf.exempt(agent_bp)


# ---------------------------------------------------------------------------
# Human-facing UI
# ---------------------------------------------------------------------------

@agent_bp.route("/new-export", methods=["GET", "POST"])
@login_required
def new_export():
    form = AgentExportForm()
    if form.validate_on_submit():
        export = Export(user_id=current_user.id, status=ExportStatus.PENDING)
        db.session.add(export)
        db.session.flush()

        job = AgentJob(
            user_id=current_user.id,
            kind=AgentJobKind.EXPORT,
            token=secrets.token_urlsafe(32),
            config_json=json.dumps({
                "install_path": form.install_path.data or None,
                "include_files": form.include_files.data,
                "db_config": form.get_db_config(),
                "include_uploads": form.include_uploads.data,
                "extra_paths": form.get_extra_paths(),
            }),
            export_id=export.id,
        )
        db.session.add(job)
        db.session.commit()
        log_action(current_user.id, "agent_export_created", detail=job.id)
        return redirect(url_for("agent.job_status", job_id=job.id))

    return render_template("agent/new_export.html", form=form)


@agent_bp.route("/new-import", methods=["GET", "POST"])
@login_required
def new_import():
    form = AgentImportForm()
    available = Export.query.filter_by(
        user_id=current_user.id, status=ExportStatus.COMPLETE
    ).order_by(Export.created_at.desc()).all()
    form.source_export_id.choices = [
        (e.id, f"{e.created_at:%Y-%m-%d %H:%M} — {(e.file_size_bytes or 0) / 1048576:.1f} MB")
        for e in available
    ]

    if not available:
        flash("You need at least one completed export to restore from.", "warning")
        return redirect(url_for("main.dashboard"))

    if form.validate_on_submit():
        source_export = Export.query.get_or_404(form.source_export_id.data)
        if source_export.user_id != current_user.id:
            abort(403)

        import_job = ImportJob(
            user_id=current_user.id,
            source_filename=os.path.basename(source_export.file_path or "export.zip"),
            target_path=form.target_path.data if form.restore_files.data else None,
            status=ImportStatus.PENDING,
        )
        db.session.add(import_job)
        db.session.flush()

        job = AgentJob(
            user_id=current_user.id,
            kind=AgentJobKind.IMPORT,
            token=secrets.token_urlsafe(32),
            config_json=json.dumps({
                "source_export_id": source_export.id,
                "target_path": form.target_path.data or None,
                "restore_files": form.restore_files.data,
                "db_target": form.get_db_target(),
            }),
            import_job_id=import_job.id,
        )
        db.session.add(job)
        db.session.commit()
        log_action(current_user.id, "agent_import_created", detail=job.id)
        return redirect(url_for("agent.job_status", job_id=job.id))

    return render_template("agent/new_import.html", form=form)


@agent_bp.route("/job/<job_id>")
@login_required
def job_status(job_id):
    job = AgentJob.query.get_or_404(job_id)
    if job.user_id != current_user.id and not current_user.is_admin():
        abort(404)
    server_url = request.url_root.rstrip("/")
    return render_template("agent/job_status.html", job=job, server_url=server_url)


@agent_bp.route("/job/<job_id>/status.json")
@login_required
def job_status_json(job_id):
    job = AgentJob.query.get_or_404(job_id)
    if job.user_id != current_user.id and not current_user.is_admin():
        abort(404)
    return jsonify({
        "status": job.status,
        "agent_hostname": job.agent_hostname,
        "agent_os": job.agent_os,
        "error_message": job.error_message,
        "export_id": job.export_id,
        "import_job_id": job.import_job_id,
        "progress_percent": job.progress_percent,
        "log_lines": job.log_text.split("\n") if job.log_text else [],
    })


@agent_bp.route("/download-script")
@login_required
def download_script():
    path = os.path.join(current_app.root_path, "..", "agent_downloads", "snailycad_agent.py")
    return send_file(os.path.abspath(path), as_attachment=True, download_name="snailycad_agent.py")


def _load_agent_script_template():
    path = os.path.join(current_app.root_path, "..", "agent_downloads", "snailycad_agent.py")
    with open(os.path.abspath(path)) as f:
        return f.read()


def _embed_config(script_text, server_url, token):
    # token is our own secrets.token_urlsafe() output and server_url is
    # built from request.url_root — neither can contain a literal quote,
    # but escape defensively anyway since this is a straight text splice.
    safe_server = server_url.replace('"', '\\"')
    safe_token = token.replace('"', '\\"')
    script_text = script_text.replace("EMBEDDED_SERVER = None", f'EMBEDDED_SERVER = "{safe_server}"')
    script_text = script_text.replace("EMBEDDED_TOKEN = None", f'EMBEDDED_TOKEN = "{safe_token}"')
    return script_text


def _get_owned_job(job_id):
    job = AgentJob.query.get_or_404(job_id)
    if job.user_id != current_user.id and not current_user.is_admin():
        abort(404)
    return job


@agent_bp.route("/job/<job_id>/download-windows")
@login_required
def download_windows(job_id):
    job = _get_owned_job(job_id)
    server_url = request.url_root.rstrip("/")
    script_text = _embed_config(_load_agent_script_template(), server_url, job.token)

    launcher_bat = (
        "@echo off\r\n"
        "setlocal\r\n"
        "cd /d \"%~dp0\"\r\n"
        "echo SnailyCAD Migration Platform Agent\r\n"
        "echo.\r\n"
        "where py >nul 2>nul\r\n"
        "if %ERRORLEVEL% EQU 0 (\r\n"
        "    py \"%~dp0snailycad_agent.py\"\r\n"
        "    goto :eof\r\n"
        ")\r\n"
        "where python >nul 2>nul\r\n"
        "if %ERRORLEVEL% EQU 0 (\r\n"
        "    python \"%~dp0snailycad_agent.py\"\r\n"
        "    goto :eof\r\n"
        ")\r\n"
        "echo Python 3 was not found on this machine.\r\n"
        "echo Install it from https://www.python.org/downloads/ ^(check \"Add python.exe to PATH\"^)\r\n"
        "echo then double-click this file again.\r\n"
        "echo.\r\n"
        "pause\r\n"
    )

    work_dir = tempfile.mkdtemp(prefix="agent-dl-")
    zip_path = os.path.join(work_dir, "SnailyCAD-Agent-Windows.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("snailycad_agent.py", script_text)
        zf.writestr("Start Agent.bat", launcher_bat)
        zf.writestr(
            "README.txt",
            "Double-click \"Start Agent.bat\" to run.\r\n\r\n"
            "Requires Python 3 (https://www.python.org/downloads) — if it's not\r\n"
            "already installed, the launcher will tell you and link the installer.\r\n"
            "During install, check \"Add python.exe to PATH\".\r\n",
        )

    return send_file(zip_path, as_attachment=True, download_name="SnailyCAD-Agent-Windows.zip")


@agent_bp.route("/job/<job_id>/download-linux")
@login_required
def download_linux(job_id):
    job = _get_owned_job(job_id)
    server_url = request.url_root.rstrip("/")
    script_text = _embed_config(_load_agent_script_template(), server_url, job.token)

    launcher_sh = (
        "#!/usr/bin/env bash\n"
        'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        'python3 "$DIR/snailycad_agent.py"\n'
    )

    work_dir = tempfile.mkdtemp(prefix="agent-dl-")
    zip_path = os.path.join(work_dir, "snailycad-agent-linux.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("snailycad_agent.py", script_text)
        zi = zipfile.ZipInfo("start-agent.sh")
        zi.external_attr = 0o755 << 16  # preserve the executable bit
        zf.writestr(zi, launcher_sh)
        zf.writestr(
            "README.txt",
            "Run: chmod +x start-agent.sh && ./start-agent.sh\n"
            "(or: python3 snailycad_agent.py directly — needs no other setup)\n",
        )

    return send_file(zip_path, as_attachment=True, download_name="snailycad-agent-linux.zip")


# ---------------------------------------------------------------------------
# Agent API — token-authenticated, no login/session involved. The agent
# always connects OUT to these endpoints; nothing needs to be reachable on
# the agent's side.
# ---------------------------------------------------------------------------

def _authenticate(job_id=None):
    token = request.headers.get("X-Agent-Token")
    if not token and request.is_json:
        token = (request.get_json(silent=True) or {}).get("token")
    if not token:
        token = request.form.get("token")

    if not token:
        abort(401)

    query = AgentJob.query.filter_by(token=token)
    if job_id:
        query = query.filter_by(id=job_id)
    job = query.first()
    if not job:
        abort(401)
    if job.is_token_expired:
        abort(410)
    return job


@agent_bp.route("/api/handshake", methods=["POST"])
def api_handshake():
    job = _authenticate()
    if job.status not in (AgentJobStatus.WAITING, AgentJobStatus.CONNECTED):
        return jsonify({"error": f"Job is already {job.status}"}), 409

    payload = request.get_json(silent=True) or {}
    job.status = AgentJobStatus.CONNECTED
    job.connected_at = job.connected_at or datetime.utcnow()
    job.agent_hostname = payload.get("hostname")
    job.agent_os = payload.get("os")
    db.session.commit()
    log_action(job.user_id, "agent_connected", detail=f"{job.id} ({job.agent_hostname})")

    config = json.loads(job.config_json)

    response = {"job_id": job.id, "kind": job.kind, "config": config}
    if job.kind == AgentJobKind.EXPORT:
        response["known_paths"] = {
            "config": KNOWN_CONFIG_PATHS,
            "uploads": KNOWN_UPLOAD_DIRS,
            "cad_config": KNOWN_CAD_CONFIG_PATHS,
        }
    return jsonify(response)


@agent_bp.route("/api/<job_id>/upload-package", methods=["POST"])
def api_upload_package(job_id):
    job = _authenticate(job_id)
    if job.kind != AgentJobKind.EXPORT:
        return jsonify({"error": "This job isn't an export job"}), 400

    uploaded = request.files.get("file")
    if not uploaded:
        return jsonify({"error": "No file uploaded"}), 400

    job.status = AgentJobStatus.FINALIZING
    db.session.commit()

    work_dir = tempfile.mkdtemp(prefix=f"agent-upload-{job.id}-")
    zip_path = os.path.join(work_dir, "package.zip")
    uploaded.save(zip_path)

    try:
        if not zipfile.is_zipfile(zip_path):
            raise ValueError("Uploaded file is not a valid zip archive.")

        extract_dir = os.path.join(work_dir, "extracted")
        os.makedirs(extract_dir, exist_ok=True)
        with zipfile.ZipFile(zip_path) as zf:
            for member in zf.namelist():
                dest = os.path.abspath(os.path.join(extract_dir, member))
                if not dest.startswith(os.path.abspath(extract_dir) + os.sep):
                    raise ValueError(f"Unsafe path in uploaded package: {member}")
            zf.extractall(extract_dir)

        manifest_path = os.path.join(extract_dir, "manifest.json")
        if not os.path.isfile(manifest_path):
            raise ValueError("Uploaded package is missing manifest.json.")
        with open(manifest_path) as f:
            manifest = json.load(f)

        # Recompute every hash server-side rather than trusting the agent's
        # claims — defense in depth in case an agent is buggy or tampered with.
        for item in manifest.get("items", []):
            full = os.path.join(extract_dir, *item["archive_path"].split("/"))
            if not os.path.isfile(full):
                raise ValueError(f"Missing from package: {item['archive_path']}")
            if sha256_of_file(full) != item["sha256"]:
                raise ValueError(f"Hash mismatch (corrupted?): {item['archive_path']}")

        if not manifest.get("items"):
            raise ValueError("Package contains no items.")

        export = Export.query.get(job.export_id)
        final_path = os.path.join(current_app.config["EXPORTS_DIR"], f"{export.id}.zip")
        os.makedirs(os.path.dirname(final_path), exist_ok=True)
        os.replace(zip_path, final_path)

        archive_sha256 = sha256_of_file(final_path)
        with open(final_path + ".sha256", "w") as f:
            f.write(f"{archive_sha256}  {os.path.basename(final_path)}\n")

        export.status = ExportStatus.COMPLETE
        export.file_path = final_path
        export.file_size_bytes = os.path.getsize(final_path)
        export.sha256 = archive_sha256
        export.manifest_json = json.dumps(manifest)
        export.source_os = manifest.get("source_os")
        export.completed_at = datetime.utcnow()

        job.status = AgentJobStatus.COMPLETE
        job.completed_at = datetime.utcnow()
        db.session.commit()
        log_action(job.user_id, "agent_export_completed", detail=job.id)

        return jsonify({"status": "complete", "item_count": len(manifest["items"]),
                         "size_bytes": export.file_size_bytes, "sha256": archive_sha256})

    except (ValueError, OSError, json.JSONDecodeError) as e:
        export = Export.query.get(job.export_id)
        if export:
            export.status = ExportStatus.FAILED
            export.error_message = str(e)
        job.status = AgentJobStatus.FAILED
        job.error_message = str(e)
        db.session.commit()
        log_action(job.user_id, "agent_export_failed", detail=str(e))
        return jsonify({"error": str(e)}), 400

    finally:
        import shutil
        shutil.rmtree(work_dir, ignore_errors=True)


@agent_bp.route("/api/<job_id>/download-package")
def api_download_package(job_id):
    job = _authenticate(job_id)
    if job.kind != AgentJobKind.IMPORT:
        abort(400)

    config = json.loads(job.config_json)
    source_export = Export.query.get_or_404(config["source_export_id"])
    if not source_export.file_path or not os.path.exists(source_export.file_path):
        abort(404)

    job.status = AgentJobStatus.CONNECTED
    db.session.commit()
    return send_file(source_export.file_path, as_attachment=True, download_name="package.zip")


@agent_bp.route("/api/<job_id>/complete", methods=["POST"])
def api_complete(job_id):
    job = _authenticate(job_id)
    if job.kind != AgentJobKind.IMPORT:
        return jsonify({"error": "This job isn't an import job"}), 400

    payload = request.get_json(silent=True) or {}
    restored_files = payload.get("restored_files", 0)
    warnings = payload.get("warnings", [])

    import_job = ImportJob.query.get(job.import_job_id)
    if import_job:
        import_job.status = ImportStatus.COMPLETE
        import_job.target_os = job.agent_os
        import_job.warnings_json = json.dumps(warnings)
        import_job.log_text = f"Restored {restored_files} file(s) via agent."
        import_job.completed_at = datetime.utcnow()

    job.status = AgentJobStatus.COMPLETE
    job.completed_at = datetime.utcnow()
    db.session.commit()
    log_action(job.user_id, "agent_import_completed", detail=job.id)
    return jsonify({"status": "complete"})


@agent_bp.route("/api/<job_id>/fail", methods=["POST"])
def api_fail(job_id):
    job = _authenticate(job_id)
    payload = request.get_json(silent=True) or {}
    message = payload.get("message", "Agent reported an unspecified failure.")

    job.status = AgentJobStatus.FAILED
    job.error_message = message

    if job.kind == AgentJobKind.EXPORT and job.export_id:
        export = Export.query.get(job.export_id)
        if export:
            export.status = ExportStatus.FAILED
            export.error_message = message
    elif job.kind == AgentJobKind.IMPORT and job.import_job_id:
        import_job = ImportJob.query.get(job.import_job_id)
        if import_job:
            import_job.status = ImportStatus.FAILED
            import_job.error_message = message

    db.session.commit()
    log_action(job.user_id, "agent_job_failed", detail=f"{job.id}: {message}")
    return jsonify({"status": "acknowledged"})


@agent_bp.route("/api/<job_id>/progress", methods=["POST"])
def api_progress(job_id):
    """
    Live progress updates from the agent — a plain-English message plus
    an optional percent complete. Appended to the job's running log so
    the status page can show a growing, human-readable transcript
    instead of just a single current state.
    """
    job = _authenticate(job_id)
    payload = request.get_json(silent=True) or {}
    message = (payload.get("message") or "").strip()
    percent = payload.get("percent")

    if message:
        timestamp = datetime.utcnow().strftime("%H:%M:%S")
        line = f"[{timestamp}] {message}"
        job.log_text = f"{job.log_text}\n{line}" if job.log_text else line

    if isinstance(percent, (int, float)):
        job.progress_percent = max(0, min(100, int(percent)))

    db.session.commit()
    return jsonify({"status": "ok"})
