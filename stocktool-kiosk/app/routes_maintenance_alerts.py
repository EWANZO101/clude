"""
Maintenance Alerts (spec item 2) -- flags tools that have been sitting
in a maintenance level too long. Built entirely on top of Part 1's
Tool.maintenance_level and the open ToolMaintenanceEvent (ended_at is
None while a tool is in maintenance) -- no new history model needed,
just a per-level threshold and a query.
"""
from flask import Blueprint, request, jsonify
from app.models import db, MaintenanceAlertThreshold, ToolMaintenanceEvent
from app.auth import permission_required
from app.reporting import get_maintenance_alerts

maintenance_alerts_bp = Blueprint("maintenance_alerts", __name__)


@maintenance_alerts_bp.route("/api/tools/alerts", methods=["GET"])
def maintenance_alerts():
    """Every tool currently in maintenance longer than its level's
    threshold. Message mirrors the spec example: 'Tool has been in
    Maintenance Level 2 for 3 days.'"""
    return jsonify(get_maintenance_alerts()), 200


@maintenance_alerts_bp.route("/api/admin/maintenance-thresholds", methods=["GET"])
@permission_required("admin", "supervisor")
def list_thresholds():
    """Configured thresholds, plus the defaults that'd apply to any
    level not explicitly configured yet (levels 1-5 shown as a guide)."""
    configured = {row.level: row.threshold_hours for row in MaintenanceAlertThreshold.query.all()}
    levels_in_use = {e.level for e in ToolMaintenanceEvent.query.with_entities(ToolMaintenanceEvent.level).distinct()}
    all_levels = sorted(set(configured) | levels_in_use | {1, 2, 3})
    return jsonify([
        {
            "level": level,
            "threshold_hours": configured.get(level, MaintenanceAlertThreshold.default_for_level(level)),
            "is_default": level not in configured,
        }
        for level in all_levels
    ]), 200


@maintenance_alerts_bp.route("/api/admin/maintenance-thresholds", methods=["POST"])
@permission_required("admin", "supervisor")
def set_threshold():
    data = request.get_json(silent=True) or {}
    try:
        level = int(data.get("level"))
        hours = float(data.get("threshold_hours"))
    except (TypeError, ValueError):
        return jsonify({"error": "level (int) and threshold_hours (number) are required."}), 400
    if level < 1 or hours <= 0:
        return jsonify({"error": "level must be >= 1 and threshold_hours must be > 0."}), 400

    row = MaintenanceAlertThreshold.set_threshold_hours(level, hours)
    db.session.commit()
    return jsonify(row.to_dict()), 200
