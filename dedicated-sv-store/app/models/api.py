import hashlib
import secrets

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


def _generate_key():
    return f"dsv_{secrets.token_urlsafe(32)}"


def hash_key(raw_key):
    return hashlib.sha256(raw_key.encode("utf-8")).hexdigest()


class ApiKey(db.Model, TimestampMixin):
    __tablename__ = "api_keys"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    seller_id = db.Column(db.Integer, db.ForeignKey("seller_profiles.id"))
    name = db.Column(db.String(100), nullable=False)
    key_prefix = db.Column(db.String(12), nullable=False, index=True)
    key_hash = db.Column(db.String(64), unique=True, nullable=False)
    scopes = db.Column(db.JSON, default=list)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    last_used_at = db.Column(db.DateTime(timezone=True))
    revoked_at = db.Column(db.DateTime(timezone=True))
    rate_limit_per_minute = db.Column(db.Integer, default=120)

    user = db.relationship("User")
    seller = db.relationship("SellerProfile")

    @classmethod
    def generate(cls, user_id, name, scopes=None, seller_id=None):
        raw_key = _generate_key()
        instance = cls(
            user_id=user_id,
            seller_id=seller_id,
            name=name,
            key_prefix=raw_key[:12],
            key_hash=hash_key(raw_key),
            scopes=scopes or [],
        )
        return instance, raw_key

    def has_scope(self, scope):
        return not self.scopes or scope in self.scopes

    def is_valid(self):
        return self.is_active and self.revoked_at is None


class ApiLog(db.Model):
    __tablename__ = "api_logs"

    id = db.Column(db.Integer, primary_key=True)
    api_key_id = db.Column(db.Integer, db.ForeignKey("api_keys.id"))
    method = db.Column(db.String(10), nullable=False)
    path = db.Column(db.String(500), nullable=False)
    status_code = db.Column(db.Integer)
    ip_address = db.Column(db.String(45))
    duration_ms = db.Column(db.Integer)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    api_key = db.relationship("ApiKey")


class Webhook(db.Model, TimestampMixin):
    __tablename__ = "webhooks"

    id = db.Column(db.Integer, primary_key=True)
    seller_id = db.Column(db.Integer, db.ForeignKey("seller_profiles.id"))
    owner_user_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    url = db.Column(db.String(500), nullable=False)
    secret = db.Column(db.String(128), nullable=False)
    events = db.Column(db.JSON, default=list)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    seller = db.relationship("SellerProfile")
    owner = db.relationship("User")

    def subscribes_to(self, event_name):
        return not self.events or event_name in self.events


class WebhookDelivery(db.Model):
    __tablename__ = "webhook_deliveries"

    id = db.Column(db.Integer, primary_key=True)
    webhook_id = db.Column(db.Integer, db.ForeignKey("webhooks.id"), nullable=False)
    event = db.Column(db.String(100), nullable=False)
    payload = db.Column(db.JSON)
    status_code = db.Column(db.Integer)
    success = db.Column(db.Boolean, default=False, nullable=False)
    attempt = db.Column(db.Integer, default=1, nullable=False)
    error = db.Column(db.Text)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    delivered_at = db.Column(db.DateTime(timezone=True))

    webhook = db.relationship("Webhook")
