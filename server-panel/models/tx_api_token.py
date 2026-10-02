import hashlib
import secrets
from datetime import datetime

from database import db


class TxApiToken(db.Model):
    """Bearer tokens for the txAdmin REST API (/tx/api/v1). Only a SHA-256
    of the token is stored; the plaintext is shown once when created."""

    __tablename__ = "tx_api_tokens"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    token_hash = db.Column(db.String(64), unique=True, nullable=False)
    prefix = db.Column(db.String(12), nullable=False)
    # Comma-separated instance ids this token may touch, or "*" for all.
    scope = db.Column(db.String(255), nullable=False, default="*")
    created_by = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    last_used_at = db.Column(db.DateTime, nullable=True)

    @staticmethod
    def hash(token):
        return hashlib.sha256(token.encode()).hexdigest()

    @staticmethod
    def generate():
        return "txp_" + secrets.token_urlsafe(32)

    def allows(self, inst_id):
        return self.scope == "*" or str(inst_id) in self.scope.split(",")

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "prefix": self.prefix, "scope": self.scope,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "last_used_at": self.last_used_at.isoformat() if self.last_used_at else None,
        }
