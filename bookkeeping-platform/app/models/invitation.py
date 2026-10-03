import uuid
import secrets
from datetime import datetime, timedelta
from app.extensions import db

STATUS_PENDING = "pending"
STATUS_ACCEPTED = "accepted"
STATUS_REVOKED = "revoked"
STATUS_EXPIRED = "expired"


def gen_uuid():
    return str(uuid.uuid4())


def gen_token():
    return secrets.token_urlsafe(32)


class Invitation(db.Model):
    """An invite for an accountant/bookkeeper/employee to join a business at
    a given role. Accepting one creates a Membership — it never grants
    access directly, so a business owner always sees exactly what was
    invited before it becomes real access."""

    __tablename__ = "invitations"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    invited_by_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)

    email = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(32), nullable=False)
    token = db.Column(db.String(64), unique=True, nullable=False, default=gen_token)
    status = db.Column(db.String(20), nullable=False, default=STATUS_PENDING)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, default=lambda: datetime.utcnow() + timedelta(days=14))

    business = db.relationship("Business")
    invited_by = db.relationship("User")

    def is_valid(self):
        return self.status == STATUS_PENDING and datetime.utcnow() < self.expires_at
