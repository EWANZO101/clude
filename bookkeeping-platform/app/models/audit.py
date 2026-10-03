import uuid
from datetime import datetime
from app.extensions import db


def gen_uuid():
    return str(uuid.uuid4())


class AuditLog(db.Model):
    """Append-only record of important actions. Nothing in the application
    updates or deletes rows in this table — it is the system's memory of
    what happened, and it must survive even if the record it describes is
    later voided or archived."""

    __tablename__ = "audit_logs"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)

    action = db.Column(db.String(100), nullable=False)          # e.g. "journal_entry.posted"
    entity_type = db.Column(db.String(50), nullable=False)      # e.g. "JournalEntry"
    entity_id = db.Column(db.String(36), nullable=True)

    previous_value = db.Column(db.Text, nullable=True)          # JSON string, or None
    new_value = db.Column(db.Text, nullable=True)                # JSON string, or None
    ip_address = db.Column(db.String(45), nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)

    user = db.relationship("User")


def record_audit(business_id, action, entity_type, entity_id=None,
                  previous_value=None, new_value=None, user_id=None, ip_address=None):
    import json

    def _serialize(v):
        if v is None:
            return None
        if isinstance(v, str):
            return v
        try:
            return json.dumps(v, default=str)
        except TypeError:
            return str(v)

    entry = AuditLog(
        business_id=business_id,
        user_id=user_id,
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        previous_value=_serialize(previous_value),
        new_value=_serialize(new_value),
        ip_address=ip_address,
    )
    db.session.add(entry)
    return entry
