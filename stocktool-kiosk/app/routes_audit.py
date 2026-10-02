"""
Audit API -- everything here is gated to role='financial' specifically
(not 'admin'), per spec: this is a premium role separate from regular
admin access. See app/auth.py's permission_required().
"""
from datetime import date

from flask import Blueprint, jsonify, request

from app.auth import permission_required
from app.models import AuditRun
from app.audit_engine import run_day_audit, run_month_audit, run_year_audit

audit_bp = Blueprint("audit", __name__, url_prefix="/api/admin/audit")


@audit_bp.route("/runs", methods=["GET"])
@permission_required("financial", "admin")
def list_runs():
    period_type = request.args.get("period_type")
    q = AuditRun.query
    if period_type:
        if period_type not in AuditRun.PERIODS:
            return jsonify({"error": f"period_type must be one of {AuditRun.PERIODS}"}), 400
        q = q.filter_by(period_type=period_type)
    runs = q.order_by(AuditRun.period_key.desc()).limit(200).all()
    return jsonify({"runs": [r.to_dict() for r in runs]}), 200


@audit_bp.route("/runs/<int:run_id>", methods=["GET"])
@permission_required("financial", "admin")
def run_detail(run_id):
    run = AuditRun.query.get_or_404(run_id)
    data = run.to_dict()
    data["records"] = [r.to_dict() for r in run.records]
    return jsonify(data), 200


@audit_bp.route("/run-now", methods=["POST"])
@permission_required("financial", "admin")
def run_now():
    """Manual on-demand trigger -- e.g. a financial user who wants
    today's numbers immediately rather than waiting for the scheduler's
    next tick. Uses the exact same audit_engine functions the
    scheduler calls, so there's no separate code path to drift out of
    sync."""
    data = request.get_json(silent=True) or {}
    period_type = data.get("period_type", AuditRun.PERIOD_DAY)

    if period_type == AuditRun.PERIOD_DAY:
        target = date.today()
        if data.get("date"):
            target = date.fromisoformat(data["date"])
        run = run_day_audit(target, is_backfill=False)
        return jsonify(run.to_dict()), 200

    if period_type == AuditRun.PERIOD_MONTH:
        year = int(data.get("year", date.today().year))
        month = int(data.get("month", date.today().month))
        run = run_month_audit(year, month)
        if not run:
            return jsonify({"error": "No day audits exist for that month yet."}), 400
        return jsonify(run.to_dict()), 200

    if period_type == AuditRun.PERIOD_YEAR:
        year = int(data.get("year", date.today().year))
        run = run_year_audit(year)
        if not run:
            return jsonify({"error": "No month audits exist for that year yet."}), 400
        return jsonify(run.to_dict()), 200

    return jsonify({"error": f"period_type must be one of {AuditRun.PERIODS}"}), 400