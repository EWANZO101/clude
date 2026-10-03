"""
Cross-cutting reporting helpers -- the logic behind the "Overall Goal"
section of the spec (replacement candidates, maintenance alerts, PPE/
consumable usage anomalies, wire project variance). Factored out here
so both the per-item/per-tool endpoints and the combined dashboard
endpoint (routes_dashboard.py) compute things exactly one way.
"""
from datetime import datetime, timezone
from app.models import (
    db, Tool, ToolMaintenanceEvent, MaintenanceAlertThreshold,
    Item, IssuanceEvent, WireTransaction, WireProjectBudget,
)


def _now():
    return datetime.now(timezone.utc)


def _aware(dt):
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def get_maintenance_alerts():
    open_events = ToolMaintenanceEvent.query.filter_by(ended_at=None).all()
    now = _now()
    alerts = []
    for event in open_events:
        tool = db.session.get(Tool, event.tool_id)
        if not tool:
            continue
        elapsed_hours = max(0.0, (now - _aware(event.started_at)).total_seconds() / 3600.0)
        threshold_hours = MaintenanceAlertThreshold.get_threshold_hours(event.level)
        if elapsed_hours < threshold_hours:
            continue
        elapsed_days = elapsed_hours / 24.0
        alerts.append({
            "tool_id": tool.id, "tool_name": tool.name, "level": event.level,
            "reason": event.reason,
            "started_at": event.started_at.isoformat() if event.started_at else None,
            "elapsed_hours": round(elapsed_hours, 1), "elapsed_days": round(elapsed_days, 1),
            "threshold_hours": threshold_hours,
            "message": f"'{tool.name}' has been in Maintenance Level {event.level} for {elapsed_days:.1f} days.",
        })
    alerts.sort(key=lambda a: a["elapsed_hours"], reverse=True)
    return alerts


def get_replacement_candidate_tools():
    candidates = []
    for tool in Tool.query.all():
        summary = tool.usage_summary()
        if summary["is_replacement_candidate"]:
            candidates.append({"tool": tool.to_dict(), "summary": summary})
    candidates.sort(key=lambda r: -r["summary"]["total_maintenance_cost"])
    return candidates


def compute_item_anomalies(item):
    """Per-employee anomalies for one item: an employee re-issued the
    item sooner than item.normal_interval_days after their last
    issuance. Returns [] if the item has no normal_interval_days set --
    there's nothing to compare against."""
    if not item.normal_interval_days:
        return []
    events = (IssuanceEvent.query.filter_by(item_id=item.id)
              .order_by(IssuanceEvent.employee.asc(), IssuanceEvent.created_at.asc()).all())
    by_employee = {}
    for e in events:
        by_employee.setdefault(e.employee, []).append(e)

    anomalies = []
    for employee, emp_events in by_employee.items():
        for prev, cur in zip(emp_events, emp_events[1:]):
            gap_days = (_aware(cur.created_at) - _aware(prev.created_at)).total_seconds() / 86400.0
            if gap_days < item.normal_interval_days:
                anomalies.append({
                    "item_id": item.id, "item_name": item.name, "employee": employee,
                    "gap_days": round(gap_days, 1), "normal_interval_days": item.normal_interval_days,
                    "previous_issuance": prev.created_at.isoformat() if prev.created_at else None,
                    "this_issuance": cur.created_at.isoformat() if cur.created_at else None,
                    "message": (
                        f"{employee} received '{item.name}' again after only {gap_days:.1f} days "
                        f"(normally every {item.normal_interval_days:.0f} days)."
                    ),
                })
    return anomalies


def get_ppe_anomalies():
    anomalies = []
    for item in Item.query.filter_by(category=Item.CATEGORY_PPE).all():
        anomalies.extend(compute_item_anomalies(item))
    anomalies.sort(key=lambda a: a["gap_days"])
    return anomalies


def get_wire_project_variances():
    """Every project with either wire usage or a budget set, and its
    variance (spec item 7). Positive variance = over budget."""
    projects = set(p for (p,) in db.session.query(WireTransaction.project).distinct() if p)
    projects |= set(p.project for p in WireProjectBudget.query.all())

    rows = []
    for project in sorted(projects):
        total_consumed = (
            db.session.query(db.func.coalesce(db.func.sum(WireTransaction.consumed), 0.0))
            .filter(WireTransaction.project == project).scalar()
        )
        budget = db.session.get(WireProjectBudget, project)
        target = budget.target_weight if budget else None
        variance = round(total_consumed - target, 4) if target is not None else None
        rows.append({
            "project": project, "total_consumed": round(total_consumed, 4),
            "target_weight": target, "variance": variance,
            "over_budget": bool(target is not None and total_consumed > target),
        })
    rows.sort(key=lambda r: (r["variance"] is None, -(r["variance"] or 0)))
    return rows
