import secrets
import hashlib
from datetime import datetime, timezone
from app.extensions import db


def _now():
    return datetime.now(timezone.utc)


class Installation(db.Model):
    """
    A registered kiosk-v2 desktop installation. The central API never
    stores this installation's business data (items/tools/projects stay
    on the existing per-tenant tables this same API already serves) —
    this table exists purely to authenticate and track the health of
    each desktop client talking to sync/update/config endpoints.
    """
    __tablename__ = "installations"

    id = db.Column(db.Integer, primary_key=True)
    installation_id = db.Column(db.String(36), unique=True, nullable=False, index=True)
    device_name = db.Column(db.String(120), nullable=True)
    app_version = db.Column(db.String(32), nullable=True)
    token_hash = db.Column(db.String(128), nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)
    last_seen_at = db.Column(db.DateTime, nullable=True)
    last_sync_at = db.Column(db.DateTime, nullable=True)

    @staticmethod
    def _hash_token(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    @classmethod
    def create_with_token(cls, installation_id: str, device_name: str, app_version: str):
        """Returns (installation, plaintext_token) — the plaintext token is
        shown to the caller exactly once, at registration time, same as
        an API key. Only its hash is ever stored."""
        token = secrets.token_urlsafe(32)
        inst = cls(
            installation_id=installation_id,
            device_name=device_name,
            app_version=app_version,
            token_hash=cls._hash_token(token),
        )
        db.session.add(inst)
        return inst, token

    @classmethod
    def find_by_token(cls, token: str):
        if not token:
            return None
        return cls.query.filter_by(token_hash=cls._hash_token(token), is_active=True).first()

    def touch(self):
        self.last_seen_at = _now()

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "installation_id": self.installation_id,
            "device_name": self.device_name,
            "app_version": self.app_version,
            "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "last_seen_at": self.last_seen_at.isoformat() if self.last_seen_at else None,
            "last_sync_at": self.last_sync_at.isoformat() if self.last_sync_at else None,
        }
