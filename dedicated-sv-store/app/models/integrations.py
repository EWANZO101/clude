import enum

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class ConnectionStatus(str, enum.Enum):
    UNTESTED = "untested"
    CONNECTED = "connected"
    FAILED = "failed"


class HardwareApiConnection(db.Model, TimestampMixin):
    """A configured link to an external hardware-catalog provider, used by
    the hardware sync background job to import/update CPU/RAM/storage/etc.
    specs. See app/integrations/adapters.py for the adapter interface —
    swapping providers never touches the hardware catalog models."""

    __tablename__ = "hardware_api_connections"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(150), nullable=False)
    provider_type = db.Column(db.String(50), default="generic_rest", nullable=False)
    base_url = db.Column(db.String(500), nullable=False)
    api_key = db.Column(db.String(255))
    sync_frequency_hours = db.Column(db.Integer, default=24, nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    status = db.Column(db.Enum(ConnectionStatus, name="hw_connection_status"), default=ConnectionStatus.UNTESTED)
    last_checked_at = db.Column(db.DateTime(timezone=True))
    last_error = db.Column(db.String(500))
    last_synced_at = db.Column(db.DateTime(timezone=True))

    def __repr__(self):
        return f"<HardwareApiConnection {self.name}>"


class SellerApiConnection(db.Model, TimestampMixin):
    """A configured link to a seller's own external inventory/pricing
    system, so the platform can pull their listings automatically (the
    reverse direction from a seller using our own /api/v1 with an API key)."""

    __tablename__ = "seller_api_connections"

    id = db.Column(db.Integer, primary_key=True)
    seller_id = db.Column(db.Integer, db.ForeignKey("seller_profiles.id"), nullable=False)
    name = db.Column(db.String(150), nullable=False)
    provider_type = db.Column(db.String(50), default="generic_rest", nullable=False)
    base_url = db.Column(db.String(500), nullable=False)
    api_key = db.Column(db.String(255))
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    status = db.Column(db.Enum(ConnectionStatus, name="seller_connection_status"), default=ConnectionStatus.UNTESTED)
    last_checked_at = db.Column(db.DateTime(timezone=True))
    last_error = db.Column(db.String(500))
    last_synced_at = db.Column(db.DateTime(timezone=True))

    seller = db.relationship("SellerProfile")

    def __repr__(self):
        return f"<SellerApiConnection {self.name}>"
