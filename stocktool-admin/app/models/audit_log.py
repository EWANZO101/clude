from datetime import datetime, timezone
from app.extensions import db


class AuditAction:
    # Items
    ITEM_CREATED = "item_created"
    ITEM_UPDATED = "item_updated"
    ITEM_DELETED = "item_deleted"
    ITEM_STOCK_ADJUSTED = "item_stock_adjusted"

    # Tools
    TOOL_CREATED = "tool_created"
    TOOL_UPDATED = "tool_updated"
    TOOL_DELETED = "tool_deleted"
    TOOL_CHECKED_OUT = "tool_checked_out"
    TOOL_CHECKED_IN = "tool_checked_in"
    TOOL_STATUS_CHANGED = "tool_status_changed"

    # Users
    USER_CREATED = "user_created"
    USER_UPDATED = "user_updated"
    USER_DELETED = "user_deleted"
    USER_LOGIN = "user_login"
    USER_LOGOUT = "user_logout"
    USER_PASSWORD_CHANGED = "user_password_changed"

    # Projects
    PROJECT_CREATED = "project_created"
    PROJECT_UPDATED = "project_updated"
    PROJECT_DELETED = "project_deleted"

    # Kiosk (stocktool-kiosk, badge-scan shop-floor terminal)
    KIOSK_LOGIN = "kiosk_login"
    KIOSK_QUICK_REMOVE = "kiosk_quick_remove"

    # System
    SYSTEM_INIT = "system_init"


class AuditLog(db.Model):
    __tablename__ = "audit_logs"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True, index=True)

    action = db.Column(db.String(64), nullable=False, index=True)
    entity_type = db.Column(db.String(32), nullable=True)   # "tool", "item", "user"
    entity_id = db.Column(db.Integer, nullable=True)
    entity_name = db.Column(db.String(128), nullable=True)

    detail = db.Column(db.Text, nullable=True)               # Human-readable summary
    ip_address = db.Column(db.String(64), nullable=True)

    # Structured fields — previously this info only lived inside the free-text
    # `detail` string, which made filtering/reporting on "how much stock moved"
    # or "which device did this" impossible without parsing prose.
    quantity_delta = db.Column(db.Integer, nullable=True)     # signed; +/- stock change
    device = db.Column(db.String(64), nullable=True)          # kiosk name, or "mobile"

    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), index=True)

    # ── Relationships ──────────────────────────────────────────────────────
    user = db.relationship("User", back_populates="audit_logs")

    # ── Helpers ────────────────────────────────────────────────────────────
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "user_id": self.user_id,
            "username": self.user.username if self.user else "System",
            "action": self.action,
            "entity_type": self.entity_type,
            "entity_id": self.entity_id,
            "entity_name": self.entity_name,
            "detail": self.detail,
            "ip_address": self.ip_address,
            "quantity_delta": self.quantity_delta,
            "device": self.device,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }

    def __repr__(self):
        return f"<AuditLog {self.action} by user={self.user_id}>"
