from flask import Blueprint, render_template, request
from flask_login import login_required, current_user

from app.models import LocalUser, Item, Tool, Project, WireSpool, ActivityEvent
from app.blueprints.items import LOW_STOCK_THRESHOLD

bp = Blueprint("dashboard", __name__)

# Rough display metadata per ActivityEvent.event_type — icon glyph + color
# variable name, keyed loosely (a prefix match covers 'wire_issue' /
# 'wire_empty' / etc. without hand-listing every one). Purely cosmetic;
# an unrecognized/future event_type still renders fine with the default.
EVENT_STYLE = {
    "item_adjust": ("±", "var(--blue)"),
    "tool_checkout": ("↗", "var(--orange)"),
    "tool_checkin": ("↘", "var(--green)"),
    "wire_bulk_add": ("+", "var(--green)"),
    "wire_issue": ("↗", "var(--orange)"),
    "wire_empty": ("●", "var(--muted)"),
    "wire_return": ("↘", "var(--green)"),
    "wire_scrap": ("✕", "var(--red)"),
    "project_activate": ("▶", "var(--accent)"),
    "project_close": ("■", "var(--muted)"),
    "project_reopen": ("▶", "var(--accent)"),
    "stock_audit_start": ("⚠", "var(--orange)"),
    "stock_audit_reconcile": ("✓", "var(--accent)"),
    "stock_audit_dismiss": ("–", "var(--muted)"),
    "stock_audit_close": ("✓", "var(--green)"),
}
DEFAULT_EVENT_STYLE = ("•", "var(--muted)")


@bp.route("/")
@login_required
def index():
    total_users = LocalUser.query.filter_by(is_active=True).count()
    low_stock_count = Item.query.filter(
        Item.deleted_at.is_(None), Item.quantity < LOW_STOCK_THRESHOLD
    ).count()
    tools_available = Tool.query.filter_by(status="available", deleted_at=None).count()
    tools_out = Tool.query.filter_by(status="checked_out", deleted_at=None).count()
    active_projects = Project.query.filter_by(status="active").count()
    wire_in_stock = WireSpool.query.filter_by(status="in_stock").count()
    recent_activity = ActivityEvent.query.order_by(ActivityEvent.created_at.desc()).limit(15).all()
    return render_template(
        "dashboard/index.html",
        total_users=total_users, low_stock_count=low_stock_count,
        tools_available=tools_available, tools_out=tools_out,
        active_projects=active_projects, wire_in_stock=wire_in_stock,
        recent_activity=recent_activity, event_style=_event_style,
    )


def _event_style(event_type: str):
    return EVENT_STYLE.get(event_type, DEFAULT_EVENT_STYLE)


@bp.route("/activity")
@login_required
def activity():
    event_type = request.args.get("type", "")
    query = ActivityEvent.query
    if event_type:
        query = query.filter_by(event_type=event_type)
    entries = query.order_by(ActivityEvent.created_at.desc()).limit(300).all()
    all_types = sorted({row[0] for row in ActivityEvent.query.with_entities(ActivityEvent.event_type).distinct().all()})
    return render_template(
        "dashboard/activity.html", entries=entries, all_types=all_types,
        event_type=event_type, event_style=_event_style,
    )
