from datetime import datetime, timezone
from app.extensions import db


def utcnow():
    return datetime.now(timezone.utc)


class FivemServer(db.Model):
    """A customer's registered FiveM server. One server_token goes in
    server.cfg - CloudLoader uses it to fetch every attached, valid
    license automatically. No manual per-product config."""

    __tablename__ = "fivem_servers"

    id = db.Column(db.Integer, primary_key=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)

    name = db.Column(db.String(120), nullable=False)

    # High-entropy token, SHA-256'd for lookup (deterministic, indexable -
    # unlike bcrypt, which is intentionally slow and not meant for exact
    # lookups). Only the hash is stored; the raw token is shown once.
    token_hash = db.Column(db.String(64), unique=True, nullable=False, index=True)
    token_prefix = db.Column(db.String(12), nullable=False)  # shown in UI, e.g. "srv_9f2a"

    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    last_seen_at = db.Column(db.DateTime(timezone=True), nullable=True)

    owner = db.relationship("User", backref="fivem_servers")
    attachments = db.relationship("ServerLicense", backref="server", cascade="all, delete-orphan")


class ServerLicense(db.Model):
    """Join table: which licenses are attached to which server."""

    __tablename__ = "server_licenses"

    id = db.Column(db.Integer, primary_key=True)
    server_id = db.Column(db.Integer, db.ForeignKey("fivem_servers.id"), nullable=False, index=True)
    license_id = db.Column(db.Integer, db.ForeignKey("licenses.id"), nullable=False, index=True)

    added_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    channel = db.Column(db.String(20), default="stable", server_default=db.text("'stable'"), nullable=False)  # "stable" or "beta"

    license = db.relationship("License")

    __table_args__ = (db.UniqueConstraint("server_id", "license_id", name="uq_server_license"),)
