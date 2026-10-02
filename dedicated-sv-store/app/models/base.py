import uuid
from datetime import datetime, timezone

from app.extensions import db


def utcnow():
    return datetime.now(timezone.utc)


class TimestampMixin:
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at = db.Column(
        db.DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )


def gen_uuid():
    return str(uuid.uuid4())


class UUIDPkMixin:
    """Mixin for models that should be addressed externally (API) by UUID
    rather than a sequential integer, to avoid leaking record counts / order.
    """

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
