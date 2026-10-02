"""
═══════════════════════════════════════════════════════════════════════════
  models_business.py — portal / CRM / projects / billing / shop models
═══════════════════════════════════════════════════════════════════════════
  Adds the data layer for the customer portal expansion. Import this once
  from app/__init__.py (next to `models_admin`) so the tables register on
  the SQLAlchemy metadata.

  Conventions kept consistent with models.py / models_admin.py:
    • `db` comes from the app package
    • timestamps are UTC (datetime.utcnow)
    • money is stored as INTEGER CENTS (avoid float rounding) — use the
      `.amount` / `.total` properties for display
    • string status fields + a *_META dict (mirrors TICKET STATUS_META)
═══════════════════════════════════════════════════════════════════════════
"""
import json
import secrets
from datetime import datetime, timedelta

from . import db


# ───────────────────────── shared status metadata ──────────────────────────
SERVICE_STATUS_META = {
    "active":    {"label": "Active",    "color": "#22c55e"},
    "pending":   {"label": "Pending",   "color": "#f59e0b"},
    "suspended": {"label": "Suspended", "color": "#ef4444"},
    "expired":   {"label": "Expired",   "color": "#94a3b8"},
}

# Ordered project lifecycle (spec §Job/Project Management → Status)
PROJECT_STAGES = [
    "submitted", "under_review", "approved", "planning", "in_progress",
    "awaiting_info", "testing", "client_review", "revision_requested",
    "deployment", "completed",
]
PROJECT_STAGE_META = {
    "submitted":          {"label": "Submitted",          "color": "#94a3b8", "pct": 5},
    "under_review":       {"label": "Under Review",        "color": "#71b7ff", "pct": 12},
    "approved":           {"label": "Approved",            "color": "#71b7ff", "pct": 20},
    "planning":           {"label": "Planning",            "color": "#2196f3", "pct": 30},
    "in_progress":        {"label": "In Progress",         "color": "#2196f3", "pct": 50},
    "awaiting_info":      {"label": "Awaiting Information", "color": "#f59e0b", "pct": 50},
    "testing":            {"label": "Testing",             "color": "#a855f7", "pct": 75},
    "client_review":      {"label": "Client Review",        "color": "#a855f7", "pct": 85},
    "revision_requested": {"label": "Revision Requested",  "color": "#f59e0b", "pct": 80},
    "deployment":         {"label": "Deployment",          "color": "#2196f3", "pct": 95},
    "completed":          {"label": "Completed",           "color": "#22c55e", "pct": 100},
}

APPOINTMENT_STATUS_META = {
    "requested":  {"label": "Requested",  "color": "#f59e0b"},
    "confirmed":  {"label": "Confirmed",  "color": "#22c55e"},
    "rescheduled":{"label": "Rescheduled","color": "#71b7ff"},
    "cancelled":  {"label": "Cancelled",  "color": "#ef4444"},
    "completed":  {"label": "Completed",  "color": "#94a3b8"},
}

INVOICE_STATUS_META = {
    "draft":    {"label": "Draft",    "color": "#94a3b8"},
    "sent":     {"label": "Sent",     "color": "#71b7ff"},
    "paid":     {"label": "Paid",     "color": "#22c55e"},
    "overdue":  {"label": "Overdue",  "color": "#ef4444"},
    "void":     {"label": "Void",     "color": "#64748b"},
    "refunded": {"label": "Refunded", "color": "#a855f7"},
}


def cents_to_str(cents: int, currency: str = "GBP") -> str:
    sym = {"GBP": "£", "USD": "$", "EUR": "€", "ZAR": "R"}.get(currency, "")
    return f"{sym}{(cents or 0) / 100:,.2f}"


# ═══════════════════════════════════ PROFILE / AUTH EXTRAS ══════════════════
class UserProfile(db.Model):
    """One-to-one extension of users (kept separate to avoid altering the
    existing users table). Avatar, phone, timezone, bio."""
    __tablename__ = "user_profiles"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), unique=True, nullable=False)
    display_name = db.Column(db.String(120), nullable=True)
    phone = db.Column(db.String(40), nullable=True)
    avatar_path = db.Column(db.String(500), nullable=True)
    timezone = db.Column(db.String(60), default="Europe/London", nullable=False)
    bio = db.Column(db.Text, nullable=True)
    email_verified = db.Column(db.Boolean, default=False, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    user = db.relationship("User", backref=db.backref("profile", uselist=False,
                                                       cascade="all, delete-orphan"))

    @classmethod
    def for_user(cls, user):
        row = cls.query.filter_by(user_id=user.id).first()
        if row is None:
            row = cls(user_id=user.id)
            db.session.add(row)
            db.session.commit()
        return row


class LoginEvent(db.Model):
    __tablename__ = "login_events"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    ip = db.Column(db.String(64), nullable=True)
    user_agent = db.Column(db.String(300), nullable=True)
    at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    user = db.relationship("User", backref=db.backref("login_events", lazy="dynamic"))


# ═══════════════════════════════════════════════ SERVICES ══════════════════
class Service(db.Model):
    """A thing the customer is paying for / using (hosting plan, retainer…)."""
    __tablename__ = "services"
    id = db.Column(db.Integer, primary_key=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=True)
    name = db.Column(db.String(160), nullable=False)
    description = db.Column(db.Text, nullable=True)
    status = db.Column(db.String(20), default="pending", nullable=False, index=True)
    price_cents = db.Column(db.Integer, default=0, nullable=False)
    currency = db.Column(db.String(3), default="GBP", nullable=False)
    billing_cycle = db.Column(db.String(20), default="monthly")  # monthly|yearly|one_off
    renews_at = db.Column(db.DateTime, nullable=True)
    stripe_subscription_id = db.Column(db.String(120), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    owner = db.relationship("User", backref=db.backref("services", lazy="dynamic"))

    @property
    def status_meta(self):
        return SERVICE_STATUS_META.get(self.status, SERVICE_STATUS_META["pending"])

    @property
    def price_display(self):
        return cents_to_str(self.price_cents, self.currency)


# ═══════════════════════════════════════════════ PROJECTS ══════════════════
class Project(db.Model):
    __tablename__ = "projects"
    id = db.Column(db.Integer, primary_key=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=True)
    assigned_staff_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    title = db.Column(db.String(200), nullable=False)
    summary = db.Column(db.Text, nullable=True)
    requirements = db.Column(db.Text, nullable=True)
    stage = db.Column(db.String(30), default="submitted", nullable=False, index=True)
    percent_complete = db.Column(db.Integer, default=0, nullable=False)
    estimated_completion = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    owner = db.relationship("User", foreign_keys=[owner_id],
                            backref=db.backref("projects", lazy="dynamic"))
    assigned_staff = db.relationship("User", foreign_keys=[assigned_staff_id])
    milestones = db.relationship("ProjectMilestone", backref="project",
                                 cascade="all, delete-orphan", lazy="dynamic",
                                 order_by="ProjectMilestone.position")
    events = db.relationship("ProjectEvent", backref="project",
                             cascade="all, delete-orphan", lazy="dynamic",
                             order_by="ProjectEvent.created_at.desc()")

    @property
    def stage_meta(self):
        return PROJECT_STAGE_META.get(self.stage, PROJECT_STAGE_META["submitted"])

    @property
    def effective_percent(self):
        # explicit value wins; otherwise fall back to the stage default
        return self.percent_complete or self.stage_meta.get("pct", 0)

    def log_event(self, kind, text, actor=None):
        ev = ProjectEvent(project_id=self.id, kind=kind, text=text,
                          actor_id=getattr(actor, "id", None))
        db.session.add(ev)
        return ev


class ProjectMilestone(db.Model):
    __tablename__ = "project_milestones"
    id = db.Column(db.Integer, primary_key=True)
    project_id = db.Column(db.Integer, db.ForeignKey("projects.id"), nullable=False, index=True)
    title = db.Column(db.String(200), nullable=False)
    position = db.Column(db.Integer, default=0)
    is_done = db.Column(db.Boolean, default=False, nullable=False)
    due_at = db.Column(db.DateTime, nullable=True)
    completed_at = db.Column(db.DateTime, nullable=True)


class ProjectEvent(db.Model):
    """Timeline entry: creation, staff/client updates, milestones, deploys."""
    __tablename__ = "project_events"
    id = db.Column(db.Integer, primary_key=True)
    project_id = db.Column(db.Integer, db.ForeignKey("projects.id"), nullable=False, index=True)
    actor_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    kind = db.Column(db.String(30), default="update")  # created|staff_update|client_update|milestone|deploy|stage_change
    text = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    actor = db.relationship("User")


# ═══════════════════════════════════════════ APPOINTMENTS ══════════════════
class Appointment(db.Model):
    """Times stored in UTC; render in Europe/London, 24h (see portal utils)."""
    __tablename__ = "appointments"
    id = db.Column(db.Integer, primary_key=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    staff_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    subject = db.Column(db.String(200), nullable=False)
    notes = db.Column(db.Text, nullable=True)
    starts_at = db.Column(db.DateTime, nullable=False, index=True)  # UTC
    ends_at = db.Column(db.DateTime, nullable=False)                # UTC
    status = db.Column(db.String(20), default="requested", nullable=False, index=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    owner = db.relationship("User", foreign_keys=[owner_id],
                            backref=db.backref("appointments", lazy="dynamic"))
    staff = db.relationship("User", foreign_keys=[staff_id])

    @property
    def status_meta(self):
        return APPOINTMENT_STATUS_META.get(self.status, APPOINTMENT_STATUS_META["requested"])

    @staticmethod
    def has_conflict(starts_at, ends_at, staff_id=None, exclude_id=None):
        """True if an active appointment overlaps [starts_at, ends_at)."""
        q = Appointment.query.filter(
            Appointment.status.in_(["requested", "confirmed", "rescheduled"]),
            Appointment.starts_at < ends_at,
            Appointment.ends_at > starts_at,
        )
        if staff_id:
            q = q.filter(Appointment.staff_id == staff_id)
        if exclude_id:
            q = q.filter(Appointment.id != exclude_id)
        return db.session.query(q.exists()).scalar()


class WorkingHours(db.Model):
    """Bookable window per weekday (0=Mon … 6=Sun). Times are local HH:MM."""
    __tablename__ = "working_hours"
    id = db.Column(db.Integer, primary_key=True)
    weekday = db.Column(db.Integer, nullable=False)        # 0–6
    start_time = db.Column(db.String(5), default="09:00")  # 24h "HH:MM"
    end_time = db.Column(db.String(5), default="17:00")
    is_open = db.Column(db.Boolean, default=True, nullable=False)


class BlackoutDate(db.Model):
    __tablename__ = "blackout_dates"
    id = db.Column(db.Integer, primary_key=True)
    day = db.Column(db.Date, nullable=False, unique=True, index=True)
    reason = db.Column(db.String(160), nullable=True)


# ══════════════════════════════════════════════ INVOICES ═══════════════════
class Invoice(db.Model):
    __tablename__ = "invoices"
    id = db.Column(db.Integer, primary_key=True)
    number = db.Column(db.String(40), unique=True, nullable=False, index=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    project_id = db.Column(db.Integer, db.ForeignKey("projects.id"), nullable=True)
    status = db.Column(db.String(20), default="draft", nullable=False, index=True)
    currency = db.Column(db.String(3), default="GBP", nullable=False)
    notes = db.Column(db.Text, nullable=True)
    issued_at = db.Column(db.DateTime, nullable=True)
    due_at = db.Column(db.DateTime, nullable=True)
    paid_at = db.Column(db.DateTime, nullable=True)
    stripe_session_id = db.Column(db.String(160), nullable=True)
    stripe_payment_intent = db.Column(db.String(160), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    owner = db.relationship("User", backref=db.backref("invoices", lazy="dynamic"))
    line_items = db.relationship("InvoiceLineItem", backref="invoice",
                                 cascade="all, delete-orphan", lazy="select")
    payments = db.relationship("Payment", backref="invoice",
                               cascade="all, delete-orphan", lazy="dynamic")

    @staticmethod
    def gen_number():
        return f"INV-{datetime.utcnow():%Y%m}-{secrets.token_hex(3).upper()}"

    @property
    def total_cents(self):
        return sum(li.amount_cents for li in self.line_items)

    @property
    def total_display(self):
        return cents_to_str(self.total_cents, self.currency)

    @property
    def status_meta(self):
        return INVOICE_STATUS_META.get(self.status, INVOICE_STATUS_META["draft"])

    @property
    def is_payable(self):
        return self.status in ("sent", "overdue")


class InvoiceLineItem(db.Model):
    __tablename__ = "invoice_line_items"
    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey("invoices.id"), nullable=False, index=True)
    description = db.Column(db.String(300), nullable=False)
    quantity = db.Column(db.Integer, default=1, nullable=False)
    unit_cents = db.Column(db.Integer, default=0, nullable=False)

    @property
    def amount_cents(self):
        return (self.quantity or 0) * (self.unit_cents or 0)


class Payment(db.Model):
    __tablename__ = "payments"
    id = db.Column(db.Integer, primary_key=True)
    invoice_id = db.Column(db.Integer, db.ForeignKey("invoices.id"), nullable=True, index=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    amount_cents = db.Column(db.Integer, default=0, nullable=False)
    currency = db.Column(db.String(3), default="GBP", nullable=False)
    method = db.Column(db.String(40), default="stripe")
    status = db.Column(db.String(20), default="succeeded")
    stripe_payment_intent = db.Column(db.String(160), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    owner = db.relationship("User")

    @property
    def amount_display(self):
        return cents_to_str(self.amount_cents, self.currency)


# ═══════════════════════════════════════════════ PRODUCTS ══════════════════
# Named Shop* to avoid clashing with the License Manager's own `Product`.
class ShopCategory(db.Model):
    __tablename__ = "product_categories"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    slug = db.Column(db.String(120), unique=True, nullable=False, index=True)
    products = db.relationship("ShopProduct", backref="category", lazy="dynamic")


class ShopProduct(db.Model):
    __tablename__ = "products"
    id = db.Column(db.Integer, primary_key=True)
    category_id = db.Column(db.Integer, db.ForeignKey("product_categories.id"), nullable=True)
    name = db.Column(db.String(200), nullable=False)
    slug = db.Column(db.String(200), unique=True, nullable=False, index=True)
    description = db.Column(db.Text, nullable=True)
    sku = db.Column(db.String(80), nullable=True, index=True)
    price_cents = db.Column(db.Integer, default=0, nullable=False)
    currency = db.Column(db.String(3), default="GBP", nullable=False)
    stock = db.Column(db.Integer, default=0, nullable=False)
    image_path = db.Column(db.String(500), nullable=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @property
    def price_display(self):
        return cents_to_str(self.price_cents, self.currency)


# ═══════════════════════════════════════════ NOTIFICATIONS ═════════════════
class Notification(db.Model):
    __tablename__ = "notifications"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    title = db.Column(db.String(200), nullable=False)
    body = db.Column(db.String(500), nullable=True)
    url = db.Column(db.String(400), nullable=True)
    category = db.Column(db.String(40), default="general")
    is_read = db.Column(db.Boolean, default=False, nullable=False, index=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)

    user = db.relationship("User", backref=db.backref("notifications", lazy="dynamic"))

    @classmethod
    def push(cls, user_id, title, body=None, url=None, category="general"):
        n = cls(user_id=user_id, title=title, body=body, url=url, category=category)
        db.session.add(n)
        return n

    @classmethod
    def unread_count(cls, user_id):
        return cls.query.filter_by(user_id=user_id, is_read=False).count()


# ═══════════════════════════════════════════════ AUDIT LOG ═════════════════
class AuditLog(db.Model):
    __tablename__ = "audit_logs"
    id = db.Column(db.Integer, primary_key=True)
    actor_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True, index=True)
    action = db.Column(db.String(80), nullable=False, index=True)
    target_type = db.Column(db.String(60), nullable=True)
    target_id = db.Column(db.Integer, nullable=True)
    meta_json = db.Column(db.Text, nullable=True)
    ip = db.Column(db.String(64), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    actor = db.relationship("User")

    @classmethod
    def log(cls, action, actor=None, target_type=None, target_id=None, meta=None, ip=None):
        row = cls(action=action, actor_id=getattr(actor, "id", None),
                  target_type=target_type, target_id=target_id, ip=ip,
                  meta_json=json.dumps(meta, ensure_ascii=False) if meta else None)
        db.session.add(row)
        return row


# ═══════════════════════════════════════════════ FILES ═════════════════════
class StoredFile(db.Model):
    __tablename__ = "stored_files"
    id = db.Column(db.Integer, primary_key=True)
    owner_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    project_id = db.Column(db.Integer, db.ForeignKey("projects.id"), nullable=True, index=True)
    filename = db.Column(db.String(255), nullable=False)
    stored_path = db.Column(db.String(500), nullable=False)
    mime = db.Column(db.String(120), nullable=True)
    size_bytes = db.Column(db.Integer, default=0)
    scan_status = db.Column(db.String(20), default="pending")  # pending|clean|infected|skipped
    download_count = db.Column(db.Integer, default=0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    owner = db.relationship("User")


# ════════════════════ KNOWLEDGE BASE / MESSAGING / REVIEWS ══════════════════
# Schema in place now so later phases need no migration churn.
class KbArticle(db.Model):
    __tablename__ = "kb_articles"
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(200), nullable=False)
    slug = db.Column(db.String(200), unique=True, nullable=False, index=True)
    body = db.Column(db.Text, nullable=True)
    is_published = db.Column(db.Boolean, default=False, nullable=False)
    author_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class Message(db.Model):
    """Internal staff ↔ customer thread message."""
    __tablename__ = "messages"
    id = db.Column(db.Integer, primary_key=True)
    sender_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    recipient_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    body = db.Column(db.Text, nullable=False)
    is_read = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    sender = db.relationship("User", foreign_keys=[sender_id])
    recipient = db.relationship("User", foreign_keys=[recipient_id])


class Announcement(db.Model):
    __tablename__ = "announcements"
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(200), nullable=False)
    body = db.Column(db.Text, nullable=True)
    level = db.Column(db.String(20), default="info")  # info|success|warning|danger
    is_active = db.Column(db.Boolean, default=True, nullable=False, index=True)
    starts_at = db.Column(db.DateTime, nullable=True)
    ends_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @classmethod
    def active(cls):
        now = datetime.utcnow()
        rows = cls.query.filter_by(is_active=True).all()
        return [r for r in rows
                if (r.starts_at is None or r.starts_at <= now)
                and (r.ends_at is None or r.ends_at >= now)]


class Review(db.Model):
    __tablename__ = "reviews"
    id = db.Column(db.Integer, primary_key=True)
    author_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    rating = db.Column(db.Integer, default=5, nullable=False)  # 1–5
    body = db.Column(db.Text, nullable=True)
    is_published = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    author = db.relationship("User")


class Testimonial(db.Model):
    """A public review/testimonial submitted from the website — no account
    needed. Shows on the homepage slider and the /reviews page once approved."""
    __tablename__ = "testimonials"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    organisation = db.Column(db.String(160), nullable=True)   # business / community
    country = db.Column(db.String(80), nullable=True)
    rating = db.Column(db.Integer, default=5, nullable=False)  # 1–5
    body = db.Column(db.Text, nullable=False)
    approved = db.Column(db.Boolean, default=True, nullable=False, index=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    posted_to_discord = db.Column(db.Boolean, default=False, nullable=False)
    replies = db.relationship("TestimonialReply", backref="testimonial",
                              cascade="all, delete-orphan",
                              order_by="TestimonialReply.created_at",
                              lazy="selectin")

    @property
    def stars(self):
        r = max(1, min(5, int(self.rating or 0)))
        return "★" * r + "☆" * (5 - r)

    @property
    def rating_clamped(self):
        return max(1, min(5, int(self.rating or 5)))

    @property
    def reply_count(self):
        return len(self.replies)

    @property
    def byline(self):
        bits = [self.name]
        if self.organisation:
            bits.append(self.organisation)
        if self.country:
            bits.append(self.country)
        return " · ".join(bits)


class TestimonialReply(db.Model):
    """A reply on a review — a public question to the reviewer, or a staff answer."""
    __tablename__ = "testimonial_replies"
    id = db.Column(db.Integer, primary_key=True)
    testimonial_id = db.Column(db.Integer, db.ForeignKey("testimonials.id"), nullable=False, index=True)
    name = db.Column(db.String(120), nullable=False)
    body = db.Column(db.Text, nullable=False)
    is_staff = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class OAuthAccount(db.Model):
    """Links a user to an external SSO identity (provider + subject id)."""
    __tablename__ = "oauth_accounts"
    id = db.Column(db.Integer, primary_key=True)
    provider = db.Column(db.String(40), nullable=False, index=True)
    sub = db.Column(db.String(255), nullable=False, index=True)   # provider's user id
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    email = db.Column(db.String(160), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    user = db.relationship("User")
    __table_args__ = (db.UniqueConstraint("provider", "sub", name="uq_oauth_provider_sub"),)


# ═══════════════════════════════════════════ MEETING / CALL-OUT REQUESTS ════
MEETING_MODE_META = {
    "in_person": {"label": "In-person — within the Scottish Borders"},
    "outside":   {"label": "In-person — outside the area (may incur a charge)"},
    "phone":     {"label": "Phone call"},
    "online":    {"label": "Online / remote service"},
}
MEETING_STATUS_META = {
    "new":       {"label": "New",       "color": "#f59e0b"},
    "contacted": {"label": "Contacted", "color": "#3b82f6"},
    "scheduled": {"label": "Scheduled", "color": "#22c55e"},
    "closed":    {"label": "Closed",    "color": "#94a3b8"},
}


class MeetingRequest(db.Model):
    """A public 'Book a call-out' request: in-person (in/out of area), phone, or online."""
    __tablename__ = "meeting_requests"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    email = db.Column(db.String(160), nullable=True)
    phone = db.Column(db.String(40), nullable=True)
    mode = db.Column(db.String(20), default="in_person", nullable=False)
    location = db.Column(db.String(200), nullable=True)   # address for in-person
    preferred_day = db.Column(db.Date, nullable=True)
    preferred_time = db.Column(db.String(5), nullable=True)
    details = db.Column(db.Text, nullable=True)
    status = db.Column(db.String(20), default="new", nullable=False, index=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)

    @property
    def mode_meta(self):
        return MEETING_MODE_META.get(self.mode, MEETING_MODE_META["in_person"])

    @property
    def status_meta(self):
        return MEETING_STATUS_META.get(self.status, MEETING_STATUS_META["new"])

    @property
    def is_in_person(self):
        return self.mode in ("in_person", "outside")


# ═══════════════════════════════════════════════ QUICK JOBS ════════════════
QUICKJOB_STATUS_META = {
    "new":       {"label": "Awaiting scheduling", "color": "#f59e0b"},
    "scheduled": {"label": "Scheduled",           "color": "#22c55e"},
    "completed": {"label": "Completed",           "color": "#94a3b8"},
    "cancelled": {"label": "Cancelled",           "color": "#ef4444"},
}


class QuickJob(db.Model):
    """A lightweight, shareable job. Admin creates it, sends the share link;
    the recipient (no account needed) sees the details and can pick a day —
    unless the admin sets/locks the day."""
    __tablename__ = "quick_jobs"
    id = db.Column(db.Integer, primary_key=True)
    token = db.Column(db.String(40), unique=True, nullable=False, index=True)

    title = db.Column(db.String(200), nullable=False)
    details = db.Column(db.Text, nullable=True)
    location = db.Column(db.String(200), nullable=True)
    contact_phone = db.Column(db.String(40), nullable=True)
    price_cents = db.Column(db.Integer, nullable=True)
    currency = db.Column(db.String(3), default="GBP", nullable=False)

    client_name = db.Column(db.String(120), nullable=True)
    client_email = db.Column(db.String(160), nullable=True)
    client_phone = db.Column(db.String(40), nullable=True)

    status = db.Column(db.String(20), default="new", nullable=False, index=True)
    allow_client_scheduling = db.Column(db.Boolean, default=True, nullable=False)
    allow_client_edits = db.Column(db.Boolean, default=True, nullable=False)
    scheduled_day = db.Column(db.Date, nullable=True)
    scheduled_time = db.Column(db.String(5), nullable=True)   # "HH:MM" (optional)
    scheduled_by = db.Column(db.String(10), nullable=True)    # "client" | "admin"

    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    # Payment (Stripe)
    is_paid = db.Column(db.Boolean, default=False, nullable=False)
    paid_at = db.Column(db.DateTime, nullable=True)
    paid_via = db.Column(db.String(20), nullable=True)   # "stripe" | "manual"
    stripe_session_id = db.Column(db.String(160), nullable=True)
    stripe_payment_intent = db.Column(db.String(160), nullable=True)

    created_by = db.relationship("User")
    items = db.relationship("QuickJobItem", backref="job", lazy="selectin",
                            cascade="all, delete-orphan",
                            order_by="QuickJobItem.id")

    @staticmethod
    def gen_token():
        return secrets.token_urlsafe(9)

    @property
    def status_meta(self):
        return QUICKJOB_STATUS_META.get(self.status, QUICKJOB_STATUS_META["new"])

    # ----- pricing: line items drive the total; price_cents is the fallback -----
    @property
    def has_items(self):
        return len(self.items) > 0

    @property
    def items_total_cents(self):
        return sum(i.amount_cents for i in self.items)

    @property
    def total_cents(self):
        return self.items_total_cents if self.has_items else (self.price_cents or 0)

    @property
    def total_display(self):
        return cents_to_str(self.total_cents, self.currency)

    @property
    def price_display(self):
        if not self.has_items and self.price_cents is None:
            return None
        return cents_to_str(self.total_cents, self.currency)

    @property
    def is_open_for_scheduling(self):
        return self.status != "cancelled" and self.allow_client_scheduling

    @property
    def has_price(self):
        return self.total_cents > 0

    @property
    def is_payable_online(self):
        """A non-zero total, not already paid, and not cancelled."""
        return self.has_price and not self.is_paid and self.status != "cancelled"

    @property
    def client_can_edit(self):
        """Whether the public recipient may change items / details / schedule."""
        return self.allow_client_edits and not self.is_paid and self.status != "cancelled"


class QuickJobItem(db.Model):
    """A line on a Quick Job. Either side can add them; the job total is the
    sum of all line amounts (quantity × unit price)."""
    __tablename__ = "quick_job_items"
    id = db.Column(db.Integer, primary_key=True)
    job_id = db.Column(db.Integer, db.ForeignKey("quick_jobs.id"), nullable=False, index=True)
    label = db.Column(db.String(200), nullable=False)
    quantity = db.Column(db.Integer, default=1, nullable=False)
    unit_cents = db.Column(db.Integer, default=0, nullable=False)
    source = db.Column(db.String(10), default="admin", nullable=False)  # admin | client
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @property
    def amount_cents(self):
        return (self.quantity or 0) * (self.unit_cents or 0)

    @property
    def unit_display(self):
        return cents_to_str(self.unit_cents, "GBP")

    @property
    def amount_display(self):
        return cents_to_str(self.amount_cents, "GBP")


# ═══════════════════════════════════════════ PARTNER PORTAL ════════════════
import re as _re  # noqa: E402

PARTNER_TYPE_CHOICES = ["Developer", "Agency", "Community", "Other"]
PARTNER_LEGAL_CHOICES = ["Registered", "Unregistered"]

# status key -> (label, tailwind colour token, progress %)
PARTNER_STATUS_META = {
    "draft":       ("Draft",          "gray",  10),
    "pending":     ("Pending Review", "amber", 40),
    "in_progress": ("In Progress",    "blue",  70),
    "approved":    ("Approved",       "green", 100),
    "rejected":    ("Rejected",       "red",   100),
}

AGREEMENT_VERSION_DEFAULT = "1.0"


def slugify(value, maxlen=60):
    value = (value or "").strip().lower()
    value = _re.sub(r"[^a-z0-9]+", "-", value).strip("-")
    return (value or "company")[:maxlen]


class PartnerAgreementAcceptance(db.Model):
    """A user's electronically-signed acceptance of the Partner Agreement."""
    __tablename__ = "partner_agreement_acceptances"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    full_legal_name = db.Column(db.String(160), nullable=False)
    version = db.Column(db.String(20), nullable=False, default=AGREEMENT_VERSION_DEFAULT)
    ip = db.Column(db.String(64))
    accepted_at = db.Column(db.DateTime, default=datetime.utcnow)
    user = db.relationship("User")


class PartnerCompany(db.Model):
    """A partner-built company profile / mini-site living under OpsLab."""
    __tablename__ = "partner_companies"
    id = db.Column(db.Integer, primary_key=True)
    slug = db.Column(db.String(80), unique=True, nullable=False, index=True)
    name = db.Column(db.String(160), nullable=False)
    ctype = db.Column(db.String(40), default="Developer")
    legal_status = db.Column(db.String(40), default="Unregistered")
    owner_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False, index=True)
    owner_legal_name = db.Column(db.String(160))
    country = db.Column(db.String(80))
    description = db.Column(db.Text)
    services = db.Column(db.Text)
    pricing = db.Column(db.Text)
    external_url = db.Column(db.String(300))
    terms = db.Column(db.Text)
    privacy = db.Column(db.Text)
    status = db.Column(db.String(20), default="pending", index=True)
    review_notes = db.Column(db.Text)        # admin feedback / requested changes
    rejection_reason = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    owner = db.relationship("User")

    @property
    def status_label(self):
        return PARTNER_STATUS_META.get(self.status, ("Unknown", "gray", 0))[0]

    @property
    def status_color(self):
        return PARTNER_STATUS_META.get(self.status, ("Unknown", "gray", 0))[1]

    @property
    def progress(self):
        return PARTNER_STATUS_META.get(self.status, ("Unknown", "gray", 0))[2]

    @property
    def is_public(self):
        return self.status == "approved"

    @staticmethod
    def unique_slug(name):
        base = slugify(name)
        candidate, n = base, 1
        while PartnerCompany.query.filter_by(slug=candidate).first():
            n += 1
            candidate = f"{base}-{n}"
        return candidate


# ══════════════════════════════════════════════ ROADMAP ════════════════════
ROADMAP_STATUS_META = {
    "idea":        {"label": "Idea",        "color": "#94a3b8"},
    "planned":     {"label": "Planned",     "color": "#60a5fa"},
    "in_progress": {"label": "In Progress", "color": "#f59e0b"},
    "completed":   {"label": "Completed",   "color": "#22c55e"},
}
ROADMAP_STATUS_ORDER = ["idea", "planned", "in_progress", "completed"]


class RoadmapItem(db.Model):
    """A single public roadmap card. Admin/staff create & move these; anyone
    can view the board at /roadmap."""
    __tablename__ = "roadmap_items"
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(160), nullable=False)
    description = db.Column(db.Text, nullable=True)
    category = db.Column(db.String(60), nullable=True)   # free-text tag, e.g. "Tickets", "Portal"
    status = db.Column(db.String(20), default="idea", nullable=False, index=True)
    position = db.Column(db.Integer, default=0, nullable=False)  # order within a column
    is_visible = db.Column(db.Boolean, default=True, nullable=False, index=True)
    target_date = db.Column(db.Date, nullable=True)
    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    created_by = db.relationship("User")

    @property
    def status_meta(self):
        return ROADMAP_STATUS_META.get(self.status, ROADMAP_STATUS_META["idea"])


SERVICE_PACKAGE_SLUGS = [
    "website-development", "fivem-development", "tech-support",
    "hosting", "system-setup", "onsite-it-networking",
]


class ServicePackage(db.Model):
    """A single pricing/package card shown on a /services/<slug> page.
    Admin/staff manage these; slugs are shared with the six divisions
    defined in app/services_data.py (see SERVICE_PACKAGE_SLUGS above)."""
    __tablename__ = "service_packages"
    id = db.Column(db.Integer, primary_key=True)
    service_slug = db.Column(db.String(60), nullable=False, index=True)
    name = db.Column(db.String(120), nullable=False)
    description = db.Column(db.Text, nullable=True)
    features = db.Column(db.Text, nullable=True)  # one feature per line
    position = db.Column(db.Integer, default=0, nullable=False)
    is_visible = db.Column(db.Boolean, default=True, nullable=False, index=True)
    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    created_by = db.relationship("User")

    @property
    def feature_list(self):
        return [f.strip() for f in (self.features or "").splitlines() if f.strip()]
