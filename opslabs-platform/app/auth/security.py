from datetime import datetime, timedelta

from sqlalchemy.exc import IntegrityError

from ..extensions import db
from ..models import LoginAttempt

FAIL_MAX = 5
LOCK_MINUTES = 15


def is_locked(key):
    la = LoginAttempt.query.filter_by(key=key).first()
    return bool(la and la.locked_until and datetime.utcnow() < la.locked_until)


def record_failure(key):
    la = LoginAttempt.query.filter_by(key=key).first()
    if not la:
        la = LoginAttempt(key=key, failed_count=0)
        db.session.add(la)
        try:
            db.session.flush()
        except IntegrityError:
            db.session.rollback()
            la = LoginAttempt.query.filter_by(key=key).first()

    if la.locked_until and datetime.utcnow() >= la.locked_until:
        la.failed_count = 0
        la.locked_until = None

    la.failed_count += 1
    if la.failed_count >= FAIL_MAX:
        la.locked_until = datetime.utcnow() + timedelta(minutes=LOCK_MINUTES)
        la.failed_count = 0
    db.session.commit()


def clear_failures(key):
    LoginAttempt.query.filter_by(key=key).delete()
    db.session.commit()


def client_ip(request):
    return request.remote_addr or '0.0.0.0'
