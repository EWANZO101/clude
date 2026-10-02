from flask import Blueprint, render_template, redirect, url_for, flash

from services import ssl_service
from utils.permissions import require_permission

ssl_bp = Blueprint("ssl", __name__, template_folder="templates")


@ssl_bp.route("/ssl")
@require_permission("ssl.view")
def index():
    installed = ssl_service.is_installed()
    certs = []
    error = None
    if installed:
        try:
            certs = ssl_service.get_certificates()
        except ssl_service.SSLServiceError as exc:
            error = str(exc)

    expiring_count = len([c for c in certs if c["status"] in ("expiring", "expired")])

    return render_template(
        "ssl_index.html",
        installed=installed,
        certs=certs,
        error=error,
        expiring_count=expiring_count,
    )


@ssl_bp.route("/ssl/renew", methods=["POST"])
@require_permission("ssl.manage")
def renew():
    try:
        output = ssl_service.renew_all()
        flash(output or "Renewal check complete — nothing was due for renewal.", "success")
    except ssl_service.SSLServiceError as exc:
        flash(str(exc), "error")
    return redirect(url_for("ssl.index"))
