import re
from datetime import datetime, timezone
from app.extensions import db


# Plain many-to-many association tables — a category has no extra data
# about the link itself (no "primary category" flag), and an item/tool can
# sit in as many categories as an admin wants, per the spec.
item_categories = db.Table(
    "item_categories",
    db.Column("item_id", db.Integer, db.ForeignKey("items.id", ondelete="CASCADE"), primary_key=True),
    db.Column("category_id", db.Integer, db.ForeignKey("categories.id", ondelete="CASCADE"), primary_key=True),
)

tool_categories = db.Table(
    "tool_categories",
    db.Column("tool_id", db.Integer, db.ForeignKey("tools.id", ondelete="CASCADE"), primary_key=True),
    db.Column("category_id", db.Integer, db.ForeignKey("categories.id", ondelete="CASCADE"), primary_key=True),
)


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    return slug or "category"


class Category(db.Model):
    __tablename__ = "categories"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), nullable=False)
    slug = db.Column(db.String(96), unique=True, nullable=False, index=True)
    icon = db.Column(db.String(48), nullable=True)           # Font Awesome class, e.g. "fa-solid fa-screwdriver-wrench"
    color = db.Column(db.String(16), nullable=True)          # hex, e.g. "#4f46e5"
    sort_order = db.Column(db.Integer, default=0, nullable=False, index=True)

    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(timezone.utc),
        onupdate=lambda: datetime.now(timezone.utc),
    )

    # ── Relationships ──────────────────────────────────────────────────────
    # backref names ("categories") are added on Item/Tool themselves so
    # item.categories / tool.categories both work without collision here.
    items = db.relationship("Item", secondary=item_categories, back_populates="categories")
    tools = db.relationship("Tool", secondary=tool_categories, back_populates="categories")

    def to_dict(self, counts: bool = True) -> dict:
        data = {
            "id": self.id,
            "name": self.name,
            "slug": self.slug,
            "icon": self.icon,
            "color": self.color,
            "sort_order": self.sort_order,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }
        if counts:
            data["item_count"] = sum(1 for i in self.items if i.is_active)
            data["tool_count"] = sum(1 for t in self.tools if t.is_active)
        return data

    def __repr__(self):
        return f"<Category {self.name}>"
