from functools import wraps
from flask import Blueprint, render_template, abort
from flask_login import login_required, current_user
from app.models.backup import Backup
from app.models.audit import AuditLog
from app.models.integrity import IntegrityCheckRun
from app.models.user import User
from app.models.business import Business

admin_bp = Blueprint("admin", __name__, template_folder="../templates/admin")


def require_platform_admin(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not current_user.is_authenticated or not current_user.is_platform_admin:
            abort(403)
        return view(*args, **kwargs)
    return wrapped


@admin_bp.route("/")
@login_required
@require_platform_admin
def dashboard():
    recent_backups = Backup.query.order_by(Backup.started_at.desc()).limit(10).all()
    recent_audit = AuditLog.query.order_by(AuditLog.created_at.desc()).limit(20).all()
    recent_integrity_runs = IntegrityCheckRun.query.order_by(IntegrityCheckRun.started_at.desc()).limit(10).all()
    user_count = User.query.count()
    business_count = Business.query.count()
    failing_backups = Backup.query.filter_by(status="failed").count()
    open_issue_runs = [r for r in recent_integrity_runs if r.issue_count > 0]

    return render_template(
        "admin/dashboard.html",
        recent_backups=recent_backups,
        recent_audit=recent_audit,
        recent_integrity_runs=recent_integrity_runs,
        user_count=user_count,
        business_count=business_count,
        failing_backups=failing_backups,
        open_issue_runs=open_issue_runs,
    )
