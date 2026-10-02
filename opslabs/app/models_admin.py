"""
═══════════════════════════════════════════════════════════════════════════
  models_admin.py — extra models for the admin content editor & settings
═══════════════════════════════════════════════════════════════════════════
  Drop this file in `/root/opslabs/app/` next to models.py, then add ONE
  line to app/__init__.py to import it. (Instructions in the deploy notes.)

  Two new tables:
    site_content   — JSON-flexible content blocks for the live homepage
    settings       — global key/value config (brand, smtp, integrations…)

  Both have helper class-methods so other code can read them as if they
  were dicts — and the values can be edited from the new admin pages.
═══════════════════════════════════════════════════════════════════════════
"""
import json
from datetime import datetime
from . import db


class SiteContent(db.Model):
    """One row per editable homepage section.

    `data` is a flexible JSON blob — keys differ per section. The template
    reads `SiteContent.get('hero').data['headline']` etc.

    Default content is seeded on first boot so the homepage works out of
    the box; admins then edit those rows via /admin/content.
    """
    __tablename__ = "site_content"

    id = db.Column(db.Integer, primary_key=True)
    section = db.Column(db.String(50), unique=True, nullable=False, index=True)
    data_json = db.Column(db.Text, nullable=False, default="{}")
    updated_at = db.Column(db.DateTime, default=datetime.utcnow,
                           onupdate=datetime.utcnow)
    updated_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    updated_by = db.relationship("User", foreign_keys=[updated_by_id])

    # ── JSON convenience ──────────────────────────────────────────────
    @property
    def data(self) -> dict:
        try:
            return json.loads(self.data_json or "{}")
        except Exception:
            return {}

    @data.setter
    def data(self, value: dict) -> None:
        self.data_json = json.dumps(value or {}, ensure_ascii=False)

    # ── Helpers ───────────────────────────────────────────────────────
    @classmethod
    def get(cls, section: str) -> "SiteContent":
        row = cls.query.filter_by(section=section).first()
        if row is None:
            row = cls(section=section, data_json="{}")
            db.session.add(row)
            db.session.commit()
        return row

    @classmethod
    def get_data(cls, section: str, default: dict | None = None) -> dict:
        row = cls.query.filter_by(section=section).first()
        if row is None:
            return dict(default or {})
        # merge defaults under the saved data
        merged = dict(default or {})
        merged.update(row.data)
        return merged

    @classmethod
    def set_data(cls, section: str, data: dict, user_id: int | None = None) -> "SiteContent":
        row = cls.get(section)
        row.data = data
        if user_id:
            row.updated_by_id = user_id
        db.session.commit()
        return row

    def __repr__(self):
        return f"<SiteContent {self.section}>"


class Setting(db.Model):
    """Global key/value config — brand, SMTP, Discord IDs, feature flags."""
    __tablename__ = "settings"

    id = db.Column(db.Integer, primary_key=True)
    key = db.Column(db.String(80), unique=True, nullable=False, index=True)
    value = db.Column(db.Text, nullable=True)
    kind = db.Column(db.String(20), default="string", nullable=False)
    # "string" | "int" | "bool" | "color" | "json" | "secret"
    category = db.Column(db.String(40), default="general", nullable=False, index=True)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    @classmethod
    def get(cls, key: str, default=None):
        row = cls.query.filter_by(key=key).first()
        if row is None:
            return default
        return cls._cast(row.value, row.kind, default)

    @classmethod
    def set(cls, key: str, value, kind: str = "string", category: str = "general"):
        row = cls.query.filter_by(key=key).first()
        if row is None:
            row = cls(key=key, kind=kind, category=category)
            db.session.add(row)
        if kind == "json":
            row.value = json.dumps(value, ensure_ascii=False) if value is not None else None
        elif kind == "bool":
            row.value = "1" if value in (True, "1", "true", "yes", "on") else "0"
        elif value is None:
            row.value = None
        else:
            row.value = str(value)
        row.kind = kind
        row.category = category
        db.session.commit()
        return row

    @classmethod
    def _cast(cls, raw, kind, default):
        if raw is None:
            return default
        if kind == "bool":
            return raw in ("1", "true", "True", "yes", "on")
        if kind == "int":
            try: return int(raw)
            except (TypeError, ValueError): return default
        if kind == "json":
            try: return json.loads(raw)
            except (TypeError, ValueError): return default
        return raw

    @classmethod
    def all_by_category(cls):
        out: dict[str, list[Setting]] = {}
        for s in cls.query.order_by(cls.category, cls.key).all():
            out.setdefault(s.category, []).append(s)
        return out

    def __repr__(self):
        return f"<Setting {self.key}={self.value!r}>"
