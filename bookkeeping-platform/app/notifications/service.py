from app.extensions import db
from app.models.notification import Notification, NotificationPreference, PREFERENCE_FIELD_BY_TYPE
from app.models.business import Membership


def _user_wants(user_id, notif_type):
    field = PREFERENCE_FIELD_BY_TYPE.get(notif_type)
    if field is None:
        return True  # unknown type: fail open, don't silently drop it
    pref = NotificationPreference.query.get(user_id)
    if pref is None:
        return True  # no row yet = defaults = everything on
    return getattr(pref, field, True)


def notify_user(user_id, notif_type, title, message, business_id=None, link=None):
    if not _user_wants(user_id, notif_type):
        return None
    n = Notification(
        user_id=user_id, business_id=business_id, type=notif_type,
        title=title, message=message, link=link,
    )
    db.session.add(n)
    db.session.commit()
    return n


def notify_business_admins(business_id, notif_type, title, message, link=None):
    """Notifies every owner/admin of a business — the people actually
    positioned to act on a financial or system warning for it."""
    memberships = Membership.query.filter(
        Membership.business_id == business_id, Membership.role.in_(["owner", "admin"])
    ).all()
    created = []
    for m in memberships:
        n = notify_user(m.user_id, notif_type, title, message, business_id=business_id, link=link)
        if n:
            created.append(n)
    return created
