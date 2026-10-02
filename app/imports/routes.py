import json
import os
import shutil
import tempfile
from datetime import datetime

from flask import (
    Blueprint, render_template, redirect, url_for, flash,
    current_app, abort,
)
from flask_login import login_required, current_user
from werkzeug.utils import secure_filename

from app.extensions import db
from app.models import ImportJob, ImportStatus
from app.imports.forms import NewImportForm
from app.imports.service import ImportService, ImportError_
from app.transport import build_transport, TransportError
from app.auth.routes import log_action

imports_bp = Blueprint("imports", __name__, url_prefix="/imports")


def _owned_import_or_404(import_id):
    job = ImportJob.query.get_or_404(import_id)
    if job.user_id != current_user.id and not current_user.is_admin():
        abort(404)
    return job


@imports_bp.route("/new", methods=["GET", "POST"])
@login_required
def new():
    form = NewImportForm()
    if form.validate_on_submit():
        filename = secure_filename(form.package_file.data.filename)
        job = ImportJob(
            user_id=current_user.id,
            source_filename=filename,
            target_path=form.target_path.data,
            status=ImportStatus.RUNNING,
        )
        db.session.add(job)
        db.session.commit()
        log_action(current_user.id, "import_started", detail=job.id)

        work_dir = tempfile.mkdtemp(prefix=f"import-{job.id}-")
        uploaded_path = os.path.join(work_dir, filename or "package.zip")
        form.package_file.data.save(uploaded_path)

        progress_log = []

        def progress_cb(msg):
            progress_log.append(msg)

        service = None
        try:
            transport = build_transport(form.connection_type.data, form.get_transport_config())
            service = ImportService(
                package_path=uploaded_path,
                target_path=form.target_path.data,
                work_dir=work_dir,
                db_target=form.get_db_target(),
                progress_cb=progress_cb,
                transport=transport,
            )
            service.connect()
            result = service.run()

            job.status = ImportStatus.COMPLETE
            job.target_os = result.target_os
            job.log_text = "\n".join(progress_log)
            job.warnings_json = json.dumps(result.warnings)
            job.completed_at = datetime.utcnow()
            db.session.commit()
            log_action(current_user.id, "import_completed", detail=job.id)
            flash(
                f"Import completed — {result.restored_files} file(s) restored.",
                "success",
            )

        except (ImportError_, TransportError) as e:
            job.status = ImportStatus.FAILED
            job.error_message = str(e)
            job.log_text = "\n".join(progress_log)
            db.session.commit()
            log_action(current_user.id, "import_failed", detail=str(e))
            flash(f"Import failed: {e}", "danger")

        except Exception as e:  # noqa: BLE001
            job.status = ImportStatus.FAILED
            job.error_message = f"Unexpected error: {e}"
            job.log_text = "\n".join(progress_log)
            db.session.commit()
            log_action(current_user.id, "import_failed", detail=str(e))
            flash("Import failed due to an unexpected error. Check the logs.", "danger")

        finally:
            if service is not None:
                try:
                    service.transport.close()
                except Exception:  # noqa: BLE001
                    pass
            shutil.rmtree(work_dir, ignore_errors=True)

        return redirect(url_for("imports.detail", import_id=job.id))

    return render_template("imports/new.html", form=form)


@imports_bp.route("/<import_id>")
@login_required
def detail(import_id):
    job = _owned_import_or_404(import_id)
    warnings = json.loads(job.warnings_json) if job.warnings_json else []
    log_lines = job.log_text.splitlines() if job.log_text else []
    return render_template("imports/detail.html", job=job, warnings=warnings, log_lines=log_lines)


@imports_bp.route("/<import_id>/delete", methods=["POST"])
@login_required
def delete(import_id):
    job = _owned_import_or_404(import_id)
    db.session.delete(job)
    db.session.commit()
    log_action(current_user.id, "import_deleted", detail=import_id)
    flash("Import record deleted.", "info")
    return redirect(url_for("main.dashboard"))


@imports_bp.route("/")
@login_required
def list_imports():
    jobs = ImportJob.query.filter_by(user_id=current_user.id).order_by(
        ImportJob.created_at.desc()
    ).all()
    return render_template("imports/list.html", jobs=jobs)
