import uuid
from datetime import datetime
from app.extensions import db

STATUS_SUCCESS = "success"
STATUS_FAILURE = "failure"


def gen_uuid():
    return str(uuid.uuid4())


class IntegrationConfig(db.Model):
    """One row per (business, provider). Holds whether it's enabled and its
    provider-specific settings. `secret` is stored as plain text here for
    Phase 5 clarity — a real deployment would put this behind a secrets
    manager / envelope encryption, never a plain DB column."""

    __tablename__ = "integration_configs"
    __table_args__ = (
        db.UniqueConstraint("business_id", "provider", name="uq_integration_business_provider"),
    )

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    provider = db.Column(db.String(50), nullable=False)  # 'bank_csv' | 'stripe' | ...
    is_enabled = db.Column(db.Boolean, default=False, nullable=False)
    secret = db.Column(db.String(255), nullable=True)  # e.g. webhook shared secret
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class IntegrationLog(db.Model):
    """Append-only record of every integration attempt, success or failure.
    This is what lets 'if one integration fails it should not bring down the
    entire system' be verified after the fact, not just asserted."""

    __tablename__ = "integration_logs"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=True)
    provider = db.Column(db.String(50), nullable=False)
    event = db.Column(db.String(100), nullable=False)
    status = db.Column(db.String(10), nullable=False)
    message = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
