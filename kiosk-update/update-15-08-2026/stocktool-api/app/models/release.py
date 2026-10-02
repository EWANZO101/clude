from datetime import datetime, timezone
from app.extensions import db


class ReleaseVersion(db.Model):
    """A published kiosk-v2 desktop release. The desktop app polls
    /api/updates/latest and compares against its own version string."""
    __tablename__ = "release_versions"

    id = db.Column(db.Integer, primary_key=True)
    version = db.Column(db.String(32), unique=True, nullable=False)  # e.g. "2.1.0"
    channel = db.Column(db.String(20), nullable=False, default="stable", index=True)  # stable | beta
    download_url = db.Column(db.String(500), nullable=False)
    checksum_sha256 = db.Column(db.String(64), nullable=False)
    release_notes = db.Column(db.Text, nullable=True)
    min_supported_version = db.Column(db.String(32), nullable=True)  # older clients must upgrade first
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    published_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), nullable=False)

    def to_dict(self) -> dict:
        return {
            "version": self.version,
            "channel": self.channel,
            "download_url": self.download_url,
            "checksum_sha256": self.checksum_sha256,
            "release_notes": self.release_notes,
            "min_supported_version": self.min_supported_version,
            "published_at": self.published_at.isoformat() if self.published_at else None,
        }
