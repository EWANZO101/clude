from app.extensions import db
from app.models.notification import Notification


def notify(user_id, type_, title, body=None, link=None):
    n = Notification(user_id=user_id, type=type_, title=title, body=body, link=link)
    db.session.add(n)
    return n
