import os
import shutil
import tempfile
from datetime import datetime

from flask import (
    Blueprint, render_template, redirect, url_for, flash,
    current_app, send_file, abort,
)
from flask_login import login_required, current_user

from app.extensions import db
from app.models import Export, ExportStatus
from app.exports.forms import NewExportForm
from app.exports.service import ExportService, ExportError, detect_host_os
from app.transport import build_transport, TransportError
from app.auth.routes import log_action

exports_bp = Blueprint("exports", __name__, url_prefix="/exports")


def _owned_export_or_404(export_id):
    export = Export.query.get_or_404(export_id)
    if export.user_id != current_user.id and not current_user.is_admin():
        abort(404)
    return export


@exports_bp.route("/new", methods=["GET", "POST"])
@login_required
def new():
    form = NewExportForm()
    if form.validate_on_submit():
        export = Export(
            user_id=current_user.id,
            source_os=detect_host_os(),
            status=ExportStatus.RUNNING,
        )
        db.session.add(export)
        db.session.commit()
        log_action(current_user.id, "export_started", detail=export.id)

        work_dir = tempfile.mkdtemp(prefix=f"export-{export.id}-")
        output_path = os.path.join(
            current_app.config["EXPORTS_DIR"], f"{export.id}.zip"
        )

        progress_log = []

        def progress_cb(msg):
            progress_log.append(msg)

        service = None
        try:
            transport = build_transport(form.connection_type.data, form.get_transport_config())
            service = ExportService(
                install_path=form.install_path.data,
                work_dir=work_dir,
                db_config=form.get_db_config(),
                include_uploads=form.include_uploads.data,
                extra_paths=form.get_extra_paths(),
                progress_cb=progress_cb,
                transport=transport,
            )
            service.connect()
            service.validate_install_path()
            service.collect()
            service.dump_database()
            result = service.finalize(
                output_path,
                extra_meta={"exported_by": current_user.email, "export_id": export.id},
            )

            export.status = ExportStatus.COMPLETE
            export.file_path = result.archive_path
            export.file_size_bytes = result.archive_size_bytes
            export.sha256 = result.archive_sha256
            export.manifest_json = _safe_json(result.manifest)
            export.completed_at = datetime.utcnow()
            db.session.commit()
            log_action(current_user.id, "export_completed", detail=export.id)
            flash("Export completed successfully.", "success")

        except (ExportError, TransportError) as e:
            export.status = ExportStatus.FAILED
            export.error_message = str(e)
            db.session.commit()
            log_action(current_user.id, "export_failed", detail=str(e))
            flash(f"Export failed: {e}", "danger")

        except Exception as e:  # noqa: BLE001 - surface unexpected errors, don't leak a 500
            export.status = ExportStatus.FAILED
            export.error_message = f"Unexpected error: {e}"
            db.session.commit()
            log_action(current_user.id, "export_failed", detail=str(e))
            flash("Export failed due to an unexpected error. Check the logs.", "danger")

        finally:
            if service is not None:
                try:
                    service.transport.close()
                except Exception:  # noqa: BLE001
                    pass
            shutil.rmtree(work_dir, ignore_errors=True)

        return redirect(url_for("exports.detail", export_id=export.id))

    return render_template("exports/new.html", form=form)


@exports_bp.route("/<export_id>")
@login_required
def detail(export_id):
    export = _owned_export_or_404(export_id)
    manifest = _load_json(export.manifest_json)
    return render_template("exports/detail.html", export=export, manifest=manifest)


@exports_bp.route("/<export_id>/download")
@login_required
def download(export_id):
    export = _owned_export_or_404(export_id)
    if export.status != ExportStatus.COMPLETE or not export.file_path:
        flash("This export isn't ready to download.", "warning")
        return redirect(url_for("exports.detail", export_id=export_id))

    if not os.path.exists(export.file_path):
        flash("Export file is missing on disk.", "danger")
        return redirect(url_for("exports.detail", export_id=export_id))

    log_action(current_user.id, "export_downloaded", detail=export_id)
    return send_file(
        export.file_path,
        as_attachment=True,
        download_name=f"snailycad-export-{export_id}.zip",
    )


@exports_bp.route("/<export_id>/delete", methods=["POST"])
@login_required
def delete(export_id):
    export = _owned_export_or_404(export_id)

    if export.file_path and os.path.exists(export.file_path):
        os.remove(export.file_path)
    sidecar = f"{export.file_path}.sha256" if export.file_path else None
    if sidecar and os.path.exists(sidecar):
        os.remove(sidecar)

    db.session.delete(export)
    db.session.commit()
    log_action(current_user.id, "export_deleted", detail=export_id)
    flash("Export deleted.", "info")
    return redirect(url_for("main.dashboard"))


def _safe_json(data):
    import json
    return json.dumps(data)


def _load_json(text):
    import json
    if not text:
        return None
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return None
