"""
Combined dashboard (spec's "Overall Goal" section) -- one call surfacing
everything management is meant to be able to answer at a glance:
replacement-candidate tools, open maintenance alerts, PPE/consumable
usage anomalies, and welding-wire project variances. Pure aggregation --
every dataset here is computed by app.reporting and already exposed
individually by its own blueprint; this just combines them.
"""
from flask import Blueprint, jsonify
from app.auth import permission_required
from app.reporting import (
    get_maintenance_alerts, get_replacement_candidate_tools,
    get_ppe_anomalies, get_wire_project_variances,
)

dashboard_bp = Blueprint("dashboard", __name__, url_prefix="/api/dashboard")


@dashboard_bp.route("/summary", methods=["GET"])
@permission_required("admin", "supervisor")
def dashboard_summary():
    maintenance_alerts = get_maintenance_alerts()
    replacement_candidates = get_replacement_candidate_tools()
    ppe_anomalies = get_ppe_anomalies()
    wire_variances = get_wire_project_variances()
    over_budget_projects = [r for r in wire_variances if r["over_budget"]]

    return jsonify({
        "maintenance_alerts": maintenance_alerts,
        "replacement_candidate_tools": replacement_candidates,
        "ppe_usage_anomalies": ppe_anomalies,
        "wire_project_variances": wire_variances,
        "counts": {
            "maintenance_alerts": len(maintenance_alerts),
            "replacement_candidate_tools": len(replacement_candidates),
            "ppe_usage_anomalies": len(ppe_anomalies),
            "projects_over_budget": len(over_budget_projects),
        },
    }), 200
