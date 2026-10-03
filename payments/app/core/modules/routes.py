import os

from flask import Blueprint, render_template, request, redirect, url_for, flash, current_app
from flask_login import login_required, current_user

from app.extensions import db
from app.core.modules.models import ModuleRecord, ModuleLogEntry
from app.core.modules import loader
from app.core.storage.service import save_upload, file_path
from app.core.audit.service import log_action

modules_bp = Blueprint("modules", __name__, url_prefix="/modules", template_folder="../../templates/modules")


@modules_bp.route("/")
@login_required
def index():
    records = ModuleRecord.query.order_by(ModuleRecord.name).all()
    return render_template("modules/index.html", modules=records)


@modules_bp.route("/install", methods=["GET", "POST"])
@login_required
def install():
    if request.method == "POST":
        upload = request.files.get("module_zip")
        if not upload or not upload.filename:
            flash("Choose a module ZIP file first.", "error")
            return redirect(url_for("modules.install"))

        try:
            stored, path = save_upload(upload, purpose="module_zip", user=current_user)
            record = loader.install_from_zip(path, replace_existing=True)
            loader.enable(current_app._get_current_object(), record.id)
            log_action(current_user, "module.installed", target_type="module", target_id=record.id)
            flash(f"Module '{record.name}' installed and enabled.", "success")
            return redirect(url_for("modules.index"))
        except loader.ModuleInstallError as e:
            flash(f"Install failed: {e}", "error")
        except Exception as e:
            flash(f"Install failed: {e}", "error")

    return render_template("modules/install.html")


@modules_bp.route("/<module_id>/enable", methods=["POST"])
@login_required
def enable_module(module_id):
    try:
        loader.enable(current_app._get_current_object(), module_id)
        log_action(current_user, "module.enabled", target_type="module", target_id=module_id)
        flash("Module enabled.", "success")
    except loader.ModuleInstallError as e:
        flash(str(e), "error")
    return redirect(url_for("modules.index"))


@modules_bp.route("/<module_id>/disable", methods=["POST"])
@login_required
def disable_module(module_id):
    try:
        loader.disable(module_id)
        log_action(current_user, "module.disabled", target_type="module", target_id=module_id)
        flash("Module disabled.", "success")
    except loader.ModuleInstallError as e:
        flash(str(e), "error")
    return redirect(url_for("modules.index"))


@modules_bp.route("/<module_id>/uninstall", methods=["POST"])
@login_required
def uninstall_module(module_id):
    delete_data = request.form.get("delete_data") == "yes"
    try:
        loader.uninstall(module_id, delete_data=delete_data)
        log_action(current_user, "module.uninstalled", target_type="module", target_id=module_id)
        flash("Module uninstalled.", "success")
    except loader.ModuleInstallError as e:
        flash(str(e), "error")
    return redirect(url_for("modules.index"))


@modules_bp.route("/<module_id>/logs")
@login_required
def module_logs(module_id):
    logs = ModuleLogEntry.query.filter_by(module_id=module_id).order_by(
        ModuleLogEntry.created_at.desc()
    ).limit(200).all()
    record = db.session.get(ModuleRecord, module_id)
    return render_template("modules/logs.html", logs=logs, record=record)
