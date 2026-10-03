import io
import json
import zipfile
from datetime import datetime

from flask import Blueprint, render_template, Response, send_file
from flask_login import login_required, current_user

from app.core.export.registry import available_exporters, run_exporter
from app.core.audit.service import log_action

export_bp = Blueprint("export", __name__, url_prefix="/export", template_folder="../../templates/export")


def _core_account_export(user):
    """Core (non-module) export: profile, settings, dashboard layout —
    the data that already lives in app.core rather than an installed module."""
    from app.core.database.models import DashboardWidget

    profile = {
        "name": user.name, "email": user.email, "country": user.country,
        "currency": user.currency, "timezone": user.timezone,
        "created_at": user.created_at.isoformat() if getattr(user, "created_at", None) else None,
    }
    widgets = DashboardWidget.query.filter_by(user_id=user.id).order_by(DashboardWidget.position).all()
    dashboard = [{"widget_key": w.widget_key, "position": w.position, "enabled": w.enabled} for w in widgets]

    payload = {"profile": profile, "dashboard_layout": dashboard}
    return {"account.json": (json.dumps(payload, indent=2, default=str), "application/json")}


@export_bp.route("/")
@login_required
def index():
    exporters = available_exporters()
    return render_template("export/index.html", exporters=exporters)


@export_bp.route("/<key>/download")
@login_required
def download_module(key):
    if key == "account":
        files = _core_account_export(current_user)
    else:
        files = run_exporter(key, current_user)

    if not files:
        return Response("Nothing to export.", status=404)

    log_action(current_user, "export.downloaded", target_type="module", target_id=key)

    if len(files) == 1:
        filename, (content, mimetype) = next(iter(files.items()))
        return Response(content, mimetype=mimetype,
                         headers={"Content-Disposition": f"attachment; filename={filename}"})

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for filename, (content, _mimetype) in files.items():
            zf.writestr(filename, content)
    buf.seek(0)
    return send_file(buf, as_attachment=True, download_name=f"{key}_export.zip", mimetype="application/zip")


@export_bp.route("/all/download")
@login_required
def download_all():
    """Full-system export: one ZIP containing every module's export plus
    core account data, each in its own subfolder."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for filename, (content, _mimetype) in _core_account_export(current_user).items():
            zf.writestr(f"account/{filename}", content)

        for key in available_exporters():
            files = run_exporter(key, current_user)
            for filename, (content, _mimetype) in files.items():
                zf.writestr(f"{key}/{filename}", content)

        manifest = {
            "exported_at": datetime.utcnow().isoformat() + "Z",
            "user": current_user.email,
            "modules_included": list(available_exporters().keys()) + ["account"],
        }
        zf.writestr("manifest.json", json.dumps(manifest, indent=2))

    buf.seek(0)
    log_action(current_user, "export.full_system_downloaded")
    stamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    return send_file(buf, as_attachment=True, download_name=f"export_{stamp}.zip", mimetype="application/zip")
