import json
import re
from datetime import datetime, timezone
from app.extensions import db


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return slug or "layout"


# What a brand new kiosk (or a layout that's been "reset to default") looks
# like. Deliberately close to the original scan-only dashboard so resetting
# never leaves a kiosk broken — it's the same screen Builder Mode started
# from, just expressed as components.
DEFAULT_LAYOUT_COMPONENTS = [
    {"id": "hdr-1", "type": "header", "size": "full", "visible": True,
     "settings": {"title": "Welcome", "subtitle": "Scan an item to remove stock", "show_logout": True}},
    {"id": "scan-1", "type": "scan_panel", "size": "full", "visible": True,
     "settings": {"hint": "Waiting for scan…"}},
    {"id": "sum-1", "type": "stock_summary", "size": "full", "visible": True,
     "settings": {"show_total_items": True, "show_low_stock": True, "show_out_of_stock": True}},
]


class DashboardLayout(db.Model):
    """
    A named kiosk layout. Each layout carries TWO component trees:

    - draft_components  — what Builder Mode is currently editing
    - published_components — what kiosks actually render

    Saving in the builder only ever touches the draft. Nothing a kiosk
    displays changes until an admin explicitly hits Publish, which copies
    draft -> published. This is what gives "draft vs published" and lets an
    admin safely experiment without live-editing a shop-floor screen.
    """
    __tablename__ = "dashboard_layouts"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    slug = db.Column(db.String(96), unique=True, nullable=False, index=True)

    # NULL = applies to every kiosk that has no more specific layout
    # assigned. A specific value pins this layout to one kiosk "device"
    # name (see kiosk/state.py's terminal["device"]), so different kiosk
    # use-cases (e.g. a tool-cage terminal vs a consumables terminal) can
    # each run their own layout.
    target_device = db.Column(db.String(64), nullable=True, index=True)
    is_default = db.Column(db.Boolean, default=False, nullable=False)

    draft_components = db.Column(db.Text, nullable=False)
    published_components = db.Column(db.Text, nullable=True)
    published_at = db.Column(db.DateTime, nullable=True)

    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )

    created_by = db.relationship("User", foreign_keys=[created_by_id])

    # ── Helpers ────────────────────────────────────────────────────────────
    @property
    def draft(self) -> list:
        try:
            return json.loads(self.draft_components) if self.draft_components else []
        except (TypeError, ValueError):
            return []

    @draft.setter
    def draft(self, components: list):
        self.draft_components = json.dumps(components)

    @property
    def published(self) -> list | None:
        if not self.published_components:
            return None
        try:
            return json.loads(self.published_components)
        except (TypeError, ValueError):
            return None

    @property
    def has_unpublished_changes(self) -> bool:
        return self.draft_components != self.published_components

    @property
    def status(self) -> str:
        if not self.published_components:
            return "draft"
        return "modified" if self.has_unpublished_changes else "published"

    def publish(self):
        self.published_components = self.draft_components
        self.published_at = datetime.now(timezone.utc)

    def reset_to_default(self):
        self.draft = DEFAULT_LAYOUT_COMPONENTS

    def to_dict(self, include_components: bool = True) -> dict:
        data = {
            "id": self.id,
            "name": self.name,
            "slug": self.slug,
            "target_device": self.target_device,
            "is_default": self.is_default,
            "status": self.status,
            "published_at": self.published_at.isoformat() if self.published_at else None,
            "created_by": self.created_by.username if self.created_by else None,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }
        if include_components:
            data["draft_components"] = self.draft
            data["published_components"] = self.published
        return data

    def __repr__(self):
        return f"<DashboardLayout {self.name} [{self.status}]>"
