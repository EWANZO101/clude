import logging

from app.extensions import db
from app.core.notifications.models import Notification, NotificationPreference
from app.core.email.service import send_email as _send_email_real

logger = logging.getLogger(__name__)


def send_email(to_address, subject, body):
    """Delegates to the real SMTP-backed email service (app.core.email.service),
    which itself falls back to logging if SMTP isn't configured."""
    _send_email_real(to_address, subject, body)


def notify(user, kind, title, body="", module_id=None, url=None):
    pref = NotificationPreference.query.filter_by(user_id=user.id, kind=kind).first()
    in_app = pref.in_app if pref else True
    email = pref.email if pref else False

    if in_app:
        db.session.add(Notification(user_id=user.id, kind=kind, title=title, body=body,
                                     module_id=module_id, url=url))
        db.session.commit()

    if email:
        send_email(user.email, title, body)
