from flask import Blueprint, render_template, redirect, url_for, flash
from flask_login import login_required, current_user
from app.models.audit import AuditLog
from app.models.integrity import IntegrityCheckRun
from app.accounting.integrity import run_integrity_check
from app.models.notification import TYPE_AUDIT_WARNING
from app.notifications.service import notify_business_admins
from app.businesses.decorators import require_current_business, require_permission

audit_bp = Blueprint("audit", __name__, template_folder="../templates/audit")


@audit_bp.route("/log")
@login_required
@require_current_business
@require_permission("view")
def audit_log(business):
    entries = (
        AuditLog.query.filter_by(business_id=business.id)
        .order_by(AuditLog.created_at.desc())
        .limit(200)
        .all()
    )
    return render_template("audit/log.html", entries=entries)


@audit_bp.route("/integrity")
@login_required
@require_current_business
@require_permission("view")
def integrity_history(business):
    runs = (
        IntegrityCheckRun.query.filter_by(business_id=business.id)
        .order_by(IntegrityCheckRun.started_at.desc())
        .limit(20)
        .all()
    )
    return render_template("audit/integrity_history.html", runs=runs)


@audit_bp.route("/integrity/run", methods=["POST"])
@login_required
@require_current_business
@require_permission("view")
def integrity_run(business):
    run = run_integrity_check(business_id=business.id)
    if run.issue_count:
        flash(f"Integrity check found {run.issue_count} issue(s). Review below.", "error")
        notify_business_admins(
            business.id, TYPE_AUDIT_WARNING,
            title=f"Self-audit found {run.issue_count} issue(s)",
            message="Run at " + run.started_at.strftime("%Y-%m-%d %H:%M") + ". Review the details before your next reporting cycle.",
            link=f"/audit/integrity/{run.id}",
        )
    else:
        flash("Integrity check found no issues.", "success")
    return redirect(url_for("audit.integrity_detail", run_id=run.id))


@audit_bp.route("/integrity/<run_id>")
@login_required
@require_current_business
@require_permission("view")
def integrity_detail(business, run_id):
    run = IntegrityCheckRun.query.filter_by(id=run_id, business_id=business.id).first_or_404()
    return render_template("audit/integrity_detail.html", run=run)
