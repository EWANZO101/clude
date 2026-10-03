"""Sidebar/nav-entry ordering business logic — the "sidebar builder"
feature (see /root/.claude/plans/sprightly-meandering-whisper.md).
Shared by the human-facing admin.py route (dragging the list on this
kiosk terminal's own /admin panel) and sync_api.py's /sidebar/reorder
route (relayed by the Agent on behalf of the remote Client
Portal/Admin Panel — see agent/commands.py's sidebar_reorder command).
One implementation of "what does a valid reorder look like" rather than
two copies that could drift apart, same reasoning role_admin.py gives.
"""
from app.extensions import db
from app.models import NavEntry, AuditLogEntry


def _audit(actor: str, action: str, detail: str = None):
    db.session.add(AuditLogEntry(actor=actor, action=action, detail=detail))


def get_state() -> list:
    rows = NavEntry.query.order_by(NavEntry.section, NavEntry.sort_order).all()
    return [r.to_sync_dict() for r in rows]


def reorder(actor: str, order: list) -> tuple:
    """order: the full new ordering, listed keys first (in the order
    given); any key not mentioned keeps its relative order after them.
    Section is left as whatever it already was — this only ever changes
    sort_order."""
    if not order:
        return False, "order must be a non-empty list of keys."

    existing_keys = {row.key for row in NavEntry.query.all()}
    unknown = [k for k in order if k not in existing_keys]
    if unknown:
        return False, f"Unknown nav entry key(s): {', '.join(unknown)}"

    position = 0
    for key in order:
        NavEntry.query.get(key).sort_order = position
        position += 1
    remaining = NavEntry.query.filter(~NavEntry.key.in_(order)).order_by(NavEntry.sort_order).all()
    for row in remaining:
        row.sort_order = position
        position += 1

    _audit(actor, "sidebar_reorder", detail=", ".join(order[:10]) + ("..." if len(order) > 10 else ""))
    db.session.commit()
    return True, "Sidebar order updated."
