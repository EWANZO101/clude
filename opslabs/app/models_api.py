"""API key model (kept separate to keep models.py clean)."""
import secrets
import hashlib
from datetime import datetime
from . import db


class ApiKey(db.Model):
    __tablename__ = "api_keys"
    id = db.Column(db.Integer, primary_key=True)
    label = db.Column(db.String(120), nullable=False)
    # Store SHA256 of the raw key so a DB leak doesn't expose keys
    key_hash = db.Column(db.String(64), unique=True, nullable=False, index=True)
    prefix = db.Column(db.String(12), nullable=False)  # first ~8 chars for display
    scope = db.Column(db.String(20), default="read", nullable=False)  # read, write, admin
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_used_at = db.Column(db.DateTime, nullable=True)
    request_count = db.Column(db.Integer, default=0, nullable=False)

    @staticmethod
    def _hash(raw):
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    @classmethod
    def create(cls, label, scope, owner_id=None):
        raw = "ops_" + secrets.token_urlsafe(32)
        k = cls(
            label=label,
            key_hash=cls._hash(raw),
            prefix=raw[:10],
            scope=scope,
            owner_id=owner_id,
        )
        db.session.add(k)
        db.session.commit()
        return k, raw

    @classmethod
    def verify(cls, raw):
        if not raw:
            return None
        k = cls.query.filter_by(key_hash=cls._hash(raw), is_active=True).first()
        if k:
            k.last_used_at = datetime.utcnow()
            k.request_count = (k.request_count or 0) + 1
            db.session.commit()
        return k

    def can(self, required):
        """Scope hierarchy: admin > write > read."""
        order = {"read": 0, "write": 1, "admin": 2}
        return order.get(self.scope, 0) >= order.get(required, 0)
