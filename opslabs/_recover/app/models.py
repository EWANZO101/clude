"""Database models for OpsLab Systems."""
from datetime import datetime, timedelta
import secrets
from . import db
from flask_login import UserMixin
from werkzeug.security import check_password_hash, generate_password_hash


# ─── Status helpers ───────────────────────────────────────────────────
# Five-stage lifecycle plus legacy "open"/"closed" maps.
TICKET_STATUS_FLOW = ["seen", "pending", "in_progress", "resolved", "denied"]
TICKET_STATUS_VALID = TICKET_STATUS_FLOW + ["open", "closed"]  # accept legacy too

# Visual styles (kept in one place so bot + web stay in sync)
STATUS_META = {
    "seen":        {"label": "Seen",        "emoji": "👀", "color": "#71b7ff", "step": 1, "terminal": False},
    "pending":     {"label": "Pending",     "emoji": "⏳", "color": "#f59e0b", "step": 2, "terminal": False},
    "in_progress": {"label": "In Progress", "emoji": "🛠️", "color": "#2196f3", "step": 3, "terminal": False},
    "resolved":    {"label": "Resolved",    "emoji": "✅", "color": "#22c55e", "step": 4, "terminal": True},
    "denied":      {"label": "Denied",      "emoji": "🚫", "color": "#ef4444", "step": 4, "terminal": True},
    # Legacy aliases — render same as new equivalents
    "open":        {"label": "Open",        "emoji": "🔓", "color": "#22c55e", "step": 1, "terminal": False},
    "closed":      {"label": "Closed",      "emoji": "🔒", "color": "#94a3b8", "step": 4, "terminal": True},
}

# Migration helper: legacy → new
def normalise_status(s: str) -> str:
    if s == "open":
        return "seen"
    if s == "closed":
        return "resolved"
    return s if s in TICKET_STATUS_FLOW else "seen"


# ---------------------------------------------------------------------------
# USERS / AUTH
# ---------------------------------------------------------------------------
class User(UserMixin, db.Model):
    __tablename__ = "users"
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), unique=True, nullable=False, index=True)
    email = db.Column(db.String(120), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(20), default="user", nullable=False)
    discord_id = db.Column(db.String(40), nullable=True, index=True)
    discord_username = db.Column(db.String(80), nullable=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login_at = db.Column(db.DateTime, nullable=True)

    tickets = db.relationship("Ticket", backref="owner", lazy="dynamic",
                              foreign_keys="Ticket.user_id")
    messages = db.relationship("TicketMessage", backref="author", lazy="dynamic")
    reset_tokens = db.relationship("PasswordResetToken", backref="user",
                                   cascade="all, delete-orphan")

    def set_password(self, pw):
        self.password_hash = generate_password_hash(pw)

    def check_password(self, pw):
        return check_password_hash(self.password_hash, pw)

    @property
    def is_admin(self):
        return self.role == "admin"

    @property
    def is_staff(self):
        return self.role in ("staff", "admin")

    def __repr__(self):
        return f"<User {self.username} ({self.role})>"


class PasswordResetToken(db.Model):
    __tablename__ = "password_reset_tokens"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    token = db.Column(db.String(64), unique=True, nullable=False, index=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, nullable=False)
    used = db.Column(db.Boolean, default=False, nullable=False)

    @staticmethod
    def create_for(user, hours=2):
        tok = PasswordResetToken(
            user_id=user.id,
            token=secrets.token_urlsafe(32),
            expires_at=datetime.utcnow() + timedelta(hours=hours),
        )
        db.session.add(tok)
        db.session.commit()
        return tok

    @property
    def is_valid(self):
        return (not self.used) and datetime.utcnow() < self.expires_at


# ---------------------------------------------------------------------------
# COMPANIES
# ---------------------------------------------------------------------------
class Company(db.Model):
    __tablename__ = "companies"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    slug = db.Column(db.String(80), unique=True, nullable=False, index=True)
    tagline = db.Column(db.String(255), nullable=True)
    description = db.Column(db.Text, nullable=True)
    logo_url = db.Column(db.String(500), nullable=True)
    accent_color = db.Column(db.String(20), default="#2196f3")
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    categories = db.relationship("TicketCategory", backref="company",
                                 cascade="all, delete-orphan", lazy="dynamic")
    tickets = db.relationship("Ticket", backref="company", lazy="dynamic")

    def __repr__(self):
        return f"<Company {self.name}>"


# ---------------------------------------------------------------------------
# TICKETS
# ---------------------------------------------------------------------------
class TicketCategory(db.Model):
    __tablename__ = "ticket_categories"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    description = db.Column(db.String(255), nullable=True)
    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    tickets = db.relationship("Ticket", backref="category", lazy="dynamic")


class Ticket(db.Model):
    __tablename__ = "tickets"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=False)
    category_id = db.Column(db.Integer, db.ForeignKey("ticket_categories.id"), nullable=True)

    subject = db.Column(db.String(200), nullable=False)
    # 5-stage flow: seen, pending, in_progress, resolved, denied
    # Legacy "open" and "closed" are still accepted and mapped on read.
    status = db.Column(db.String(20), default="seen", nullable=False)
    priority = db.Column(db.String(20), default="normal", nullable=False)
    resolution_note = db.Column(db.Text, nullable=True)  # why denied / resolved

    # Discord linkage
    discord_channel_id = db.Column(db.String(40), nullable=True, index=True)

    assigned_to_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    assigned_to = db.relationship("User", foreign_keys=[assigned_to_id])

    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow,
                           onupdate=datetime.utcnow, index=True)
    closed_at = db.Column(db.DateTime, nullable=True)

    messages = db.relationship("TicketMessage", backref="ticket",
                               cascade="all, delete-orphan",
                               order_by="TicketMessage.created_at")

    # ── Helpers ────────────────────────────────────────────────────────
    @property
    def status_normalised(self) -> str:
        return normalise_status(self.status)

    @property
    def status_meta(self) -> dict:
        return STATUS_META.get(self.status, STATUS_META["seen"])

    @property
    def is_terminal(self) -> bool:
        return self.status_meta.get("terminal", False)

    @property
    def progress_percent(self) -> int:
        """How far through the lifecycle (0-100), used for the progress bar."""
        step = self.status_meta.get("step", 1)
        # 4 stages, 4 fenceposts: 25/50/75/100
        if self.status == "denied":
            return 100
        return min(100, step * 25)

    def to_dict(self, include_messages=False):
        meta = self.status_meta
        d = {
            "id": self.id,
            "subject": self.subject,
            "status": self.status,
            "status_label": meta["label"],
            "status_emoji": meta["emoji"],
            "status_color": meta["color"],
            "status_step": meta["step"],
            "is_terminal": self.is_terminal,
            "progress_percent": self.progress_percent,
            "priority": self.priority,
            "resolution_note": self.resolution_note,
            "category": self.category.name if self.category else None,
            "company": self.company.name if self.company else None,
            "owner": self.owner.username if self.owner else None,
            "assigned_to": self.assigned_to.username if self.assigned_to else None,
            "discord_channel_id": self.discord_channel_id,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "closed_at": self.closed_at.isoformat() if self.closed_at else None,
        }
        if include_messages:
            d["messages"] = [m.to_dict() for m in self.messages]
        return d


class TicketMessage(db.Model):
    __tablename__ = "ticket_messages"
    id = db.Column(db.Integer, primary_key=True)
    ticket_id = db.Column(db.Integer, db.ForeignKey("tickets.id"), nullable=False, index=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    source = db.Column(db.String(20), default="web", nullable=False)
    discord_message_id = db.Column(db.String(40), nullable=True, index=True)
    discord_author = db.Column(db.String(120), nullable=True)

    body = db.Column(db.Text, nullable=False)
    is_internal = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)

    def to_dict(self):
        return {
            "id": self.id,
            "body": self.body,
            "source": self.source,
            "author": (self.author.username if self.author
                       else self.discord_author or "system"),
            "author_role": (self.author.role if self.author else "discord"),
            "is_internal": self.is_internal,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }
