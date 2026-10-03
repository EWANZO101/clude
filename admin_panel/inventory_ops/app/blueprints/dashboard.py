from flask import Blueprint, render_template

from app.models import ItemType, InventoryItem, InventoryItemEvent, AuditLogEntry
from app.permissions import require_login_if_enabled

bp = Blueprint("dashboard", __name__)


@bp.route("/")
@require_login_if_enabled
def index():
    types = ItemType.query.filter_by(deleted_at=None).order_by(ItemType.name).all()
    counts = {
        t.key: InventoryItem.query.filter_by(item_type_key=t.key, deleted_at=None).count()
        for t in types
    }
    total_items = InventoryItem.query.filter_by(deleted_at=None).count()
    checked_out = InventoryItem.query.filter(
        InventoryItem.deleted_at.is_(None), InventoryItem.checked_out_by_name.isnot(None)
    ).count()
    recent_events = InventoryItemEvent.query.order_by(InventoryItemEvent.occurred_at.desc()).limit(10).all()
    recent_activity = AuditLogEntry.query.order_by(AuditLogEntry.created_at.desc()).limit(10).all()
    return render_template(
        "dashboard/index.html", types=types, counts=counts, total_items=total_items,
        checked_out=checked_out, recent_events=recent_events, recent_activity=recent_activity,
    )
