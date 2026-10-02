from flask import Blueprint, render_template, request
from flask_login import login_required

from app.core.audit.models import AuditLog

audit_bp = Blueprint("audit", __name__, url_prefix="/audit", template_folder="../../templates/audit")


@audit_bp.route("/")
@login_required
def index():
    page = request.args.get("page", 1, type=int)
    pagination = AuditLog.query.order_by(AuditLog.created_at.desc()).paginate(page=page, per_page=50, error_out=False)
    return render_template("audit/index.html", pagination=pagination)
