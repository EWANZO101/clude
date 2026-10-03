#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  OpsLab Systems — Portal Expansion installer (Phase 1)
#  • Backs up your current app/ + requirements.txt + instance DB
#  • Writes the new portal blueprint, models, RBAC, billing + templates
#  • Installs new Python deps (psycopg2-binary, stripe)
#  • Restarts the service (if found)
#
#  Usage:
#     chmod +x install_portal.sh
#     ./install_portal.sh                 # uses defaults below
#     APP_ROOT=/opt/opslabs ./install_portal.sh
#     SERVICE=opslabs-app.service VENV=/opt/opslabs/.venv ./install_portal.sh
#     ./install_portal.sh --no-restart    # skip the systemctl restart
# ════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Config (override via env) ───────────────────────────────────────────
APP_ROOT="${APP_ROOT:-$(pwd)}"          # project root that CONTAINS app/
SERVICE="${SERVICE:-opslabs-app.service}"
VENV="${VENV:-}"                        # e.g. /opt/opslabs/.venv  (auto-detected if empty)
DO_RESTART=1
[ "${1:-}" = "--no-restart" ] && DO_RESTART=0

say()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── Sanity check ────────────────────────────────────────────────────────
[ -f "$APP_ROOT/app/__init__.py" ] || die "No app/__init__.py under APP_ROOT=$APP_ROOT. Set APP_ROOT to your project root (the folder that contains app/)."
say "Target project: $APP_ROOT"

# ── Backup ──────────────────────────────────────────────────────────────
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$APP_ROOT/_backups"
BACKUP="$BACKUP_DIR/pre-portal-$STAMP.tar.gz"
mkdir -p "$BACKUP_DIR"
say "Backing up current site → $BACKUP"
tar -czf "$BACKUP" -C "$APP_ROOT" \
    app \
    $( [ -f "$APP_ROOT/requirements.txt" ] && echo requirements.txt ) \
    $( [ -d "$APP_ROOT/instance" ] && echo instance ) \
    2>/dev/null || die "Backup failed — aborting before any changes."
ok "Backup written ($(du -h "$BACKUP" | cut -f1))"

# ── Write files ─────────────────────────────────────────────────────────
write() {  # write <relpath>  (content follows on stdin via heredoc)
  local rel="$1"; local dst="$APP_ROOT/$rel"
  mkdir -p "$(dirname "$dst")"
  cat > "$dst"
  echo "   wrote $rel"
}

say "Writing portal files…"

write "app/models_business.py" << '__OPSLAB_EOF__'
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
__OPSLAB_EOF__
write "app/rbac.py" << '__OPSLAB_EOF__'
"""
═══════════════════════════════════════════════════════════════════════════
  rbac.py — role hierarchy + permission decorators
═══════════════════════════════════════════════════════════════════════════
  Backward compatible with the existing `User.role` strings:
    legacy "user" → customer, "admin" → admin, "staff" → staff.

  Usage:
      from .rbac import require_role, require_permission, STAFF

      @bp.route("/admin/thing")
      @require_role(STAFF)
      def thing(): ...

      @bp.route("/invoices/<int:i>/void", methods=["POST"])
      @require_permission("invoice.manage")
      def void(i): ...
═══════════════════════════════════════════════════════════════════════════
"""
from functools import wraps
from flask import abort, redirect, url_for, request, flash
from flask_login import current_user

# Canonical roles (high → low authority)
SUPER_ADMIN = "super_admin"
ADMIN = "admin"
STAFF = "staff"
SUPPORT = "support"
CUSTOMER = "customer"

ROLES = [SUPER_ADMIN, ADMIN, STAFF, SUPPORT, CUSTOMER]
ROLE_RANK = {SUPER_ADMIN: 50, ADMIN: 40, STAFF: 30, SUPPORT: 20, CUSTOMER: 10}
ROLE_LABELS = {
    SUPER_ADMIN: "Super Admin", ADMIN: "Admin", STAFF: "Staff",
    SUPPORT: "Support", CUSTOMER: "Customer",
}

# Map any legacy/loose value onto a canonical role
_LEGACY = {"user": CUSTOMER, "member": CUSTOMER, "client": CUSTOMER,
           "administrator": ADMIN, "owner": SUPER_ADMIN}


def canonical_role(user) -> str:
    raw = (getattr(user, "role", None) or "").strip().lower()
    if raw in ROLE_RANK:
        return raw
    return _LEGACY.get(raw, CUSTOMER)


def rank(user) -> int:
    return ROLE_RANK.get(canonical_role(user), 0)


def at_least(user, role) -> bool:
    return rank(user) >= ROLE_RANK.get(role, 999)


def is_staff_plus(user) -> bool:
    """Anyone who works for the company (support and above)."""
    return at_least(user, SUPPORT)


# ── Permission map: permission → minimum role ───────────────────────────────
# Add freely; unknown permissions default to ADMIN (fail safe).
PERMISSIONS = {
    # projects
    "project.view_all":     SUPPORT,
    "project.manage":       STAFF,
    "project.update_stage": STAFF,
    # appointments
    "appointment.view_all": SUPPORT,
    "appointment.manage":   STAFF,
    # invoices / billing
    "invoice.view_all":     SUPPORT,
    "invoice.manage":       ADMIN,
    "payment.refund":       ADMIN,
    # products / shop
    "product.manage":       ADMIN,
    # support tickets
    "ticket.view_all":      SUPPORT,
    "ticket.manage":        SUPPORT,
    # users / system
    "user.manage":          ADMIN,
    "role.manage":          SUPER_ADMIN,
    "settings.manage":      ADMIN,
    "audit.view":           ADMIN,
    "kb.manage":            STAFF,
    "announcement.manage":  ADMIN,
}


def has_permission(user, permission) -> bool:
    required = PERMISSIONS.get(permission, ADMIN)
    return at_least(user, required)


# ── Decorators ──────────────────────────────────────────────────────────────
def _deny():
    if not current_user.is_authenticated:
        flash("Please sign in to continue.", "warning")
        return redirect(url_for("auth.login", next=request.path))
    abort(403)


def require_role(min_role):
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            if not current_user.is_authenticated or not at_least(current_user, min_role):
                return _deny()
            return fn(*a, **kw)
        return wrapper
    return deco


def require_permission(permission):
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            if not current_user.is_authenticated or not has_permission(current_user, permission):
                return _deny()
            return fn(*a, **kw)
        return wrapper
    return deco
__OPSLAB_EOF__
write "app/billing.py" << '__OPSLAB_EOF__'
"""
═══════════════════════════════════════════════════════════════════════════
  billing.py — Stripe integration (safe when unconfigured)
═══════════════════════════════════════════════════════════════════════════
  Set these env vars to go live:
      STRIPE_SECRET_KEY        sk_live_… / sk_test_…
      STRIPE_PUBLISHABLE_KEY   pk_…           (used in templates)
      STRIPE_WEBHOOK_SECRET    whsec_…        (verifies webhook signatures)

  Without STRIPE_SECRET_KEY everything no-ops with a clear message, so the
  rest of the portal still runs. Webhook endpoint is /billing/webhook.
═══════════════════════════════════════════════════════════════════════════
"""
import os
from datetime import datetime
from flask import Blueprint, request, current_app, url_for

from . import db
from .models_business import Invoice, Payment, Service, Notification, AuditLog, QuickJob

billing_bp = Blueprint("billing", __name__)

try:
    import stripe  # noqa
except Exception:  # library not installed yet
    stripe = None


def _secret():
    return os.environ.get("STRIPE_SECRET_KEY", "").strip()


def is_configured() -> bool:
    return bool(stripe and _secret())


def publishable_key() -> str:
    return os.environ.get("STRIPE_PUBLISHABLE_KEY", "").strip()


def create_checkout_session(invoice: Invoice, success_url: str, cancel_url: str):
    """Return (session, error). On success `session.url` is the redirect."""
    if not is_configured():
        return None, "Stripe is not configured yet — add STRIPE_SECRET_KEY."
    stripe.api_key = _secret()
    try:
        session = stripe.checkout.Session.create(
            mode="payment",
            success_url=success_url,
            cancel_url=cancel_url,
            client_reference_id=str(invoice.id),
            customer_email=invoice.owner.email,
            line_items=[{
                "quantity": li.quantity,
                "price_data": {
                    "currency": invoice.currency.lower(),
                    "unit_amount": li.unit_cents,
                    "product_data": {"name": li.description[:120] or "Item"},
                },
            } for li in invoice.line_items],
            metadata={"invoice_id": invoice.id, "invoice_number": invoice.number},
        )
        invoice.stripe_session_id = session.id
        db.session.commit()
        return session, None
    except Exception as e:  # surface Stripe errors without crashing
        return None, str(e)


def _mark_invoice_paid(invoice: Invoice, payment_intent=None):
    invoice.status = "paid"
    invoice.paid_at = datetime.utcnow()
    if payment_intent:
        invoice.stripe_payment_intent = payment_intent
    db.session.add(Payment(
        invoice_id=invoice.id, owner_id=invoice.owner_id,
        amount_cents=invoice.total_cents, currency=invoice.currency,
        method="stripe", status="succeeded", stripe_payment_intent=payment_intent,
    ))
    Notification.push(invoice.owner_id, "Payment received",
                      f"Invoice {invoice.number} is now paid.",
                      url=f"/portal/invoices/{invoice.id}", category="billing")
    AuditLog.log("invoice.paid", target_type="invoice", target_id=invoice.id,
                 meta={"number": invoice.number})


def create_checkout_for_quickjob(job: QuickJob, success_url: str, cancel_url: str):
    """Stripe Checkout session to pay a Quick Job. Returns (session, error)."""
    if not is_configured():
        return None, "Stripe is not configured yet — add STRIPE_SECRET_KEY."
    if not job.is_payable_online:
        return None, "This job isn't payable."
    stripe.api_key = _secret()
    cur = (job.currency or "GBP").lower()
    if job.has_items:
        line_items = [{
            "quantity": (it.quantity or 1),
            "price_data": {
                "currency": cur,
                "unit_amount": it.unit_cents,
                "product_data": {"name": (it.label or "Item")[:120]},
            },
        } for it in job.items if it.unit_cents and it.quantity]
    else:
        line_items = [{
            "quantity": 1,
            "price_data": {
                "currency": cur,
                "unit_amount": job.total_cents,
                "product_data": {"name": (job.title or "Job")[:120]},
            },
        }]
    try:
        session = stripe.checkout.Session.create(
            mode="payment",
            success_url=success_url,
            cancel_url=cancel_url,
            client_reference_id=f"job:{job.id}",
            customer_email=(job.client_email or None),
            line_items=line_items,
            metadata={"quickjob_id": job.id, "quickjob_token": job.token},
        )
        job.stripe_session_id = session.id
        db.session.commit()
        return session, None
    except Exception as e:
        return None, str(e)


def _mark_quickjob_paid(job: QuickJob, payment_intent=None):
    job.is_paid = True
    job.paid_at = datetime.utcnow()
    job.paid_via = "stripe"
    if payment_intent:
        job.stripe_payment_intent = payment_intent
    if job.created_by_id:
        Notification.push(job.created_by_id, "Job payment received",
                          f"“{job.title}” has been paid ({job.price_display}).",
                          url=f"/admin/jobs/{job.id}", category="job")
    AuditLog.log("quickjob.paid", target_type="quick_job", target_id=job.id,
                 meta={"amount_cents": job.total_cents})


@billing_bp.route("/webhook", methods=["POST"])
def webhook():
    """Stripe → us. Verifies signature when STRIPE_WEBHOOK_SECRET is set."""
    if not (stripe and _secret()):
        return ("stripe not configured", 503)

    payload = request.get_data()
    sig = request.headers.get("Stripe-Signature", "")
    wh_secret = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
    stripe.api_key = _secret()

    try:
        if wh_secret:
            event = stripe.Webhook.construct_event(payload, sig, wh_secret)
        else:  # dev: trust the body (set the secret in production!)
            import json
            event = json.loads(payload)
    except Exception as e:
        current_app.logger.warning("Stripe webhook verify failed: %s", e)
        return ("bad signature", 400)

    etype = event.get("type")
    obj = event.get("data", {}).get("object", {})

    if etype == "checkout.session.completed":
        meta = obj.get("metadata") or {}
        ref = obj.get("client_reference_id") or ""
        # Quick Job payment?
        qj_id = meta.get("quickjob_id") or (ref[4:] if ref.startswith("job:") else None)
        if qj_id:
            job = QuickJob.query.get(int(qj_id))
            if job and not job.is_paid:
                _mark_quickjob_paid(job, obj.get("payment_intent"))
        else:
            inv_id = meta.get("invoice_id") or ref
            if inv_id:
                inv = Invoice.query.get(int(inv_id))
                if inv and inv.status != "paid":
                    _mark_invoice_paid(inv, obj.get("payment_intent"))

    elif etype in ("invoice.paid", "invoice.payment_succeeded"):
        sub = obj.get("subscription")
        if sub:
            svc = Service.query.filter_by(stripe_subscription_id=sub).first()
            if svc:
                svc.status = "active"

    elif etype == "customer.subscription.deleted":
        sub = obj.get("id")
        svc = Service.query.filter_by(stripe_subscription_id=sub).first()
        if svc:
            svc.status = "expired"

    db.session.commit()
    return ("", 200)
__OPSLAB_EOF__
write "app/portal/__init__.py" << '__OPSLAB_EOF__'
"""Customer portal blueprint: dashboard, projects, appointments, invoices."""
from flask import Blueprint

portal_bp = Blueprint(
    "portal", __name__,
    template_folder="templates",  # falls back to app/templates/portal too
)

from . import routes  # noqa: E402,F401  (registers routes on import)
__OPSLAB_EOF__
write "app/portal/routes.py" << '__OPSLAB_EOF__'
"""
Portal routes — customer-facing, with staff overrides via RBAC.
Times stored UTC; displayed Europe/London in 24h (see to_local / fmt).
"""
from datetime import datetime, timedelta, time, date
from zoneinfo import ZoneInfo

from flask import (render_template, request, redirect, url_for, flash,
                   abort, jsonify)
from flask_login import login_required, current_user

from . import portal_bp
from .. import db
from ..models import Ticket, Company, User, normalise_status
from ..models_business import (
    Service, Project, ProjectMilestone, ProjectEvent, PROJECT_STAGES,
    PROJECT_STAGE_META, Appointment, WorkingHours, BlackoutDate,
    Invoice, InvoiceLineItem, Payment, Notification, Announcement, AuditLog,
)
from ..rbac import require_permission, has_permission, is_staff_plus, STAFF
from .. import billing

LONDON = ZoneInfo("Europe/London")
UTC = ZoneInfo("UTC")
OPEN_TICKET = ("seen", "pending", "in_progress", "open")


# ───────────────────────────── tz / format helpers ─────────────────────────
def to_local(dt):
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(LONDON)


def fmt(dt, with_time=True):
    loc = to_local(dt)
    if not loc:
        return "—"
    return loc.strftime("%d %b %Y · %H:%M") if with_time else loc.strftime("%d %b %Y")


def local_to_utc(d: date, hhmm: str):
    """'14:30' on a date (London) → naive UTC datetime for storage."""
    h, m = (int(x) for x in hhmm.split(":"))
    local_dt = datetime(d.year, d.month, d.day, h, m, tzinfo=LONDON)
    return local_dt.astimezone(UTC).replace(tzinfo=None)


@portal_bp.app_template_filter("dt")
def _jinja_dt(value):
    return fmt(value)


@portal_bp.app_template_filter("dtdate")
def _jinja_dtdate(value):
    return fmt(value, with_time=False)


# Inject portal-wide context (unread notifications, announcements)
@portal_bp.app_context_processor
def _portal_ctx():
    if not current_user.is_authenticated:
        return {}
    return dict(
        portal_unread=Notification.unread_count(current_user.id),
        portal_announcements=Announcement.active(),
        portal_is_staff=is_staff_plus(current_user),
        can=has_permission,  # use {{ can(current_user, 'invoice.manage') }}
    )


def _owned_or_staff(query, owner_col):
    """Limit a query to the current user's rows unless they're staff+."""
    if is_staff_plus(current_user):
        return query
    return query.filter(owner_col == current_user.id)


# ════════════════════════════════════ DASHBOARD ════════════════════════════
@portal_bp.route("/")
@login_required
def dashboard():
    uid = current_user.id

    svc_counts = {s: Service.query.filter_by(owner_id=uid, status=s).count()
                  for s in ("active", "pending", "suspended", "expired")}

    proj_q = Project.query.filter_by(owner_id=uid)
    proj_counts = {
        "active": proj_q.filter(~Project.stage.in_(["completed"])).count(),
        "completed": proj_q.filter_by(stage="completed").count(),
    }
    recent_projects = (Project.query.filter_by(owner_id=uid)
                       .order_by(Project.updated_at.desc()).limit(5).all())

    outstanding = (Invoice.query.filter_by(owner_id=uid)
                   .filter(Invoice.status.in_(["sent", "overdue"])).all())
    outstanding_total = sum(i.total_cents for i in outstanding)
    recent_payments = (Payment.query.filter_by(owner_id=uid)
                       .order_by(Payment.created_at.desc()).limit(5).all())

    upcoming_appts = (Appointment.query.filter_by(owner_id=uid)
                      .filter(Appointment.starts_at >= datetime.utcnow(),
                              Appointment.status.in_(["requested", "confirmed", "rescheduled"]))
                      .order_by(Appointment.starts_at.asc()).limit(5).all())

    open_tickets = (Ticket.query.filter_by(user_id=uid)
                    .filter(Ticket.status.in_(OPEN_TICKET)).count())

    return render_template("portal/dashboard.html",
        svc_counts=svc_counts, proj_counts=proj_counts,
        recent_projects=recent_projects, outstanding=outstanding,
        outstanding_total=outstanding_total, recent_payments=recent_payments,
        upcoming_appts=upcoming_appts, open_tickets=open_tickets)


# ════════════════════════════════════ PROJECTS ═════════════════════════════
@portal_bp.route("/projects")
@login_required
def projects():
    q = _owned_or_staff(Project.query, Project.owner_id)
    items = q.order_by(Project.updated_at.desc()).all()
    return render_template("portal/projects.html", projects=items, stage_meta=PROJECT_STAGE_META)


@portal_bp.route("/projects/new", methods=["GET", "POST"])
@login_required
def project_new():
    companies = Company.query.filter_by(is_active=True).all()
    if request.method == "POST":
        title = (request.form.get("title") or "").strip()
        if not title:
            flash("Give your project a title.", "error")
            return render_template("portal/project_new.html", companies=companies)
        p = Project(
            owner_id=current_user.id,
            company_id=(request.form.get("company_id") or None),
            title=title,
            summary=(request.form.get("summary") or "").strip() or None,
            requirements=(request.form.get("requirements") or "").strip() or None,
            stage="submitted",
        )
        db.session.add(p)
        db.session.flush()
        p.log_event("created", "Project submitted.", actor=current_user)
        Notification.push(current_user.id, "Project submitted",
                          f"“{p.title}” is now in the queue.",
                          url=f"/portal/projects/{p.id}", category="project")
        AuditLog.log("project.create", actor=current_user, target_type="project",
                     target_id=p.id, ip=request.remote_addr)
        db.session.commit()
        flash("Project submitted.", "success")
        return redirect(url_for("portal.project_detail", pid=p.id))
    return render_template("portal/project_new.html", companies=companies)


@portal_bp.route("/projects/<int:pid>")
@login_required
def project_detail(pid):
    p = Project.query.get_or_404(pid)
    if p.owner_id != current_user.id and not is_staff_plus(current_user):
        abort(403)
    staff = User.query.filter(User.role.in_(["staff", "admin", "super_admin", "support"])).all() \
        if is_staff_plus(current_user) else []
    return render_template("portal/project_detail.html", p=p,
                           stages=PROJECT_STAGES, stage_meta=PROJECT_STAGE_META,
                           events=p.events.all(), milestones=p.milestones.all(),
                           staff=staff)


@portal_bp.route("/projects/<int:pid>/update", methods=["POST"])
@require_permission("project.manage")
def project_update(pid):
    p = Project.query.get_or_404(pid)
    new_stage = request.form.get("stage")
    pct = request.form.get("percent_complete")
    note = (request.form.get("note") or "").strip()

    if new_stage and new_stage in PROJECT_STAGES and new_stage != p.stage:
        p.stage = new_stage
        p.percent_complete = PROJECT_STAGE_META[new_stage].get("pct", p.percent_complete)
        p.log_event("stage_change", f"Stage → {PROJECT_STAGE_META[new_stage]['label']}",
                    actor=current_user)
    if pct:
        try:
            p.percent_complete = max(0, min(100, int(pct)))
        except ValueError:
            pass
    sid = request.form.get("assigned_staff_id")
    if sid is not None:
        p.assigned_staff_id = int(sid) if sid else None
    est = request.form.get("estimated_completion")
    if est:
        try:
            p.estimated_completion = datetime.strptime(est, "%Y-%m-%d")
        except ValueError:
            pass
    if note:
        p.log_event("staff_update", note, actor=current_user)

    Notification.push(p.owner_id, "Project updated",
                      f"“{p.title}” — {p.stage_meta['label']} ({p.effective_percent}%).",
                      url=f"/portal/projects/{p.id}", category="project")
    AuditLog.log("project.update", actor=current_user, target_type="project",
                 target_id=p.id, meta={"stage": p.stage}, ip=request.remote_addr)
    db.session.commit()
    flash("Project updated.", "success")
    return redirect(url_for("portal.project_detail", pid=p.id))


@portal_bp.route("/projects/<int:pid>/comment", methods=["POST"])
@login_required
def project_comment(pid):
    p = Project.query.get_or_404(pid)
    if p.owner_id != current_user.id and not is_staff_plus(current_user):
        abort(403)
    text = (request.form.get("text") or "").strip()
    if text:
        kind = "staff_update" if is_staff_plus(current_user) else "client_update"
        p.log_event(kind, text, actor=current_user)
        # notify the other party
        notify_uid = p.owner_id if is_staff_plus(current_user) else (p.assigned_staff_id or p.owner_id)
        if notify_uid and notify_uid != current_user.id:
            Notification.push(notify_uid, "New project comment",
                              text[:120], url=f"/portal/projects/{p.id}", category="project")
        db.session.commit()
        flash("Comment added.", "success")
    return redirect(url_for("portal.project_detail", pid=p.id))


# ═════════════════════════════════ APPOINTMENTS ════════════════════════════
def _working_hours_map():
    rows = WorkingHours.query.all()
    if not rows:  # sensible default Mon–Fri 09:00–17:00
        return {wd: ("09:00", "17:00") for wd in range(5)}
    return {r.weekday: (r.start_time, r.end_time) for r in rows if r.is_open}


def _slots_for(day: date, duration_min=30):
    """Return list of free 'HH:MM' start slots for a London date."""
    wh = _working_hours_map().get(day.weekday())
    if not wh:
        return []
    if BlackoutDate.query.filter_by(day=day).first():
        return []
    start_h, start_m = (int(x) for x in wh[0].split(":"))
    end_h, end_m = (int(x) for x in wh[1].split(":"))
    cursor = datetime.combine(day, time(start_h, start_m))
    end = datetime.combine(day, time(end_h, end_m))
    out = []
    step = timedelta(minutes=duration_min)
    now_local = datetime.now(LONDON).replace(tzinfo=None)
    while cursor + step <= end:
        s_utc = local_to_utc(day, cursor.strftime("%H:%M"))
        e_utc = s_utc + step
        if cursor > now_local and not Appointment.has_conflict(s_utc, e_utc):
            out.append(cursor.strftime("%H:%M"))
        cursor += step
    return out


@portal_bp.route("/appointments")
@login_required
def appointments():
    q = _owned_or_staff(Appointment.query, Appointment.owner_id)
    upcoming = q.filter(Appointment.starts_at >= datetime.utcnow()) \
        .order_by(Appointment.starts_at.asc()).all()
    past = q.filter(Appointment.starts_at < datetime.utcnow()) \
        .order_by(Appointment.starts_at.desc()).limit(20).all()
    return render_template("portal/appointments.html", upcoming=upcoming, past=past)


@portal_bp.route("/appointments/book", methods=["GET", "POST"])
@login_required
def appointment_book():
    if request.method == "POST":
        subject = (request.form.get("subject") or "").strip()
        day_str = request.form.get("day")
        hhmm = request.form.get("slot")
        dur = int(request.form.get("duration") or 30)
        if not (subject and day_str and hhmm):
            flash("Pick a subject, date and time.", "error")
            return redirect(url_for("portal.appointment_book"))
        try:
            day = datetime.strptime(day_str, "%Y-%m-%d").date()
        except ValueError:
            flash("Invalid date.", "error")
            return redirect(url_for("portal.appointment_book"))
        s_utc = local_to_utc(day, hhmm)
        e_utc = s_utc + timedelta(minutes=dur)
        if Appointment.has_conflict(s_utc, e_utc):
            flash("That slot was just taken — please pick another.", "error")
            return redirect(url_for("portal.appointment_book", day=day_str))
        appt = Appointment(owner_id=current_user.id, subject=subject,
                           notes=(request.form.get("notes") or "").strip() or None,
                           starts_at=s_utc, ends_at=e_utc, status="requested")
        db.session.add(appt)
        db.session.flush()
        Notification.push(current_user.id, "Appointment requested",
                          f"{subject} — {fmt(s_utc)}",
                          url="/portal/appointments", category="appointment")
        AuditLog.log("appointment.create", actor=current_user, target_type="appointment",
                     target_id=appt.id, ip=request.remote_addr)
        db.session.commit()
        flash("Appointment requested.", "success")
        return redirect(url_for("portal.appointments"))

    # GET — show booking form for a chosen day (default: next open day)
    day_str = request.args.get("day")
    if day_str:
        try:
            day = datetime.strptime(day_str, "%Y-%m-%d").date()
        except ValueError:
            day = date.today()
    else:
        day = date.today()
    slots = _slots_for(day)
    return render_template("portal/appointment_book.html",
                           day=day, day_str=day.strftime("%Y-%m-%d"), slots=slots)


@portal_bp.route("/appointments/<int:aid>/cancel", methods=["POST"])
@login_required
def appointment_cancel(aid):
    appt = Appointment.query.get_or_404(aid)
    if appt.owner_id != current_user.id and not is_staff_plus(current_user):
        abort(403)
    appt.status = "cancelled"
    AuditLog.log("appointment.cancel", actor=current_user, target_type="appointment",
                 target_id=appt.id, ip=request.remote_addr)
    db.session.commit()
    flash("Appointment cancelled.", "success")
    return redirect(url_for("portal.appointments"))


# ════════════════════════════════════ INVOICES ═════════════════════════════
@portal_bp.route("/invoices")
@login_required
def invoices():
    q = _owned_or_staff(Invoice.query, Invoice.owner_id)
    items = q.order_by(Invoice.created_at.desc()).all()
    return render_template("portal/invoices.html", invoices=items)


@portal_bp.route("/invoices/<int:iid>")
@login_required
def invoice_detail(iid):
    inv = Invoice.query.get_or_404(iid)
    if inv.owner_id != current_user.id and not is_staff_plus(current_user):
        abort(403)
    return render_template("portal/invoice_detail.html", inv=inv,
                           stripe_pk=billing.publishable_key(),
                           stripe_on=billing.is_configured())


@portal_bp.route("/invoices/<int:iid>/pay", methods=["POST"])
@login_required
def invoice_pay(iid):
    inv = Invoice.query.get_or_404(iid)
    if inv.owner_id != current_user.id:
        abort(403)
    if not inv.is_payable:
        flash("This invoice isn't payable.", "warning")
        return redirect(url_for("portal.invoice_detail", iid=inv.id))
    success = url_for("portal.invoice_detail", iid=inv.id, paid=1, _external=True)
    cancel = url_for("portal.invoice_detail", iid=inv.id, _external=True)
    session, err = billing.create_checkout_session(inv, success, cancel)
    if err:
        flash(err, "error")
        return redirect(url_for("portal.invoice_detail", iid=inv.id))
    return redirect(session.url, code=303)


# ═════════════════════════════════ NOTIFICATIONS ═══════════════════════════
@portal_bp.route("/notifications")
@login_required
def notifications():
    items = (Notification.query.filter_by(user_id=current_user.id)
             .order_by(Notification.created_at.desc()).limit(100).all())
    return render_template("portal/notifications.html", items=items)


@portal_bp.route("/notifications/read-all", methods=["POST"])
@login_required
def notifications_read_all():
    Notification.query.filter_by(user_id=current_user.id, is_read=False) \
        .update({"is_read": True})
    db.session.commit()
    if request.headers.get("X-Requested-With") == "fetch":
        return jsonify(ok=True)
    return redirect(url_for("portal.notifications"))
__OPSLAB_EOF__
write "app/quickjobs/__init__.py" << '__OPSLAB_EOF__'
"""Quick Jobs: admin-created shareable jobs with public scheduling links."""
from flask import Blueprint

quickjobs_bp = Blueprint("quickjobs", __name__)

from . import routes  # noqa: E402,F401
__OPSLAB_EOF__
write "app/quickjobs/routes.py" << '__OPSLAB_EOF__'
"""
Quick Jobs routes.

Admin (staff+):   /admin/jobs ...           create, view, schedule, delete
Public (no auth): /j/<token>                view details + (optionally) pick a day
"""
from datetime import datetime, date

from flask import (render_template, request, redirect, url_for, flash, abort)
from flask_login import login_required, current_user

from . import quickjobs_bp
from .. import db
from ..models_business import QuickJob, QuickJobItem, QUICKJOB_STATUS_META, Notification, AuditLog
from ..rbac import require_role, STAFF, is_staff_plus
from .. import billing


def _parse_price(raw):
    raw = (raw or "").strip().replace("£", "").replace(",", "")
    if not raw:
        return None
    try:
        return int(round(float(raw) * 100))
    except ValueError:
        return None


def _parse_day(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    except ValueError:
        return None


def _parse_qty(raw, default=1):
    try:
        return max(1, min(999, int(float(raw))))
    except (TypeError, ValueError):
        return default


def _notify_admin(job, title, msg):
    if job.created_by_id:
        Notification.push(job.created_by_id, title, msg,
                          url=url_for("quickjobs.admin_detail", job_id=job.id),
                          category="job")


# ════════════════════════════════════════════════ ADMIN ════════════════════
@quickjobs_bp.route("/admin/jobs")
@require_role(STAFF)
def admin_list():
    status = request.args.get("status") or ""
    q = QuickJob.query
    if status in QUICKJOB_STATUS_META:
        q = q.filter_by(status=status)
    jobs = q.order_by(QuickJob.created_at.desc()).all()
    return render_template("admin/jobs/list.html", jobs=jobs,
                           status_meta=QUICKJOB_STATUS_META, status=status)


@quickjobs_bp.route("/admin/jobs/new", methods=["GET", "POST"])
@require_role(STAFF)
def admin_new():
    if request.method == "POST":
        title = (request.form.get("title") or "").strip()
        if not title:
            flash("Give the job a title.", "error")
            return render_template("admin/jobs/form.html", job=None)
        job = QuickJob(
            token=QuickJob.gen_token(),
            title=title,
            details=(request.form.get("details") or "").strip() or None,
            location=(request.form.get("location") or "").strip() or None,
            contact_phone=(request.form.get("contact_phone") or "").strip() or None,
            price_cents=_parse_price(request.form.get("price")),
            client_name=(request.form.get("client_name") or "").strip() or None,
            client_email=(request.form.get("client_email") or "").strip() or None,
            client_phone=(request.form.get("client_phone") or "").strip() or None,
            allow_client_scheduling=bool(request.form.get("allow_client_scheduling")),
            allow_client_edits=bool(request.form.get("allow_client_edits")),
            created_by_id=current_user.id,
        )
        # Optional admin-set day at creation
        day = _parse_day(request.form.get("scheduled_day"))
        if day:
            job.scheduled_day = day
            job.scheduled_time = (request.form.get("scheduled_time") or "").strip() or None
            job.scheduled_by = "admin"
            job.status = "scheduled"
        db.session.add(job)
        db.session.flush()
        AuditLog.log("quickjob.create", actor=current_user, target_type="quick_job",
                     target_id=job.id, ip=request.remote_addr)
        db.session.commit()
        flash("Job created — share the link below.", "success")
        return redirect(url_for("quickjobs.admin_detail", job_id=job.id))
    return render_template("admin/jobs/form.html", job=None)


@quickjobs_bp.route("/admin/jobs/<int:job_id>")
@require_role(STAFF)
def admin_detail(job_id):
    job = QuickJob.query.get_or_404(job_id)
    share_url = url_for("quickjobs.public_view", token=job.token, _external=True)
    return render_template("admin/jobs/detail.html", job=job, share_url=share_url,
                           status_meta=QUICKJOB_STATUS_META,
                           stripe_on=billing.is_configured())


@quickjobs_bp.route("/admin/jobs/<int:job_id>/mark-paid", methods=["POST"])
@require_role(STAFF)
def admin_mark_paid(job_id):
    job = QuickJob.query.get_or_404(job_id)
    paid = request.form.get("paid") == "1"
    job.is_paid = paid
    job.paid_at = datetime.utcnow() if paid else None
    job.paid_via = "manual" if paid else None
    AuditLog.log("quickjob.mark_paid" if paid else "quickjob.mark_unpaid",
                 actor=current_user, target_type="quick_job", target_id=job.id,
                 ip=request.remote_addr)
    db.session.commit()
    flash("Marked as paid." if paid else "Marked as unpaid.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/edit", methods=["POST"])
@require_role(STAFF)
def admin_edit(job_id):
    job = QuickJob.query.get_or_404(job_id)
    job.title = (request.form.get("title") or job.title).strip()
    job.details = (request.form.get("details") or "").strip() or None
    job.location = (request.form.get("location") or "").strip() or None
    job.contact_phone = (request.form.get("contact_phone") or "").strip() or None
    job.price_cents = _parse_price(request.form.get("price"))
    job.client_name = (request.form.get("client_name") or "").strip() or None
    job.client_email = (request.form.get("client_email") or "").strip() or None
    job.client_phone = (request.form.get("client_phone") or "").strip() or None
    job.allow_client_scheduling = bool(request.form.get("allow_client_scheduling"))
    job.allow_client_edits = bool(request.form.get("allow_client_edits"))
    db.session.commit()
    flash("Job updated.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/items/add", methods=["POST"])
@require_role(STAFF)
def admin_item_add(job_id):
    job = QuickJob.query.get_or_404(job_id)
    label = (request.form.get("label") or "").strip()
    unit = _parse_price(request.form.get("unit_price")) or 0
    qty = _parse_qty(request.form.get("quantity"))
    if label:
        db.session.add(QuickJobItem(job_id=job.id, label=label[:200],
                                    unit_cents=unit, quantity=qty, source="admin"))
        db.session.commit()
        flash("Item added.", "success")
    else:
        flash("Give the item a name.", "error")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/items/<int:item_id>/remove", methods=["POST"])
@require_role(STAFF)
def admin_item_remove(job_id, item_id):
    job = QuickJob.query.get_or_404(job_id)
    item = QuickJobItem.query.filter_by(id=item_id, job_id=job.id).first_or_404()
    db.session.delete(item)
    db.session.commit()
    flash("Item removed.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/schedule", methods=["POST"])
@require_role(STAFF)
def admin_schedule(job_id):
    job = QuickJob.query.get_or_404(job_id)
    day = _parse_day(request.form.get("scheduled_day"))
    if day:
        job.scheduled_day = day
        job.scheduled_time = (request.form.get("scheduled_time") or "").strip() or None
        job.scheduled_by = "admin"
        if job.status == "new":
            job.status = "scheduled"
    else:
        # clearing the day reopens it
        job.scheduled_day = None
        job.scheduled_time = None
        job.scheduled_by = None
        if job.status == "scheduled":
            job.status = "new"
    AuditLog.log("quickjob.schedule", actor=current_user, target_type="quick_job",
                 target_id=job.id, meta={"day": str(job.scheduled_day)}, ip=request.remote_addr)
    db.session.commit()
    flash("Schedule updated.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/status", methods=["POST"])
@require_role(STAFF)
def admin_status(job_id):
    job = QuickJob.query.get_or_404(job_id)
    new = request.form.get("status")
    if new in QUICKJOB_STATUS_META:
        job.status = new
        db.session.commit()
        flash(f"Marked {QUICKJOB_STATUS_META[new]['label'].lower()}.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/regen-link", methods=["POST"])
@require_role(STAFF)
def admin_regen(job_id):
    job = QuickJob.query.get_or_404(job_id)
    job.token = QuickJob.gen_token()
    db.session.commit()
    flash("Share link regenerated — the old link no longer works.", "success")
    return redirect(url_for("quickjobs.admin_detail", job_id=job.id))


@quickjobs_bp.route("/admin/jobs/<int:job_id>/delete", methods=["POST"])
@require_role(STAFF)
def admin_delete(job_id):
    job = QuickJob.query.get_or_404(job_id)
    db.session.delete(job)
    AuditLog.log("quickjob.delete", actor=current_user, target_type="quick_job",
                 target_id=job_id, ip=request.remote_addr)
    db.session.commit()
    flash("Job deleted.", "success")
    return redirect(url_for("quickjobs.admin_list"))


# ════════════════════════════════════════════════ PUBLIC ═══════════════════
@quickjobs_bp.route("/j/<token>")
def public_view(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    return render_template("public/job.html", job=job, today=date.today().isoformat(),
                           stripe_on=billing.is_configured())


@quickjobs_bp.route("/j/<token>/pay", methods=["POST"])
def public_pay(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    if not job.is_payable_online:
        flash("This job isn't payable.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    success = url_for("quickjobs.public_view", token=token, paid=1, _external=True)
    cancel = url_for("quickjobs.public_view", token=token, _external=True)
    session, err = billing.create_checkout_for_quickjob(job, success, cancel)
    if err:
        flash(err, "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    return redirect(session.url, code=303)


@quickjobs_bp.route("/j/<token>/schedule", methods=["POST"])
def public_schedule(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    if not job.is_open_for_scheduling:
        flash("This job can't be scheduled here.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    day = _parse_day(request.form.get("scheduled_day"))
    if not day or day < date.today():
        flash("Please choose a valid date (today or later).", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    job.scheduled_day = day
    job.scheduled_time = (request.form.get("scheduled_time") or "").strip() or None
    job.scheduled_by = "client"
    job.status = "scheduled"
    # let the admin who created it know
    if job.created_by_id:
        when = job.scheduled_day.strftime("%d %b %Y") + (f" {job.scheduled_time}" if job.scheduled_time else "")
        Notification.push(job.created_by_id, "Job scheduled by client",
                          f"“{job.title}” booked for {when}.",
                          url=url_for("quickjobs.admin_detail", job_id=job.id),
                          category="job")
    AuditLog.log("quickjob.client_schedule", target_type="quick_job", target_id=job.id,
                 meta={"day": str(day)}, ip=request.remote_addr)
    db.session.commit()
    return redirect(url_for("quickjobs.public_view", token=token))


def _client_guard(job):
    """Returns a redirect response if the client may not edit, else None."""
    if not job.client_can_edit:
        flash("This job can no longer be changed online.", "error")
        return redirect(url_for("quickjobs.public_view", token=job.token))
    return None


@quickjobs_bp.route("/j/<token>/items/add", methods=["POST"])
def public_item_add(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    label = (request.form.get("label") or "").strip()
    unit = _parse_price(request.form.get("unit_price")) or 0
    qty = _parse_qty(request.form.get("quantity"))
    if not label:
        flash("Give the item a name.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    db.session.add(QuickJobItem(job_id=job.id, label=label[:200],
                                unit_cents=unit, quantity=qty, source="client"))
    _notify_admin(job, "Client added an item", f"“{label}” added to “{job.title}”.")
    AuditLog.log("quickjob.client_item_add", target_type="quick_job", target_id=job.id,
                 meta={"label": label}, ip=request.remote_addr)
    db.session.commit()
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/items/<int:item_id>/remove", methods=["POST"])
def public_item_remove(token, item_id):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    item = QuickJobItem.query.filter_by(id=item_id, job_id=job.id).first_or_404()
    db.session.delete(item)
    db.session.commit()
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/items/<int:item_id>/qty", methods=["POST"])
def public_item_qty(token, item_id):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    item = QuickJobItem.query.filter_by(id=item_id, job_id=job.id).first_or_404()
    action = request.form.get("action")
    if action == "inc":
        item.quantity = min(999, (item.quantity or 1) + 1)
    elif action == "dec":
        item.quantity = max(1, (item.quantity or 1) - 1)
    else:
        item.quantity = _parse_qty(request.form.get("quantity"), item.quantity or 1)
    db.session.commit()
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/details", methods=["POST"])
def public_details(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    job.client_name = (request.form.get("client_name") or "").strip() or None
    job.client_email = (request.form.get("client_email") or "").strip() or None
    job.client_phone = (request.form.get("client_phone") or "").strip() or None
    job.location = (request.form.get("location") or "").strip() or None
    _notify_admin(job, "Client updated their details", f"Contact/address changed on “{job.title}”.")
    AuditLog.log("quickjob.client_details", target_type="quick_job", target_id=job.id,
                 ip=request.remote_addr)
    db.session.commit()
    flash("Your details were saved.", "success")
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/reschedule", methods=["POST"])
def public_reschedule(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    blocked = _client_guard(job)
    if blocked:
        return blocked
    day = _parse_day(request.form.get("scheduled_day"))
    if not day or day < date.today():
        flash("Please choose a valid date (today or later).", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    job.scheduled_day = day
    job.scheduled_time = (request.form.get("scheduled_time") or "").strip() or None
    job.scheduled_by = "client"
    if job.status == "new":
        job.status = "scheduled"
    when = day.strftime("%d %b %Y") + (f" {job.scheduled_time}" if job.scheduled_time else "")
    _notify_admin(job, "Client rescheduled", f"“{job.title}” now set for {when}.")
    AuditLog.log("quickjob.client_reschedule", target_type="quick_job", target_id=job.id,
                 meta={"day": str(day)}, ip=request.remote_addr)
    db.session.commit()
    flash("Your day was updated.", "success")
    return redirect(url_for("quickjobs.public_view", token=token))


@quickjobs_bp.route("/j/<token>/cancel", methods=["POST"])
def public_cancel(token):
    job = QuickJob.query.filter_by(token=token).first_or_404()
    if job.is_paid:
        flash("This job is already paid — please contact us to cancel.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    if job.status == "cancelled":
        return redirect(url_for("quickjobs.public_view", token=token))
    if not job.allow_client_edits:
        flash("This job can't be cancelled online.", "error")
        return redirect(url_for("quickjobs.public_view", token=token))
    job.status = "cancelled"
    _notify_admin(job, "Client cancelled a job", f"“{job.title}” was cancelled by the client.")
    AuditLog.log("quickjob.client_cancel", target_type="quick_job", target_id=job.id,
                 ip=request.remote_addr)
    db.session.commit()
    flash("This job has been cancelled.", "success")
    return redirect(url_for("quickjobs.public_view", token=token))
__OPSLAB_EOF__
write "app/reviews/__init__.py" << '__OPSLAB_EOF__'
"""Public reviews / testimonials: submission, listing, homepage slider, moderation."""
from flask import Blueprint

reviews_bp = Blueprint("reviews", __name__)

from . import routes  # noqa: E402,F401
__OPSLAB_EOF__
write "app/reviews/routes.py" << '__OPSLAB_EOF__'
"""
Reviews / testimonials.

Public (no auth):
  GET  /reviews              all approved reviews
  GET  /reviews/new          submission form
  POST /reviews/new          create (shows immediately unless moderation is on)

Admin (staff+):
  GET  /admin/reviews                 moderate
  POST /admin/reviews/<id>/approve    toggle approved
  POST /admin/reviews/<id>/delete     remove
"""
import os
import json
import urllib.request
from datetime import datetime, timezone

from flask import render_template, request, redirect, url_for, flash, current_app
from flask_login import current_user

from . import reviews_bp
from .. import db
from ..models_business import Testimonial, TestimonialReply, Notification, AuditLog
from ..models_admin import Setting
from ..rbac import require_role, STAFF

WEBHOOK_SETTING = "reviews_discord_webhook"

_RATING_COLOR = {5: 0xFFD700, 4: 0x4ADE80, 3: 0x60A5FA, 2: 0xF59E0B, 1: 0xEF4444}


def _webhook_url():
    return (Setting.get(WEBHOOK_SETTING) or os.environ.get("REVIEWS_DISCORD_WEBHOOK") or "").strip()


def _post_discord(url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json", "User-Agent": "OpsLab-Reviews/1.0"},
    )
    with urllib.request.urlopen(req, timeout=6) as resp:  # noqa: S310 (trusted admin URL)
        return resp.status


def _review_embed(t, reviews_url):
    r = max(1, min(5, int(t.rating or 5)))
    stars = "★" * r + "☆" * (5 - r)
    body = (t.body or "").strip()
    if len(body) > 1500:
        body = body[:1497] + "…"
    fields = []
    if t.organisation:
        fields.append({"name": "Business / community", "value": t.organisation[:256], "inline": True})
    if t.country:
        fields.append({"name": "Country", "value": t.country[:256], "inline": True})
    return {
        "title": f"{stars}  New {r}-star review",
        "description": f">>> {body}" if body else "",
        "url": reviews_url,
        "color": _RATING_COLOR.get(r, 0x2196F3),
        "author": {"name": t.name[:256]},
        "fields": fields,
        "footer": {"text": "OpsLab Systems · Reviews"},
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def notify_review(t):
    """Post a new review to Discord if a webhook is configured. Never raises."""
    url = _webhook_url()
    if not url:
        return False
    try:
        reviews_url = url_for("reviews.index", _external=True)
    except Exception:
        reviews_url = "https://web.opslabsystems.cloud/reviews"
    payload = {
        "username": "OpsLab Reviews",
        "embeds": [_review_embed(t, reviews_url)],
    }
    try:
        _post_discord(url, payload)
        try:
            t.posted_to_discord = True
            db.session.commit()
        except Exception:
            db.session.rollback()
        return True
    except Exception as e:
        try:
            current_app.logger.warning("Discord review webhook failed: %s", e)
        except Exception:
            pass
        return False


def _is_staff_user():
    return current_user.is_authenticated and (
        getattr(current_user, "is_staff", False) or getattr(current_user, "is_admin", False))


def _clamp_rating(raw, default=5):
    try:
        return max(1, min(5, int(float(raw))))
    except (TypeError, ValueError):
        return default


# ════════════════════════════════════════════════ PUBLIC ═══════════════════
@reviews_bp.route("/reviews")
def index():
    items = (Testimonial.query.filter_by(approved=True)
             .order_by(Testimonial.created_at.desc()).all())
    avg = round(sum(t.rating_clamped for t in items) / len(items), 1) if items else None
    return render_template("reviews/index.html", reviews=items, avg=avg, count=len(items))


@reviews_bp.route("/reviews/new", methods=["GET", "POST"])
def new():
    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        body = (request.form.get("body") or "").strip()
        rating = _clamp_rating(request.form.get("rating"))
        if not name or not body:
            flash("Please add your name and a short review.", "error")
            return render_template("reviews/new.html", form=request.form)
        t = Testimonial(
            name=name[:120],
            organisation=(request.form.get("organisation") or "").strip()[:160] or None,
            country=(request.form.get("country") or "").strip()[:80] or None,
            rating=rating,
            body=body[:2000],
            approved=True,   # show immediately; flip to False here to moderate first
        )
        db.session.add(t)
        db.session.flush()
        # notify the default admin (id is not known here; notify all staff via audit)
        AuditLog.log("review.create", target_type="testimonial", target_id=t.id,
                     meta={"name": name, "rating": rating}, ip=request.remote_addr)
        db.session.commit()
        if t.approved:
            notify_review(t)
        flash("Thank you! Your review has been posted.", "success")
        return redirect(url_for("reviews.index"))
    return render_template("reviews/new.html", form={})


@reviews_bp.route("/reviews/<int:rid>/reply", methods=["POST"])
def reply(rid):
    t = Testimonial.query.get_or_404(rid)
    body = (request.form.get("body") or "").strip()
    staff = _is_staff_user()
    name = (current_user.username if staff else (request.form.get("name") or "").strip())
    if not body or not name:
        flash("Please add your name and a message.", "error")
        return redirect(url_for("reviews.index") + f"#review-{t.id}")
    db.session.add(TestimonialReply(testimonial_id=t.id, name=name[:120],
                                    body=body[:2000], is_staff=staff))
    AuditLog.log("review.reply", target_type="testimonial", target_id=t.id,
                 meta={"staff": staff}, ip=request.remote_addr)
    db.session.commit()
    flash("Reply posted.", "success")
    return redirect(url_for("reviews.index") + f"#review-{t.id}")


@reviews_bp.route("/reviews/reply/<int:reply_id>/delete", methods=["POST"])
@require_role(STAFF)
def delete_reply(reply_id):
    rep = TestimonialReply.query.get_or_404(reply_id)
    tid = rep.testimonial_id
    db.session.delete(rep)
    AuditLog.log("review.reply_delete", actor=current_user, target_type="testimonial",
                 target_id=tid, ip=request.remote_addr)
    db.session.commit()
    flash("Reply deleted.", "success")
    return redirect(url_for("reviews.index") + f"#review-{tid}")


# ════════════════════════════════════════════════ ADMIN ════════════════════
@reviews_bp.route("/admin/reviews")
@require_role(STAFF)
def admin_list():
    show = request.args.get("show", "all")
    q = Testimonial.query
    if show == "pending":
        q = q.filter_by(approved=False)
    elif show == "approved":
        q = q.filter_by(approved=True)
    items = q.order_by(Testimonial.created_at.desc()).all()
    return render_template("admin/reviews/list.html", reviews=items, show=show,
                           webhook_set=bool(_webhook_url()))


@reviews_bp.route("/admin/reviews/<int:rid>/approve", methods=["POST"])
@require_role(STAFF)
def admin_approve(rid):
    t = Testimonial.query.get_or_404(rid)
    t.approved = not t.approved
    AuditLog.log("review.approve" if t.approved else "review.hide",
                 actor=current_user, target_type="testimonial", target_id=t.id,
                 ip=request.remote_addr)
    db.session.commit()
    if t.approved:
        notify_review(t)
    flash("Review shown." if t.approved else "Review hidden.", "success")
    return redirect(url_for("reviews.admin_list", show=request.args.get("show", "all")))


@reviews_bp.route("/admin/reviews/<int:rid>/post", methods=["POST"])
@require_role(STAFF)
def admin_post(rid):
    t = Testimonial.query.get_or_404(rid)
    if not _webhook_url():
        flash("Set a Discord webhook URL first.", "error")
    elif t.posted_to_discord:
        flash("That review has already been posted.", "success")
    elif notify_review(t):
        flash("Review posted to Discord.", "success")
    else:
        flash("Couldn't reach Discord. Check the webhook URL.", "error")
    return redirect(url_for("reviews.admin_list", show=request.args.get("show", "all")))


@reviews_bp.route("/admin/reviews/webhook", methods=["POST"])
@require_role(STAFF)
def admin_webhook():
    action = request.form.get("action")
    if action == "save":
        url = (request.form.get("webhook_url") or "").strip()
        Setting.set(WEBHOOK_SETTING, url, kind="string", category="reviews")
        AuditLog.log("review.webhook_set", actor=current_user, ip=request.remote_addr)
        flash("Discord webhook saved." if url else "Discord webhook cleared.", "success")
    elif action == "test":
        url = _webhook_url()
        if not url:
            flash("Save a webhook URL first.", "error")
        else:
            ok = False
            try:
                ok = _post_discord(url, {
                    "username": "OpsLab Reviews",
                    "embeds": [{
                        "title": "✅ Test message",
                        "description": "Your reviews webhook is connected. New reviews will appear here.",
                        "color": 0x2196F3,
                        "footer": {"text": "OpsLab Systems · Reviews"},
                    }],
                }) in (200, 204)
            except Exception:
                ok = False
            flash("Test sent — check your Discord channel." if ok else
                  "Couldn't reach Discord. Check the webhook URL.", "success" if ok else "error")
    return redirect(url_for("reviews.admin_list", show=request.args.get("show", "all")))


@reviews_bp.route("/admin/reviews/<int:rid>/delete", methods=["POST"])
@require_role(STAFF)
def admin_delete(rid):
    t = Testimonial.query.get_or_404(rid)
    db.session.delete(t)
    AuditLog.log("review.delete", actor=current_user, target_type="testimonial",
                 target_id=rid, ip=request.remote_addr)
    db.session.commit()
    flash("Review deleted.", "success")
    return redirect(url_for("reviews.admin_list", show=request.args.get("show", "all")))
__OPSLAB_EOF__
write "app/callouts/__init__.py" << '__OPSLAB_EOF__'
"""Public 'Book a call-out' / meeting requests + admin handling."""
from flask import Blueprint

callouts_bp = Blueprint("callouts", __name__)

from . import routes  # noqa: E402,F401
__OPSLAB_EOF__
write "app/callouts/routes.py" << '__OPSLAB_EOF__'
"""
Book a call-out / meeting requests.

Public (no auth):
  GET  /callout            booking form
  POST /callout            submit request

Admin (staff+):
  GET  /admin/callouts                 list
  POST /admin/callouts/<id>/status     update status
  POST /admin/callouts/<id>/delete     remove
"""
from datetime import datetime

from flask import render_template, request, redirect, url_for, flash, jsonify
from flask_login import current_user

from . import callouts_bp
from .services import SERVICE_GROUPS, OTHER_LABEL, all_labels, price_display
from .. import db
from ..models_business import (MeetingRequest, MEETING_MODE_META,
                               MEETING_STATUS_META, Notification, AuditLog)
from ..models_admin import Setting
from ..rbac import require_role, STAFF


def _prices():
    """Dict of {service label: stored value} from Settings."""
    data = Setting.get("callout_prices", {})
    return data if isinstance(data, dict) else {}


def _price_texts():
    """{label: display string} for the public form / details."""
    out = {}
    for label, val in _prices().items():
        disp = price_display(val)
        if disp:
            out[label] = disp
    return out


def _price_inputs():
    """{label: editable string} for the admin form (legacy pence -> pounds)."""
    out = {}
    for label, val in _prices().items():
        if isinstance(val, (int, float)) and not isinstance(val, bool):
            out[label] = "{:.2f}".format(val / 100)
        elif val:
            out[label] = str(val)
    return out


def _clean_price(raw):
    """Keep whatever the admin typed (range/text/number), trimmed."""
    raw = (raw or "").strip()
    return raw or None


def _parse_day(raw):
    raw = (raw or "").strip()
    if not raw:
        return None
    try:
        return datetime.strptime(raw, "%Y-%m-%d").date()
    except ValueError:
        return None


# ════════════════════════════════════════════════ PUBLIC ═══════════════════
@callouts_bp.route("/callout", methods=["GET", "POST"])
def book():
    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        mode = request.form.get("mode")
        if mode not in MEETING_MODE_META:
            mode = "in_person"
        email = (request.form.get("email") or "").strip()
        phone = (request.form.get("phone") or "").strip()
        service = (request.form.get("service") or "").strip()
        other_detail = (request.form.get("other_detail") or "").strip()
        if not name or not phone:
            flash("Please add your name and a phone number so we can reach you.", "error")
            return render_template("public/callout.html", modes=MEETING_MODE_META, form=request.form,
                                   service_groups=SERVICE_GROUPS, prices=_price_texts(), other_label=OTHER_LABEL)
        if not service:
            flash("Please choose what you need help with.", "error")
            return render_template("public/callout.html", modes=MEETING_MODE_META, form=request.form,
                                   service_groups=SERVICE_GROUPS, prices=_price_texts(), other_label=OTHER_LABEL)
        if service == OTHER_LABEL and not other_detail:
            flash("Please describe what you need.", "error")
            return render_template("public/callout.html", modes=MEETING_MODE_META, form=request.form,
                                   service_groups=SERVICE_GROUPS, prices=_price_texts(), other_label=OTHER_LABEL)
        prices = _prices()
        if service == OTHER_LABEL:
            details = "Other: " + other_detail
        else:
            details = service
            est = prices.get(service)
            disp = price_display(est) if est else None
            if disp:
                details = f"{service} (est. {disp})"
        req = MeetingRequest(
            name=name[:120],
            email=email[:160] or None,
            phone=phone[:40] or None,
            mode=mode,
            location=(request.form.get("location") or "").strip()[:200] or None,
            preferred_day=_parse_day(request.form.get("preferred_day")),
            preferred_time=(request.form.get("preferred_time") or "").strip() or None,
            details=details[:2000] or None,
        )
        db.session.add(req)
        db.session.flush()
        AuditLog.log("meeting.request", target_type="meeting_request", target_id=req.id,
                     meta={"name": name, "mode": mode}, ip=request.remote_addr)
        # notify all staff
        from ..models import User
        for u in User.query.filter(User.role.in_(("staff", "support", "admin", "super_admin"))).all():
            Notification.push(u.id, "New call-out request",
                              f"{name} — {req.mode_meta['label']}.",
                              url=url_for("callouts.admin_list"), category="meeting")
        db.session.commit()
        return redirect(url_for("callouts.book", sent=1))
    return render_template("public/callout.html", modes=MEETING_MODE_META,
                           form={}, sent=request.args.get("sent"),
                           service_groups=SERVICE_GROUPS, prices=_price_texts(), other_label=OTHER_LABEL)


# ════════════════════════════════════════════════ ADMIN ════════════════════
@callouts_bp.route("/admin/callouts")
@require_role(STAFF)
def admin_list():
    status = request.args.get("status") or ""
    q = MeetingRequest.query
    if status in MEETING_STATUS_META:
        q = q.filter_by(status=status)
    items = q.order_by(MeetingRequest.created_at.desc()).all()
    return render_template("admin/callouts/list.html", items=items,
                           status_meta=MEETING_STATUS_META, status=status)


@callouts_bp.route("/admin/callouts/<int:rid>/status", methods=["POST"])
@require_role(STAFF)
def admin_status(rid):
    req = MeetingRequest.query.get_or_404(rid)
    new = request.form.get("status")
    if new in MEETING_STATUS_META:
        req.status = new
        AuditLog.log("meeting.status", actor=current_user, target_type="meeting_request",
                     target_id=req.id, meta={"status": new}, ip=request.remote_addr)
        db.session.commit()
        flash("Status updated.", "success")
    return redirect(url_for("callouts.admin_list", status=request.args.get("status", "")))


@callouts_bp.route("/admin/callouts/<int:rid>/delete", methods=["POST"])
@require_role(STAFF)
def admin_delete(rid):
    req = MeetingRequest.query.get_or_404(rid)
    db.session.delete(req)
    AuditLog.log("meeting.delete", actor=current_user, target_type="meeting_request",
                 target_id=rid, ip=request.remote_addr)
    db.session.commit()
    flash("Request deleted.", "success")
    return redirect(url_for("callouts.admin_list", status=request.args.get("status", "")))


@callouts_bp.route("/admin/callout-prices", methods=["GET"])
@require_role(STAFF)
def admin_prices():
    return render_template("admin/callouts/prices.html",
                           service_groups=SERVICE_GROUPS, prices=_price_inputs(),
                           other_label=OTHER_LABEL)


# ── Public, live-updating price list ─────────────────────────────────────
@callouts_bp.route("/pricing")
def pricing():
    return render_template("public/pricing.html",
                           service_groups=SERVICE_GROUPS, prices=_price_texts(),
                           other_label=OTHER_LABEL)


@callouts_bp.route("/pricing.json")
def pricing_json():
    return jsonify(_price_texts())


@callouts_bp.route("/admin/callout-prices", methods=["POST"])
@require_role(STAFF)
def admin_prices_save():
    new = {}
    for label in all_labels():
        if label == OTHER_LABEL:
            continue
        val = _clean_price(request.form.get(label))
        if val is not None:
            new[label] = val
    Setting.set("callout_prices", new, kind="json", category="callouts")
    AuditLog.log("meeting.prices", actor=current_user, ip=request.remote_addr)
    flash("Estimated prices saved.", "success")
    return redirect(url_for("callouts.admin_prices"))
__OPSLAB_EOF__
write "app/callouts/services.py" << '__OPSLAB_EOF__'
"""Shared list of call-out services. Prices are set in the admin area and
stored in Settings (key 'callout_prices' = {label: pence})."""

OTHER_LABEL = "Other (please specify)"

SERVICE_GROUPS = [
    ("Internet & Network Issues", [
        "Slow internet speeds",
        "Slow loading in some parts of the house/building",
        "Internet connection dropping out",
        "Wi-Fi coverage issues",
        "Poor Wi-Fi signal",
        "Device cannot connect to Wi-Fi",
        "General network troubleshooting",
    ]),
    ("Router & Wi-Fi Setup", [
        "New router installation/setup",
        "Router replacement",
        "Wi-Fi optimization",
        "Guest Wi-Fi setup",
        "Mesh Wi-Fi installation",
    ]),
    ("CCTV & Security Systems", [
        "New CCTV system installation",
        "CCTV upgrade",
        "Additional CCTV cameras",
        "CCTV troubleshooting",
        "Remote viewing setup",
    ]),
    ("Cabling & Hardwired Connections", [
        "New network cabling installation",
        "Hardwired internet connection required in a specific room",
        "Extend an existing network cable",
        "Additional Ethernet/network socket required",
        "Home office network connection",
        "Gaming room network connection",
        "Structured cabling installation",
        "Network cabinet/rack setup",
    ]),
    ("Property & Business Networking", [
        "Full home network installation",
        "Office network installation",
        "Network expansion",
        "Network relocation",
        "New property network setup",
    ]),
    ("Other Services", [
        "Network health check",
        "Internet performance review",
        "General advice and consultation",
        OTHER_LABEL,
    ]),
]


def all_labels():
    out = []
    for _grp, opts in SERVICE_GROUPS:
        out.extend(opts)
    return out


def price_display(val):
    """Render a stored price for display. Supports free text ('100-200',
    'From £100', 'POA') and legacy integer pence."""
    if val is None:
        return None
    if isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        return "£{:,.2f}".format(val / 100)
    s = str(val).strip()
    if not s:
        return None
    # bare number/range like "100" or "100-200" -> prefix a single £
    if s[0].isdigit():
        return "£" + s
    return s
__OPSLAB_EOF__
write "app/site/__init__.py" << '__OPSLAB_EOF__'
"""Entry gateway + on-site services page (kept separate from main.py)."""
from flask import Blueprint

site_bp = Blueprint("site", __name__)

from . import routes  # noqa: E402,F401
__OPSLAB_EOF__
write "app/site/routes.py" << '__OPSLAB_EOF__'
"""
Entry gateway routes.

  GET /enter?to=cloud|onsite   remember the visitor's choice, then send them on
  GET /onsitesupport           on-site / in-person services page

The gateway screen itself is shown by a before_request hook in app/__init__.py
whenever an anonymous visitor hits "/" without having chosen yet.
"""
from flask import redirect, url_for, request, render_template, make_response

from . import site_bp

# How long to remember the choice (seconds). Session-length feel: re-ask on a
# brand-new visit but never nag while they browse. ~12 hours.
ENTRY_COOKIE = "ols_entry"
ENTRY_MAXAGE = 60 * 60 * 12


@site_bp.route("/enter")
def enter():
    to = request.args.get("to")
    if to == "onsite":
        resp = make_response(redirect(url_for("site.onsitesupport")))
    else:
        resp = make_response(redirect(url_for("main.index")))
    resp.set_cookie(ENTRY_COOKIE, to or "cloud", max_age=ENTRY_MAXAGE, samesite="Lax")
    return resp


@site_bp.route("/onsitesupport")
def onsitesupport():
    # mark as entered so returning to "/" doesn't re-show the gateway
    resp = make_response(render_template("onsitesupport.html"))
    if not request.cookies.get(ENTRY_COOKIE):
        resp.set_cookie(ENTRY_COOKIE, "onsite", max_age=ENTRY_MAXAGE, samesite="Lax")
    return resp
__OPSLAB_EOF__
write "app/sso/__init__.py" << '__OPSLAB_EOF__'
"""Multi-provider SSO (Google, Microsoft, GitHub, Discord, Facebook, GitLab,
generic OIDC). Providers enable themselves when their env credentials exist."""
import os
from flask import Blueprint
from authlib.integrations.flask_client import OAuth

from .providers import PROVIDERS

sso_bp = Blueprint("sso", __name__)
oauth = OAuth()

# providers successfully registered at startup (id -> meta), for the login page
ENABLED = {}


def _env(key, suffix):
    return os.environ.get(f"{key.upper()}_{suffix}")


def init_sso(app):
    """Register OAuth clients for every provider that has credentials set."""
    oauth.init_app(app)
    ENABLED.clear()

    for pid, meta in PROVIDERS.items():
        cid = _env(pid, "CLIENT_ID")
        secret = _env(pid, "CLIENT_SECRET")
        if not cid or not secret:
            continue
        kwargs = {"client_id": cid, "client_secret": secret,
                  "client_kwargs": {"scope": meta["scope"]}}
        if meta["kind"] == "oidc":
            kwargs["server_metadata_url"] = meta["server_metadata_url"]
        else:
            kwargs["authorize_url"] = meta["authorize_url"]
            kwargs["access_token_url"] = meta["access_token_url"]
            kwargs["api_base_url"] = meta.get("api_base_url")
        try:
            oauth.register(name=pid, **kwargs)
            ENABLED[pid] = meta
        except Exception:
            pass

    # Generic OIDC (any provider) via OIDC_* env
    oidc_id = os.environ.get("OIDC_CLIENT_ID")
    oidc_secret = os.environ.get("OIDC_CLIENT_SECRET")
    oidc_meta = os.environ.get("OIDC_METADATA_URL")
    if oidc_id and oidc_secret and oidc_meta:
        try:
            oauth.register(name="oidc", client_id=oidc_id, client_secret=oidc_secret,
                           server_metadata_url=oidc_meta,
                           client_kwargs={"scope": os.environ.get("OIDC_SCOPE", "openid email profile")})
            ENABLED["oidc"] = {"label": os.environ.get("OIDC_NAME", "SSO"),
                               "color": "#334155", "text": "#ffffff", "kind": "oidc",
                               "icon": "M12 2a10 10 0 100 20 10 10 0 000-20zm0 4a3 3 0 110 6 3 3 0 010-6zm0 14a8 8 0 01-5.3-2c.1-1.6 3.5-2.5 5.3-2.5s5.2.9 5.3 2.5A8 8 0 0112 20z"}
        except Exception:
            pass

    app.config["SSO_ENABLED"] = ENABLED

from . import routes  # noqa: E402,F401
__OPSLAB_EOF__
write "app/sso/providers.py" << '__OPSLAB_EOF__'
"""
SSO provider catalogue. A provider switches on automatically when its
CLIENT_ID + CLIENT_SECRET env vars are present.

Env var names per provider:  <KEY>_CLIENT_ID / <KEY>_CLIENT_SECRET
e.g. GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET

Generic OIDC (any provider) uses:
  OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_METADATA_URL, OIDC_NAME (optional)
"""

# label / brand colour / simple inline SVG path(s) for the button icon
# kind: "oidc" (uses server_metadata_url) or "oauth2" (explicit endpoints)
PROVIDERS = {
    "google": {
        "label": "Google", "color": "#ffffff", "text": "#1f2937",
        "kind": "oidc",
        "server_metadata_url": "https://accounts.google.com/.well-known/openid-configuration",
        "scope": "openid email profile",
        "icon": "M21.35 11.1H12v3.2h5.35c-.25 1.6-1.7 4.7-5.35 4.7A6 6 0 1112 6.3a5.3 5.3 0 013.75 1.45l2.2-2.2A8.9 8.9 0 0012 3.2 8.8 8.8 0 1020.8 12c0-.6-.05-1-.15-1.5z",
    },
    "microsoft": {
        "label": "Microsoft", "color": "#2f2f2f", "text": "#ffffff",
        "kind": "oidc",
        "server_metadata_url": "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration",
        "scope": "openid email profile",
        "icon": "M3 3h8v8H3V3zm10 0h8v8h-8V3zM3 13h8v8H3v-8zm10 0h8v8h-8v-8z",
    },
    "github": {
        "label": "GitHub", "color": "#24292f", "text": "#ffffff",
        "kind": "oauth2",
        "authorize_url": "https://github.com/login/oauth/authorize",
        "access_token_url": "https://github.com/login/oauth/access_token",
        "api_base_url": "https://api.github.com/",
        "userinfo": "https://api.github.com/user",
        "emails_url": "https://api.github.com/user/emails",
        "scope": "read:user user:email",
        "icon": "M12 2a10 10 0 00-3.16 19.49c.5.09.68-.22.68-.48l-.01-1.7c-2.78.6-3.37-1.34-3.37-1.34-.46-1.16-1.11-1.47-1.11-1.47-.9-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.9 1.52 2.34 1.08 2.91.83.09-.65.35-1.09.63-1.34-2.22-.25-4.55-1.11-4.55-4.94 0-1.09.39-1.98 1.03-2.68-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.02a9.6 9.6 0 015 0c1.9-1.29 2.74-1.02 2.74-1.02.55 1.38.2 2.4.1 2.65.64.7 1.03 1.59 1.03 2.68 0 3.84-2.34 4.68-4.57 4.93.36.31.68.92.68 1.85l-.01 2.75c0 .27.18.58.69.48A10 10 0 0012 2z",
    },
    "discord": {
        "label": "Discord", "color": "#5865F2", "text": "#ffffff",
        "kind": "oauth2",
        "authorize_url": "https://discord.com/oauth2/authorize",
        "access_token_url": "https://discord.com/api/oauth2/token",
        "api_base_url": "https://discord.com/api/",
        "userinfo": "https://discord.com/api/users/@me",
        "scope": "identify email",
        "icon": "M20.3 4.3A19 19 0 0015.6 3l-.2.5c1.7.4 2.6.9 3.6 1.6a13 13 0 00-11.9 0c1-.7 2-1.2 3.6-1.6L10.4 3a19 19 0 00-4.7 1.3C2.7 8.8 2 13.2 2.2 17.6a19 19 0 005.8 2.9l.5-1c-.6-.2-1.3-.5-2-1l.4-.3a13.6 13.6 0 0011.6 0l.4.3c-.7.5-1.4.8-2 1l.5 1a19 19 0 005.8-2.9c.4-5-.8-9.4-2.9-13.3zM9.3 15c-.9 0-1.7-.8-1.7-1.9s.8-1.9 1.7-1.9 1.7.9 1.7 1.9-.8 1.9-1.7 1.9zm5.4 0c-.9 0-1.7-.8-1.7-1.9s.8-1.9 1.7-1.9 1.7.9 1.7 1.9-.8 1.9-1.7 1.9z",
    },
    "facebook": {
        "label": "Facebook", "color": "#1877F2", "text": "#ffffff",
        "kind": "oauth2",
        "authorize_url": "https://www.facebook.com/v17.0/dialog/oauth",
        "access_token_url": "https://graph.facebook.com/v17.0/oauth/access_token",
        "api_base_url": "https://graph.facebook.com/",
        "userinfo": "https://graph.facebook.com/me?fields=id,name,email",
        "scope": "email public_profile",
        "icon": "M22 12a10 10 0 10-11.6 9.9v-7H7.9V12h2.5V9.8c0-2.5 1.5-3.9 3.8-3.9 1.1 0 2.2.2 2.2.2v2.5h-1.3c-1.2 0-1.6.8-1.6 1.6V12h2.8l-.4 2.9h-2.3v7A10 10 0 0022 12z",
    },
    "gitlab": {
        "label": "GitLab", "color": "#fc6d26", "text": "#1f2937",
        "kind": "oidc",
        "server_metadata_url": "https://gitlab.com/.well-known/openid-configuration",
        "scope": "openid email profile",
        "icon": "M23 13.4l-1.1-3.4-2.2-6.8c-.1-.3-.6-.3-.7 0L16.8 9.9H7.2L5 3.2c-.1-.3-.6-.3-.7 0L2.1 10 .9 13.4c-.1.3 0 .7.3.9L12 22l10.7-7.7c.3-.2.4-.6.3-.9z",
    },
}


def parse_identity(provider, userinfo):
    """Return (sub, email, name) from a provider's userinfo payload."""
    if not userinfo:
        return None, None, None
    if provider == "github":
        sub = str(userinfo.get("id"))
        return sub, userinfo.get("email"), userinfo.get("name") or userinfo.get("login")
    if provider == "discord":
        sub = str(userinfo.get("id"))
        name = userinfo.get("global_name") or userinfo.get("username")
        return sub, userinfo.get("email"), name
    if provider == "facebook":
        return str(userinfo.get("id")), userinfo.get("email"), userinfo.get("name")
    # OIDC-style (google, microsoft, gitlab, generic)
    sub = userinfo.get("sub") or userinfo.get("id")
    name = userinfo.get("name") or userinfo.get("preferred_username")
    return (str(sub) if sub is not None else None), userinfo.get("email"), name
__OPSLAB_EOF__
write "app/sso/routes.py" << '__OPSLAB_EOF__'
"""SSO login flow:  /auth/sso/<provider>  ->  /auth/sso/<provider>/callback"""
import secrets
from urllib.parse import urlparse

from flask import (redirect, url_for, request, flash, session, current_app)
from flask_login import login_user

from . import sso_bp, oauth, ENABLED
from .providers import PROVIDERS, parse_identity
from .. import db
from ..models import User
from ..models_business import OAuthAccount, AuditLog


def _safe_next(target):
    if target and target.startswith("/") and not target.startswith("//"):
        return target
    return None


@sso_bp.route("/<provider>")
def start(provider):
    if provider not in ENABLED:
        flash("That sign-in method isn't available.", "error")
        return redirect(url_for("auth.login"))
    client = oauth.create_client(provider)
    if client is None:
        flash("That sign-in method isn't configured.", "error")
        return redirect(url_for("auth.login"))
    nxt = _safe_next(request.args.get("next"))
    if nxt:
        session["sso_next"] = nxt
    redirect_uri = url_for("sso.callback", provider=provider, _external=True)
    return client.authorize_redirect(redirect_uri)


@sso_bp.route("/<provider>/callback")
def callback(provider):
    if provider not in ENABLED:
        flash("That sign-in method isn't available.", "error")
        return redirect(url_for("auth.login"))
    client = oauth.create_client(provider)
    try:
        token = client.authorize_access_token()
    except Exception:
        flash("Sign-in was cancelled or failed. Please try again.", "error")
        return redirect(url_for("auth.login"))

    # ---- fetch userinfo ----
    meta = ENABLED[provider]
    userinfo = None
    if meta.get("kind") == "oidc" or provider == "oidc":
        userinfo = token.get("userinfo")
        if not userinfo:
            try:
                userinfo = client.userinfo()
            except Exception:
                userinfo = None
    else:
        try:
            resp = client.get(PROVIDERS[provider]["userinfo"], token=token)
            userinfo = resp.json()
        except Exception:
            userinfo = None
        # GitHub can hide the email — pull the primary verified one
        if provider == "github" and userinfo is not None and not userinfo.get("email"):
            try:
                emails = client.get(PROVIDERS[provider]["emails_url"], token=token).json()
                primary = next((e for e in emails if e.get("primary") and e.get("verified")), None)
                if primary:
                    userinfo["email"] = primary.get("email")
            except Exception:
                pass

    sub, email, name = parse_identity(provider if provider in PROVIDERS else "oidc", userinfo)
    if not sub:
        flash("Couldn't read your account from that provider.", "error")
        return redirect(url_for("auth.login"))

    # ---- find or create the user ----
    link = OAuthAccount.query.filter_by(provider=provider, sub=sub).first()
    user = link.user if link else None

    if user is None and email:
        user = User.query.filter(db.func.lower(User.email) == email.lower()).first()

    if user is None:
        if not email:
            flash("That provider didn't share an email, so we can't create an account.", "error")
            return redirect(url_for("auth.login"))
        user = User(
            username=_unique_username(email, name),
            email=email,
            role="user",
            is_active=True,
        )
        user.set_password(secrets.token_urlsafe(24))  # random; they log in via SSO
        db.session.add(user)
        db.session.flush()

    if link is None:
        db.session.add(OAuthAccount(provider=provider, sub=sub, user_id=user.id, email=email))

    if not user.is_active:
        flash("Your account is disabled. Please contact support.", "error")
        return redirect(url_for("auth.login"))

    db.session.commit()
    try:
        AuditLog.log("auth.sso_login", actor=user, target_type="user", target_id=user.id,
                     meta={"provider": provider}, ip=request.remote_addr)
        db.session.commit()
    except Exception:
        db.session.rollback()

    login_user(user, remember=True)
    nxt = _safe_next(session.pop("sso_next", None))
    dest = nxt or (url_for("portal.dashboard") if _has_portal() else url_for("main.index"))
    return redirect(dest)


def _has_portal():
    return "portal.dashboard" in current_app.view_functions


def _unique_username(email, name):
    base = (email.split("@")[0] if email else (name or "user")).strip().lower()
    base = "".join(c for c in base if c.isalnum() or c in "._-") or "user"
    base = base[:50]
    candidate = base
    n = 1
    while User.query.filter_by(username=candidate).first():
        n += 1
        candidate = f"{base}{n}"
    return candidate
__OPSLAB_EOF__
write "app/partners/__init__.py" << '__OPSLAB_EOF__'
from flask import Blueprint

partners_bp = Blueprint("partners", __name__)

from . import routes  # noqa: E402,F401
__OPSLAB_EOF__
write "app/partners/routes.py" << '__OPSLAB_EOF__'
"""Partner Portal — agreement acceptance, company registration, status
dashboard, public company page, and admin review workflow."""
from flask import (render_template, request, redirect, url_for, flash, abort)
from flask_login import login_required, current_user

from . import partners_bp
from .. import db
from ..models_business import (PartnerCompany, PartnerAgreementAcceptance,
                               PARTNER_TYPE_CHOICES, PARTNER_LEGAL_CHOICES,
                               PARTNER_STATUS_META, AGREEMENT_VERSION_DEFAULT, AuditLog)
from ..models_admin import Setting
from ..rbac import require_role, STAFF

RESERVED_SLUGS = {"new", "mine", "agreement", "admin", "p"}

DEFAULT_AGREEMENT = """OpsLab Systems — Partner & Independent Service Provider Agreement

This is a template agreement provided for convenience. Replace it with your own
solicitor-reviewed text in Admin → Partners before relying on it.

1. Independent Contractor Status
You operate as an independent business. Nothing in this agreement creates an
employment, partnership, agency or joint-venture relationship between you and
OpsLab Systems. You are solely responsible for your own taxes, insurance and
legal obligations.

2. Service Responsibility
You are responsible for the services, goods and support you offer through your
company profile. OpsLab Systems provides the hosting platform only and is not a
party to transactions between you and your customers.

3. Refund Policy Requirements
You must offer a clear refund policy. For digital goods you must provide a
minimum 24-hour refund window from the time of purchase, unless a longer period
is required by law in your or your customer's jurisdiction.

4. Complaints & Warning System
Customer complaints may be reviewed by OpsLab Systems. Repeated or serious
complaints may result in warnings. Accumulated warnings may lead to suspension
or removal of your company profile.

5. Prohibited Conduct
You must not use the platform for unlawful activity, fraud, misleading claims,
infringement of intellectual property, harassment, malware, or any content that
is illegal or harmful. You must provide accurate legal information.

6. Termination Rights
Either party may end this arrangement at any time. OpsLab Systems may suspend or
remove a company profile at its discretion, including for breach of this
agreement or false information.

7. Liability Limitations
The platform is provided "as is". To the maximum extent permitted by law,
OpsLab Systems is not liable for losses arising from your services, downtime,
or data loss. Nothing limits liability that cannot be limited by law.

8. Conduct Expectations
You agree to deal honestly and professionally with customers and with OpsLab
Systems, to respond to reasonable requests, and to keep your profile accurate.

By signing below you confirm you have read and accept this agreement and that
the information you provide is true.
"""


def agreement_version():
    return Setting.get("partner_agreement_version") or AGREEMENT_VERSION_DEFAULT


def agreement_text():
    return Setting.get("partner_agreement_text") or DEFAULT_AGREEMENT


def has_accepted(user):
    if not getattr(user, "is_authenticated", False):
        return False
    return PartnerAgreementAcceptance.query.filter_by(
        user_id=user.id, version=agreement_version()).first() is not None


@partners_bp.app_context_processor
def _inject_partner_flags():
    try:
        accepted = has_accepted(current_user)
    except Exception:
        accepted = False
    return dict(partner_agreement_accepted=accepted,
                partner_agreement_version=agreement_version())


# ── Landing ──────────────────────────────────────────────────────────────
@partners_bp.route("/partners")
def landing():
    return render_template("partners/landing.html", accepted=has_accepted(current_user))


# ── Agreement: read + sign ─────────────────────────────────────────────────
@partners_bp.route("/partners/agreement")
def agreement():
    acc = None
    if current_user.is_authenticated:
        acc = PartnerAgreementAcceptance.query.filter_by(
            user_id=current_user.id, version=agreement_version()).order_by(
            PartnerAgreementAcceptance.accepted_at.desc()).first()
    return render_template("partners/agreement.html", text=agreement_text(),
                           version=agreement_version(), acceptance=acc)


@partners_bp.route("/partners/agreement/accept", methods=["POST"])
@login_required
def accept():
    name = (request.form.get("full_legal_name") or "").strip()
    agreed = request.form.get("agree") == "on"
    if not name or not agreed:
        flash("Please enter your full legal name and tick the box to accept.", "error")
        return redirect(url_for("partners.agreement"))
    if not has_accepted(current_user):
        db.session.add(PartnerAgreementAcceptance(
            user_id=current_user.id, full_legal_name=name[:160],
            version=agreement_version(), ip=request.remote_addr))
        AuditLog.log("partner.agreement_accept", actor=current_user,
                     meta={"version": agreement_version()}, ip=request.remote_addr)
        db.session.commit()
    flash("Agreement signed — you can now create a company.", "success")
    return redirect(url_for("partners.new"))


# ── Company registration ────────────────────────────────────────────────────
@partners_bp.route("/partners/new", methods=["GET", "POST"])
@login_required
def new():
    if not has_accepted(current_user):
        flash("Please read and sign the Partner Agreement first.", "error")
        return redirect(url_for("partners.agreement"))
    if request.method == "POST":
        name = (request.form.get("name") or "").strip()
        if not name:
            flash("Company name is required.", "error")
            return render_template("partners/register.html", form=request.form,
                                   types=PARTNER_TYPE_CHOICES, legal=PARTNER_LEGAL_CHOICES)
        c = PartnerCompany(
            slug=PartnerCompany.unique_slug(name),
            name=name[:160],
            ctype=(request.form.get("ctype") or "Developer"),
            legal_status=(request.form.get("legal_status") or "Unregistered"),
            owner_user_id=current_user.id,
            owner_legal_name=(request.form.get("owner_legal_name") or "").strip()[:160] or None,
            country=(request.form.get("country") or "").strip()[:80] or None,
            description=(request.form.get("description") or "").strip() or None,
            services=(request.form.get("services") or "").strip() or None,
            pricing=(request.form.get("pricing") or "").strip() or None,
            external_url=(request.form.get("external_url") or "").strip()[:300] or None,
            terms=(request.form.get("terms") or "").strip() or None,
            privacy=(request.form.get("privacy") or "").strip() or None,
            status="pending",
        )
        db.session.add(c)
        db.session.flush()
        AuditLog.log("partner.company_create", actor=current_user,
                     target_type="partner_company", target_id=c.id,
                     meta={"name": c.name}, ip=request.remote_addr)
        db.session.commit()
        flash("Company submitted for review.", "success")
        return redirect(url_for("partners.mine"))
    return render_template("partners/register.html", form={},
                           types=PARTNER_TYPE_CHOICES, legal=PARTNER_LEGAL_CHOICES)


# ── User dashboard: my companies + statuses ────────────────────────────────
@partners_bp.route("/partners/mine")
@login_required
def mine():
    companies = (PartnerCompany.query.filter_by(owner_user_id=current_user.id)
                 .order_by(PartnerCompany.created_at.desc()).all())
    return render_template("partners/mine.html", companies=companies)


# ── Public company page (only when approved) ────────────────────────────────
@partners_bp.route("/partners/<slug>")
def public(slug):
    if slug in RESERVED_SLUGS:
        abort(404)
    c = PartnerCompany.query.filter_by(slug=slug).first_or_404()
    is_owner = current_user.is_authenticated and current_user.id == c.owner_user_id
    is_staff = current_user.is_authenticated and (
        getattr(current_user, "is_staff", False) or getattr(current_user, "is_admin", False))
    if not c.is_public and not (is_owner or is_staff):
        abort(404)
    return render_template("partners/public.html", c=c, preview=not c.is_public)


# ════════════════════════════════════════════════ ADMIN ════════════════════
@partners_bp.route("/admin/partners")
@require_role(STAFF)
def admin_list():
    show = request.args.get("status", "all")
    q = PartnerCompany.query
    if show in PARTNER_STATUS_META:
        q = q.filter_by(status=show)
    items = q.order_by(PartnerCompany.updated_at.desc()).all()
    return render_template("admin/partners/list.html", companies=items, show=show,
                           statuses=PARTNER_STATUS_META,
                           agreement_text=agreement_text(),
                           agreement_version=agreement_version())


@partners_bp.route("/admin/partners/<int:cid>/status", methods=["POST"])
@require_role(STAFF)
def admin_status(cid):
    c = PartnerCompany.query.get_or_404(cid)
    new_status = request.form.get("status")
    if new_status in PARTNER_STATUS_META:
        c.status = new_status
    c.review_notes = (request.form.get("review_notes") or "").strip() or None
    c.rejection_reason = (request.form.get("rejection_reason") or "").strip() or None
    AuditLog.log("partner.status", actor=current_user, target_type="partner_company",
                 target_id=c.id, meta={"status": c.status}, ip=request.remote_addr)
    db.session.commit()
    flash(f"“{c.name}” set to {c.status_label}.", "success")
    return redirect(url_for("partners.admin_list", status=request.args.get("status", "all")))


@partners_bp.route("/admin/partners/<int:cid>/delete", methods=["POST"])
@require_role(STAFF)
def admin_delete(cid):
    c = PartnerCompany.query.get_or_404(cid)
    db.session.delete(c)
    AuditLog.log("partner.delete", actor=current_user, target_type="partner_company",
                 target_id=cid, ip=request.remote_addr)
    db.session.commit()
    flash("Company deleted.", "success")
    return redirect(url_for("partners.admin_list", status=request.args.get("status", "all")))


@partners_bp.route("/admin/partners/agreement", methods=["POST"])
@require_role(STAFF)
def admin_agreement():
    Setting.set("partner_agreement_text", request.form.get("agreement_text") or "",
                kind="text", category="partners")
    v = (request.form.get("agreement_version") or "").strip()
    if v:
        Setting.set("partner_agreement_version", v, kind="string", category="partners")
    AuditLog.log("partner.agreement_edit", actor=current_user, ip=request.remote_addr)
    flash("Agreement updated.", "success")
    return redirect(url_for("partners.admin_list", status=request.args.get("status", "all")))
__OPSLAB_EOF__
write "app/__init__.py" << '__OPSLAB_EOF__'
"""
Ops Labs - Multi-service Flask platform
Build. Support. Scale. Together.
"""
import os
from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_mail import Mail
from flask_migrate import Migrate

db = SQLAlchemy()
login_manager = LoginManager()
mail = Mail()
migrate = Migrate()



def create_app(config_name="default"):
    app = Flask(__name__, instance_relative_config=True)

    # ------- Core config -------
    app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "change-me-in-production-please")
    app.config["SQLALCHEMY_DATABASE_URI"] = os.environ.get(
        "DATABASE_URL", f"sqlite:///{os.path.join(app.instance_path, 'opslabs.db')}"
    )
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

    # ------- Billing / Stripe (optional until keys are set) -------
    app.config["STRIPE_SECRET_KEY"] = os.environ.get("STRIPE_SECRET_KEY", "")
    app.config["STRIPE_PUBLISHABLE_KEY"] = os.environ.get("STRIPE_PUBLISHABLE_KEY", "")
    app.config["STRIPE_WEBHOOK_SECRET"] = os.environ.get("STRIPE_WEBHOOK_SECRET", "")
    app.config["DISPLAY_TIMEZONE"] = os.environ.get("DISPLAY_TIMEZONE", "Europe/London")

    # ------- Mail (for password reset emails) -------
    app.config["MAIL_SERVER"] = os.environ.get("MAIL_SERVER", "smtp.gmail.com")
    app.config["MAIL_PORT"] = int(os.environ.get("MAIL_PORT", 587))
    app.config["MAIL_USE_TLS"] = os.environ.get("MAIL_USE_TLS", "true").lower() == "true"
    app.config["MAIL_USERNAME"] = os.environ.get("MAIL_USERNAME")
    app.config["MAIL_PASSWORD"] = os.environ.get("MAIL_PASSWORD")
    app.config["MAIL_DEFAULT_SENDER"] = os.environ.get(
        "MAIL_DEFAULT_SENDER", "noreply@opslabs.local"
    )

    # ------- Discord bot bridge -------
    app.config["DISCORD_BOT_URL"] = os.environ.get("DISCORD_BOT_URL", "http://127.0.0.1:5005")
    app.config["DISCORD_BOT_TOKEN"] = os.environ.get("DISCORD_BOT_TOKEN", "")
    app.config["DISCORD_BRIDGE_KEY"] = os.environ.get(
        "DISCORD_BRIDGE_KEY", "shared-secret-change-me"
    )
    app.config["DISCORD_GUILD_ID"] = os.environ.get("DISCORD_GUILD_ID", "")

    # Make sure instance dir exists
    try:
        os.makedirs(app.instance_path)
    except OSError:
        pass

    # ------- Init extensions -------
    db.init_app(app)
    login_manager.init_app(app)
    mail.init_app(app)
    migrate.init_app(app, db)

    login_manager.login_view = "auth.login"
    login_manager.login_message_category = "warning"

    from .models import User

    @login_manager.user_loader
    def load_user(uid):
        return User.query.get(int(uid))

    # ------- Blueprints -------
    from .routes.main import main_bp
    from .routes.auth import auth_bp
    from .routes.tickets import tickets_bp
    from .routes.admin import admin_bp
    from .routes.admin_content   import content_bp
    from .routes.admin_settings  import settings_bp
    from .routes.bridge import bridge_bp
    from .routes.api import api_bp
    from . import models_api  # noqa: F401  (registers ApiKey on metadata)
    from . import models_admin
    from . import models_business  # noqa: F401  (portal/CRM/billing tables)
    from . import admin_seeds
    from . import licenses
    from .portal import portal_bp
    from .billing import billing_bp
    from .quickjobs import quickjobs_bp
    from .reviews import reviews_bp
    from .callouts import callouts_bp
    from .site import site_bp
    from .sso import sso_bp, init_sso
    from .partners import partners_bp

    app.register_blueprint(main_bp)
    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(tickets_bp, url_prefix="/tickets")
    app.register_blueprint(admin_bp, url_prefix="/admin")
    app.register_blueprint(content_bp,  url_prefix="/admin/content")
    app.register_blueprint(settings_bp, url_prefix="/admin/settings")
    app.register_blueprint(bridge_bp, url_prefix="/bridge")
    app.register_blueprint(api_bp, url_prefix="/api/v1")
    app.register_blueprint(portal_bp, url_prefix="/portal")
    app.register_blueprint(billing_bp, url_prefix="/billing")
    app.register_blueprint(quickjobs_bp)  # /admin/jobs (gated) + /j/<token> (public)
    app.register_blueprint(reviews_bp)    # /reviews (public) + /admin/reviews (gated)
    app.register_blueprint(callouts_bp)   # /callout (public) + /admin/callouts (gated)
    app.register_blueprint(site_bp)       # /enter + /onsitesupport (+ gateway at /)
    app.register_blueprint(sso_bp, url_prefix="/auth/sso")
    app.register_blueprint(partners_bp)
    init_sso(app)                         # enable any providers with env credentials

    # License Manager (/licenses/) — mounted as sub-package
    licenses.register(app)

    # ── Deterministic template resolution (env-independent) ──────────────
    # The License Manager reassigns app.jinja_loader to a ChoiceLoader; on some
    # Flask builds that loader fails to resolve OpsLabs templates at all (e.g.
    # "TemplateNotFound: index.html") and on all builds it shadows the OpsLabs
    # admin pages. We sidestep it by setting the Jinja environment loader
    # ourselves, from absolute paths: licenses templates first (so /licenses
    # keeps its own pages), OpsLabs templates second (so the main site, portal,
    # quick jobs and admin always resolve). The admin name-collision is removed
    # separately by the installer (admin/ops_*.html), so order is safe here.
    import os as _os
    from jinja2 import ChoiceLoader as _CL, FileSystemLoader as _FSL
    _app_tpl = _os.path.join(app.root_path, app.template_folder or "templates")
    _lic_tpl = _os.path.join(app.root_path, "licenses", "templates")
    _loaders = []
    if _os.path.isdir(_lic_tpl):
        _loaders.append(_FSL(_lic_tpl))
    _loaders.append(_FSL(_app_tpl))
    app.jinja_env.loader = _CL(_loaders)

    # ── Restore OpsLabs as the ACTIVE login manager ──────────────────────
    # licenses' _setup_independent_login() calls lic_lm.init_app(app) last,
    # which makes its AdminUser-only loader the app-wide manager and breaks
    # current_user on every non-/licenses page (tickets, admin, portal).
    # Its own scope-aware wrapper on THIS manager is meant to be active, so
    # we re-assert it, and add a scoped unauthorized redirect so /licenses
    # still points at the licenses login.
    login_manager.init_app(app)
    login_manager.login_view = "auth.login"

    @login_manager.unauthorized_handler
    def _scoped_unauthorized():
        from flask import request, redirect, url_for
        if request.path.startswith("/licenses"):
            return redirect(url_for("lic_auth.login", next=request.path))
        return redirect(url_for("auth.login", next=request.path))

    # ------- Create tables + seed -------
    with app.app_context():
        db.create_all()
        _ensure_columns()
        _seed_defaults()

    @app.context_processor
    def _inject_sso():
        try:
            from .sso import ENABLED
            return dict(sso_providers=ENABLED)
        except Exception:
            return dict(sso_providers={})

    @app.before_request
    def _entry_gateway():
        """Show the Cloud-vs-Onsite chooser the first time an anonymous visitor
        lands on '/'. Once they choose (cookie set) or if they're logged in,
        the normal homepage is served as usual."""
        from flask import request, render_template
        from flask_login import current_user
        if (request.method == "GET" and request.path == "/"
                and not request.cookies.get("ols_entry")
                and not current_user.is_authenticated):
            return render_template("gateway.html")

    @app.context_processor
    def _inject_admin_helpers():
        from .models_admin import Setting, SiteContent
        return dict(setting=Setting.get, content=SiteContent.get_data)

    @app.context_processor
    def _inject_reviews():
        """Approved reviews for the homepage slider + a nav count. Defensive:
        never breaks page rendering if the table isn't there yet."""
        try:
            from .models_business import Testimonial
            items = (Testimonial.query.filter_by(approved=True)
                     .order_by(Testimonial.created_at.desc()).limit(12).all())
            return dict(site_reviews=items, site_reviews_count=len(items))
        except Exception:
            return dict(site_reviews=[], site_reviews_count=0)

    return app


def _ensure_columns():
    """Lightweight idempotent migration: add new quick_jobs payment columns
    to an existing table (db.create_all() won't alter existing tables).
    Works on SQLite and PostgreSQL; safe to run on every boot."""
    from sqlalchemy import inspect, text
    try:
        insp = inspect(db.engine)
        if "quick_jobs" not in insp.get_table_names():
            return
        cols = {c["name"] for c in insp.get_columns("quick_jobs")}
        adds = {
            "is_paid": "ALTER TABLE quick_jobs ADD COLUMN is_paid BOOLEAN",
            "paid_at": "ALTER TABLE quick_jobs ADD COLUMN paid_at TIMESTAMP",
            "paid_via": "ALTER TABLE quick_jobs ADD COLUMN paid_via VARCHAR(20)",
            "stripe_session_id": "ALTER TABLE quick_jobs ADD COLUMN stripe_session_id VARCHAR(160)",
            "stripe_payment_intent": "ALTER TABLE quick_jobs ADD COLUMN stripe_payment_intent VARCHAR(160)",
            "client_phone": "ALTER TABLE quick_jobs ADD COLUMN client_phone VARCHAR(40)",
            "allow_client_edits": "ALTER TABLE quick_jobs ADD COLUMN allow_client_edits BOOLEAN",
        }
        added = False
        for name, ddl in adds.items():
            if name not in cols:
                try:
                    db.session.execute(text(ddl))
                    db.session.commit()
                    added = True
                except Exception:
                    db.session.rollback()
        if added:
            for fixup in ("UPDATE quick_jobs SET is_paid = 0 WHERE is_paid IS NULL",
                          "UPDATE quick_jobs SET allow_client_edits = 1 WHERE allow_client_edits IS NULL"):
                try:
                    db.session.execute(text(fixup))
                    db.session.commit()
                except Exception:
                    db.session.rollback()
    except Exception:
        pass

    # testimonials.posted_to_discord
    try:
        insp = inspect(db.engine)
        if "testimonials" in insp.get_table_names():
            tcols = {c["name"] for c in insp.get_columns("testimonials")}
            if "posted_to_discord" not in tcols:
                try:
                    db.session.execute(text("ALTER TABLE testimonials ADD COLUMN posted_to_discord BOOLEAN"))
                    db.session.commit()
                    # existing reviews predate the webhook — mark them un-posted
                    db.session.execute(text("UPDATE testimonials SET posted_to_discord = 0 WHERE posted_to_discord IS NULL"))
                    db.session.commit()
                except Exception:
                    db.session.rollback()
    except Exception:
        pass


def _seed_defaults():
    """Seed default admin + default ticket categories + Ops Labs company."""
    from .models import User, Company, TicketCategory
    from werkzeug.security import generate_password_hash

    # Default admin
    if not User.query.filter_by(username="admin").first():
        admin = User(
            username="admin",
            email="admin@opslabs.local",
            password_hash=generate_password_hash("admin"),
            role="admin",
            is_active=True,
        )
        db.session.add(admin)

    # Default company
    if not Company.query.filter_by(slug="opslabs").first():
        company = Company(
            name="Ops Labs",
            slug="opslabs",
            tagline="Build. Support. Scale. Together.",
            description="One community. Multiple services. Endless possibilities.",
            is_active=True,
        )
        db.session.add(company)
        db.session.flush()

        # Default categories
        defaults = [
            ("Website Development", "Custom websites and updates"),
            ("FiveM Development", "Scripts, maps, resources, and more"),
            ("Tech Support", "Fix issues and get the help you need"),
            ("Hosting Support", "Reliable hosting solutions"),
            ("System Setup", "Setup and optimize your systems"),
            ("Other", "Anything tech related"),
        ]
        for name, desc in defaults:
            db.session.add(
                TicketCategory(name=name, description=desc, company_id=company.id)
            )

    admin_seeds.seed_admin_defaults(db)
    licenses.seed_defaults()
    db.session.commit()
__OPSLAB_EOF__
write "app/templates/base.html" << '__OPSLAB_EOF__'
<!doctype html>
<html lang="en" class="dark">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<meta name="theme-color" content="#05080f">
<title>{% block title %}OpsLab Systems · Build. Support. Scale. Together.{% endblock %}</title>

<meta name="description" content="OpsLab Systems — custom websites, FiveM scripts, hosting, system setup. One roof, one team, one ticket system. Live sync between web and Discord.">
<meta property="og:title" content="OpsLab Systems · Build. Support. Scale. Together.">
<meta property="og:description" content="From custom websites to FiveM scripts, hosting to system setup — under one roof, one team, one ticket system.">
<meta property="og:type" content="website">

<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">

<!-- Tailwind + Flowbite -->
<script src="https://cdn.tailwindcss.com"></script>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/flowbite/2.5.2/flowbite.min.css">
<script>
  tailwind.config = {
    darkMode: 'class',
    theme: {
      extend: {
        fontFamily: { sans: ['"Plus Jakarta Sans"', 'system-ui', 'sans-serif'], mono: ['"JetBrains Mono"', 'monospace'] },
        colors: {
          ink: { 950:'#04070e', 900:'#070b16', 800:'#0b1224', 700:'#111c33', 600:'#1b2a4a', 500:'#2a3d63' },
          ops: { 50:'#e8f3ff', 100:'#d0e7ff', 200:'#a1cfff', 300:'#71b7ff', 400:'#429fff', 500:'#2196f3', 600:'#1976d2', 700:'#0d47a1', 800:'#0a3782', 900:'#072564' },
        },
        boxShadow: {
          glow:      '0 0 0 1px rgba(33,150,243,.25), 0 12px 40px -8px rgba(33,150,243,.35)',
          'glow-sm': '0 0 0 1px rgba(33,150,243,.2),  0 6px 20px -4px rgba(33,150,243,.25)',
        },
        keyframes: {
          'fade-up':   { '0%':{opacity:'0', transform:'translateY(8px)'}, '100%':{opacity:'1', transform:'translateY(0)'} },
          'pulse-soft':{ '0%,100%':{opacity:'1'}, '50%':{opacity:'.5'} },
        },
        animation: {
          'fade-up':    'fade-up .5s ease-out both',
          'pulse-soft': 'pulse-soft 2s ease-in-out infinite',
        }
      }
    }
  }
</script>

<style>
  html, body { background: #04070e; color: #e6edf7; }
  body {
    background-image:
      radial-gradient(900px 600px at 85% -10%, rgba(33,150,243,.10), transparent 60%),
      radial-gradient(700px 500px at 10% 20%, rgba(13,71,161,.10), transparent 60%),
      linear-gradient(180deg, #04070e, #060a14);
    background-attachment: fixed;
  }
  /* Subtle grid overlay */
  .grid-overlay {
    background-image: linear-gradient(rgba(33,150,243,.05) 1px, transparent 1px),
                      linear-gradient(90deg, rgba(33,150,243,.05) 1px, transparent 1px);
    background-size: 56px 56px;
    mask-image: radial-gradient(ellipse 80% 60% at 50% 0%, #000 40%, transparent 100%);
  }
  /* Status pills */
  .pill { display:inline-flex; align-items:center; gap:6px; padding: 3px 10px; border-radius:999px; font-size: 11px; font-weight:700; letter-spacing:.6px; text-transform: uppercase; }
  .pill-open    { background: rgba(34,197,94,.12);  color: #86efac; border:1px solid rgba(34,197,94,.3);}
  .pill-pending { background: rgba(245,158,11,.12); color: #fcd34d; border:1px solid rgba(245,158,11,.3);}
  .pill-closed  { background: rgba(148,163,184,.12);color: #cbd5e1; border:1px solid rgba(148,163,184,.3);}
  .pill-low     { background: rgba(148,163,184,.12);color: #cbd5e1; border:1px solid rgba(148,163,184,.3);}
  .pill-normal  { background: rgba(33,150,243,.12); color: #93c5fd; border:1px solid rgba(33,150,243,.3);}
  .pill-high    { background: rgba(245,158,11,.12); color: #fcd34d; border:1px solid rgba(245,158,11,.3);}
  .pill-urgent  { background: rgba(239,68,68,.12);  color: #fca5a5; border:1px solid rgba(239,68,68,.3);}
  .pill-admin   { background: rgba(33,150,243,.15); color: #93c5fd; border:1px solid rgba(33,150,243,.35);}
  .pill-staff   { background: rgba(168,85,247,.15); color: #d8b4fe; border:1px solid rgba(168,85,247,.35);}
  .pill-user    { background: rgba(148,163,184,.12);color: #cbd5e1; border:1px solid rgba(148,163,184,.3);}

  /* Card hover gleam */
  .gleam { position: relative; overflow: hidden; }
  .gleam::after {
    content: ''; position: absolute; inset: -1px; border-radius: inherit;
    background: linear-gradient(120deg, transparent 40%, rgba(33,150,243,.15) 50%, transparent 60%);
    transform: translateX(-100%); transition: transform .6s ease; pointer-events: none;
  }
  .gleam:hover::after { transform: translateX(100%); }

  /* Live indicator */
  .live-dot { display:inline-block; width:8px; height:8px; border-radius:50%; background: #22c55e; box-shadow: 0 0 0 3px rgba(34,197,94,.25); animation: pulse-soft 2s infinite; }

  /* Conversation bubble styles */
  .msg { padding: 14px 16px; border-radius: 14px; margin-bottom: 12px; max-width: 80%; border: 1px solid #1b2a4a;}
  .msg.from-me      { margin-left: auto; background: linear-gradient(135deg, rgba(33,150,243,.18), rgba(33,150,243,.06)); border-color: rgba(33,150,243,.35);}
  .msg.from-them    { background: #0b1224; }
  .msg.from-discord { background: linear-gradient(135deg, rgba(88,101,242,.12), transparent); border-color: rgba(88,101,242,.4);}
  .msg.from-system  { background: transparent; border-style: dashed; color: #8aa0c0; font-size: 13px; max-width: 100%; text-align: center;}
  .msg.internal     { border-color: rgba(245,158,11,.45); background: rgba(245,158,11,.06);}

  /* Inputs */
  .form-input, .form-textarea, .form-select { background: #0b1224 !important; border: 1px solid #1b2a4a !important; color: #e6edf7 !important; border-radius: 10px !important;}
  .form-input:focus, .form-textarea:focus, .form-select:focus { border-color: #2196f3 !important; box-shadow: 0 0 0 3px rgba(33,150,243,.25) !important;}

  /* Scrollbar */
  *::-webkit-scrollbar { width: 10px; height: 10px; }
  *::-webkit-scrollbar-track { background: #04070e; }
  *::-webkit-scrollbar-thumb { background: #1b2a4a; border-radius: 5px; }
  *::-webkit-scrollbar-thumb:hover { background: #2a3d63; }

  /* Selection */
  ::selection { background: rgba(33,150,243,.4); color: white; }

  /* ===== Navbar (glassmorphism, readable over anything) ===== */
  .site-nav {
    background: linear-gradient(180deg, rgba(7,11,22,.55), rgba(7,11,22,.30));
    -webkit-backdrop-filter: blur(16px) saturate(160%);
    backdrop-filter: blur(16px) saturate(160%);
    border-bottom: 1px solid rgba(27,42,74,.40);
    transition: background .3s ease, border-color .3s ease, box-shadow .3s ease;
  }
  /* Firms up once the page is scrolled so text stays legible over content */
  .site-nav[data-scrolled="true"] {
    background: linear-gradient(180deg, rgba(5,8,15,.92), rgba(5,8,15,.80));
    border-bottom-color: rgba(33,150,243,.22);
    box-shadow: 0 10px 30px -14px rgba(0,0,0,.7);
  }
  @supports not ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px))) {
    .site-nav { background: rgba(6,10,20,.92); }  /* graceful fallback */
  }

  .navlink {
    display:flex; align-items:center; gap:.4rem; white-space:nowrap;
    padding:.5rem .7rem; border-radius:.65rem; font-size:.86rem; font-weight:500;
    color:#c4d2e8; transition:color .15s, background .15s, box-shadow .15s;
  }
  .navlink:hover { color:#fff; background:rgba(255,255,255,.06); }
  .navlink.active { color:#fff; background:rgba(33,150,243,.14); box-shadow:inset 0 0 0 1px rgba(33,150,243,.30); }
  .navlink-onsite { color:#9fd0ff; box-shadow:inset 0 0 0 1px rgba(33,150,243,.30); }
  .navlink-onsite:hover { color:#fff; background:rgba(33,150,243,.12); }

  /* Mobile / tablet drawer */
  .nav-drawer {
    overflow:hidden; max-height:0; opacity:0;
    transition:max-height .32s cubic-bezier(.4,0,.2,1), opacity .25s ease;
  }
  .nav-drawer.open { max-height:85vh; opacity:1; overflow-y:auto; }
  .nav-backdrop { opacity:0; pointer-events:none; transition:opacity .25s ease; }
  .nav-backdrop.open { opacity:1; pointer-events:auto; }
  .mlink {
    display:flex; align-items:center; gap:.7rem; min-height:48px;
    padding:.65rem .85rem; border-radius:.8rem; font-size:1rem; font-weight:500;
    color:#dbe6f5; transition:background .15s;
  }
  .mlink:hover, .mlink:active { background:rgba(255,255,255,.06); }
  .mlink.active { background:rgba(33,150,243,.14); box-shadow:inset 0 0 0 1px rgba(33,150,243,.30); color:#fff; }
  body.nav-locked { overflow:hidden; }
</style>
{% block head_extra %}{% endblock %}
</head>
<body class="font-sans antialiased min-h-screen flex flex-col">

<!-- ============ TOP NAV ============ -->
{% set ep = (request.endpoint or '') %}
{% set is_home  = ep == 'main.index' %}
{% set is_dash  = ep.startswith('portal.') %}
{% set is_tix   = ep.startswith('tickets.') %}
{% set is_admin = ep.startswith('admin.') %}
<nav id="siteNav" class="site-nav sticky top-0 z-50">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="flex items-center justify-between h-16 gap-2">

      <!-- Brand -->
      <a href="{{ url_for('main.index') }}" class="flex items-center gap-2.5 group shrink-0">
        <svg viewBox="0 0 64 64" width="30" height="30" class="transition-transform group-hover:rotate-6">
          <polygon points="32,4 56,18 56,46 32,60 8,46 8,18" fill="none" stroke="#2196f3" stroke-width="4"/>
          <polygon points="32,4 56,18 32,32" fill="#2196f3"/>
          <polygon points="32,32 56,18 56,46 32,60" fill="#ffffff" opacity=".95"/>
        </svg>
        <span class="font-extrabold text-base sm:text-lg tracking-tight leading-none">
          <span class="text-ops-500">OpsLab</span><span class="text-white"> Systems</span>
        </span>
      </a>

      <!-- Desktop links -->
      <div class="hidden lg:flex items-center gap-0.5 flex-1 justify-center">
        <a href="{{ url_for('main.index') }}" class="navlink {{ 'active' if is_home }}">Home</a>
        <a href="{{ url_for('main.index') }}#onsite" class="navlink navlink-onsite">
          <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17.657 16.657L13.414 20.9a2 2 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
          On-site
        </a>
        {% if not current_user.is_authenticated %}
          <a href="{{ url_for('main.index') }}#services" class="navlink">Services</a>
          <a href="{{ url_for('main.index') }}#how-it-works" class="navlink">How it works</a>
          <a href="{{ url_for('main.index') }}#features" class="navlink">Why us</a>
        {% endif %}
        <a href="/licenses/" class="navlink">
          <svg class="w-3.5 h-3.5 text-ops-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/></svg>
          Licenses
        </a>
        <a href="{{ url_for('reviews.index') }}" class="navlink {{ 'active' if request.path.startswith('/reviews') }}">Reviews</a>
        <a href="{{ url_for('partners.landing') }}" class="navlink {{ 'active' if request.path.startswith('/partners') }}">Partners</a>
        {% if current_user.is_authenticated %}
          <a href="{{ url_for('portal.dashboard') }}" class="navlink {{ 'active' if is_dash }}">Dashboard</a>
          <a href="{{ url_for('tickets.index') }}" class="navlink {{ 'active' if is_tix }}">My Tickets</a>
          {% if current_user.is_staff %}<a href="{{ url_for('admin.dashboard') }}" class="navlink {{ 'active' if is_admin }}">Admin</a>{% endif %}
        {% endif %}
      </div>

      <!-- Desktop actions -->
      <div class="flex items-center gap-2 shrink-0">
        <div class="hidden lg:flex items-center gap-2">
          {% if current_user.is_authenticated %}
            <div class="flex items-center gap-2 pl-1.5 pr-2.5 py-1.5 rounded-xl bg-white/5 border border-ink-600">
              <div class="w-7 h-7 rounded-full bg-gradient-to-br from-ops-400 to-ops-700 flex items-center justify-center text-xs font-bold shrink-0">{{ (current_user.username or current_user.name or current_user.email or "?")[0].upper() }}</div>
              <div class="leading-tight hidden xl:block">
                <div class="text-xs font-semibold max-w-[120px] truncate">{{ current_user.username or current_user.name or current_user.email }}</div>
                <div class="text-[10px] text-ops-400 uppercase tracking-wider">{{ current_user.role or 'user' }}</div>
              </div>
            </div>
            <a href="{{ url_for('tickets.new') }}" class="inline-flex items-center gap-1.5 px-3.5 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg shadow-glow-sm hover:shadow-glow transition">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>
              <span class="hidden xl:inline">New Ticket</span><span class="xl:hidden">New</span>
            </a>
            <a href="{{ url_for('auth.logout') }}" title="Sign out" class="inline-flex items-center justify-center w-9 h-9 rounded-lg text-gray-400 hover:text-white hover:bg-white/5 border border-ink-600 transition">
              <span class="sr-only">Sign out</span>
              <svg class="w-4.5 h-4.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/></svg>
            </a>
          {% else %}
            <a href="{{ url_for('auth.login') }}" class="px-3 py-2 text-sm font-medium text-gray-300 hover:text-white rounded-lg hover:bg-white/5 transition">Sign in</a>
            <a href="{{ url_for('auth.register') }}" class="inline-flex items-center gap-2 px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg shadow-glow-sm hover:shadow-glow transition">Get Started</a>
          {% endif %}
        </div>

        <!-- Hamburger -->
        <button id="navToggle" type="button" aria-controls="mobileNav" aria-expanded="false"
          class="lg:hidden inline-flex items-center justify-center w-10 h-10 rounded-lg text-gray-200 hover:text-white hover:bg-white/5 border border-ink-600 transition">
          <span class="sr-only">Open main menu</span>
          <svg id="navIconOpen" class="w-6 h-6" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h16"/></svg>
          <svg id="navIconClose" class="w-6 h-6 hidden" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12"/></svg>
        </button>
      </div>
    </div>

    <!-- ===== Mobile / tablet drawer ===== -->
    <div id="mobileNav" class="nav-drawer lg:hidden">
      <div class="flex flex-col gap-1 py-3 border-t border-ink-600/60">
        {% if current_user.is_authenticated %}
          <div class="flex items-center gap-3 px-3 py-3 mb-1 rounded-2xl bg-white/5 border border-ink-600">
            <div class="w-10 h-10 rounded-full bg-gradient-to-br from-ops-400 to-ops-700 flex items-center justify-center text-sm font-bold shrink-0">{{ (current_user.username or current_user.name or current_user.email or "?")[0].upper() }}</div>
            <div class="leading-tight min-w-0">
              <div class="text-sm font-semibold truncate">{{ current_user.username or current_user.name or current_user.email }}</div>
              <div class="text-[10px] text-ops-400 uppercase tracking-wider">{{ current_user.role or 'user' }}</div>
            </div>
          </div>
        {% endif %}

        <a href="{{ url_for('main.index') }}" class="mlink {{ 'active' if is_home }}">Home</a>
        <a href="{{ url_for('main.index') }}#onsite" class="mlink text-ops-200">
          <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17.657 16.657L13.414 20.9a2 2 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
          On-site &amp; networking
        </a>
        <a href="{{ url_for('main.index') }}#services" class="mlink">Services</a>
        <a href="{{ url_for('main.index') }}#how-it-works" class="mlink">How it works</a>
        <a href="{{ url_for('main.index') }}#features" class="mlink">Why us</a>
        <a href="/licenses/" class="mlink">
          <svg class="w-5 h-5 text-ops-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/></svg>
          Licenses
        </a>
        <a href="{{ url_for('reviews.index') }}" class="mlink {{ 'active' if request.path.startswith('/reviews') }}">Reviews</a>
        <a href="{{ url_for('partners.landing') }}" class="mlink {{ 'active' if request.path.startswith('/partners') }}">Partners</a>

        {% if current_user.is_authenticated %}
          <a href="{{ url_for('portal.dashboard') }}" class="mlink {{ 'active' if is_dash }}">Dashboard</a>
          <a href="{{ url_for('tickets.index') }}" class="mlink {{ 'active' if is_tix }}">My Tickets</a>
          {% if current_user.is_staff %}<a href="{{ url_for('admin.dashboard') }}" class="mlink {{ 'active' if is_admin }}">Admin</a>{% endif %}
          <div class="mt-2 pt-3 border-t border-ink-600/60 flex flex-col gap-2">
            <a href="{{ url_for('tickets.new') }}" class="inline-flex items-center justify-center gap-2 px-4 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm transition">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>
              New Ticket
            </a>
            <a href="{{ url_for('auth.logout') }}" class="inline-flex items-center justify-center gap-2 px-4 py-3 text-sm font-semibold text-gray-300 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"/></svg>
              Sign out
            </a>
          </div>
        {% else %}
          <div class="mt-2 pt-3 border-t border-ink-600/60 flex flex-col gap-2">
            <a href="{{ url_for('auth.register') }}" class="inline-flex items-center justify-center gap-2 px-4 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm transition">Get Started</a>
            <a href="{{ url_for('auth.login') }}" class="inline-flex items-center justify-center px-4 py-3 text-sm font-semibold text-gray-300 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">Sign in</a>
          </div>
        {% endif %}
      </div>
    </div>
  </div>
</nav>
<!-- Backdrop behind the mobile drawer -->
<div id="navBackdrop" class="nav-backdrop lg:hidden fixed inset-x-0 bottom-0 top-16 z-40 bg-black/50" style="-webkit-backdrop-filter:blur(2px);backdrop-filter:blur(2px);"></div>

<script>
  (function () {
    var nav   = document.getElementById('siteNav');
    var btn   = document.getElementById('navToggle');
    var panel = document.getElementById('mobileNav');
    var back  = document.getElementById('navBackdrop');
    var iOpen = document.getElementById('navIconOpen');
    var iClose= document.getElementById('navIconClose');

    // Glass → solid on scroll (keeps text readable over page content)
    if (nav) {
      var onScroll = function () {
        nav.setAttribute('data-scrolled', window.scrollY > 8 ? 'true' : 'false');
      };
      onScroll();
      window.addEventListener('scroll', onScroll, { passive: true });
    }

    if (!btn || !panel) return;

    function setOpen(open) {
      panel.classList.toggle('open', open);
      if (back) back.classList.toggle('open', open);
      if (iOpen)  iOpen.classList.toggle('hidden', open);
      if (iClose) iClose.classList.toggle('hidden', !open);
      btn.setAttribute('aria-expanded', open ? 'true' : 'false');
      document.body.classList.toggle('nav-locked', open);
    }
    btn.addEventListener('click', function () {
      setOpen(!panel.classList.contains('open'));
    });
    if (back) back.addEventListener('click', function () { setOpen(false); });
    panel.querySelectorAll('a').forEach(function (a) {
      a.addEventListener('click', function () { setOpen(false); });
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') setOpen(false);
    });
    window.addEventListener('resize', function () {
      if (window.innerWidth >= 1024) setOpen(false);
    });
  })();
</script>

<!-- ============ FLASHES ============ -->
{% with messages = get_flashed_messages(with_categories=true) %}
  {% if messages %}
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 w-full pt-4 space-y-2">
      {% for cat, msg in messages %}
        <div class="flex items-start gap-3 p-4 rounded-xl border
          {% if cat == 'success' %}bg-green-500/10 border-green-500/30 text-green-200
          {% elif cat == 'error' %}bg-red-500/10 border-red-500/30 text-red-200
          {% elif cat == 'warning' %}bg-yellow-500/10 border-yellow-500/30 text-yellow-200
          {% else %}bg-ops-500/10 border-ops-500/30 text-ops-200{% endif %}">
          <span class="text-sm">{{ msg }}</span>
        </div>
      {% endfor %}
    </div>
  {% endif %}
{% endwith %}

<!-- ============ PAGE ============ -->
<main class="flex-1 w-full">
  {% block content %}{% endblock %}
</main>

<!-- ============ FOOTER ============ -->
<footer class="mt-24 border-t border-ink-600/60 bg-ink-950/50">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-14">
    <div class="grid md:grid-cols-4 gap-8">
      <div class="md:col-span-2">
        <div class="flex items-center gap-2.5 mb-4">
          <svg viewBox="0 0 64 64" width="28" height="28">
            <polygon points="32,4 56,18 56,46 32,60 8,46 8,18" fill="none" stroke="#2196f3" stroke-width="4"/>
            <polygon points="32,4 56,18 32,32" fill="#2196f3"/>
            <polygon points="32,32 56,18 56,46 32,60" fill="#ffffff" opacity=".95"/>
          </svg>
          <span class="font-extrabold text-lg"><span class="text-ops-500">OpsLab</span><span class="text-white"> Systems</span></span>
        </div>
        <p class="text-sm text-gray-400 max-w-md leading-relaxed">
          Build. Support. Scale. Together.<br>
          From custom websites to FiveM scripts, hosting to system setup — under one roof, one team, one ticket system.
        </p>
      </div>
      <div>
        <h4 class="text-xs font-bold uppercase tracking-widest text-gray-500 mb-3">Platform</h4>
        <ul class="space-y-2 text-sm text-gray-400">
          <li><a href="{{ url_for('main.index') }}#onsite" class="hover:text-white transition">On-site IT &amp; networking</a></li>
          <li><a href="{{ url_for('main.index') }}#services" class="hover:text-white transition">Services</a></li>
          <li><a href="{{ url_for('main.index') }}#how-it-works" class="hover:text-white transition">How it works</a></li>
          <li><a href="{{ url_for('main.index') }}#features" class="hover:text-white transition">Why us</a></li>
          <li><a href="/api/v1/health" class="hover:text-white transition">API status</a></li>
        </ul>
      </div>
      <div>
        <h4 class="text-xs font-bold uppercase tracking-widest text-gray-500 mb-3">Account</h4>
        <ul class="space-y-2 text-sm text-gray-400">
          {% if current_user.is_authenticated %}
          <li><a href="{{ url_for('tickets.index') }}" class="hover:text-white transition">My Tickets</a></li>
          <li><a href="/licenses/" class="hover:text-white transition">License Manager</a></li>
          <li><a href="{{ url_for('tickets.new') }}" class="hover:text-white transition">Open a ticket</a></li>
          <li><a href="{{ url_for('auth.logout') }}" class="hover:text-white transition">Sign out</a></li>
          {% else %}
          <li><a href="{{ url_for('auth.login') }}" class="hover:text-white transition">Sign in</a></li>
          <li><a href="{{ url_for('auth.register') }}" class="hover:text-white transition">Sign up</a></li>
          {% endif %}
        </ul>
      </div>
    </div>
    <div class="mt-10 pt-6 border-t border-ink-600/40 flex flex-col sm:flex-row items-center justify-between gap-3 text-xs text-gray-500">
      <span>© <span id="year"></span> OpsLab Systems. All rights reserved.</span>
      <span class="flex items-center gap-2"><span class="live-dot"></span> All systems operational</span>
    </div>
  </div>
</footer>

<script src="https://cdnjs.cloudflare.com/ajax/libs/flowbite/2.5.2/flowbite.min.js"></script>
<script>document.getElementById('year').textContent = new Date().getFullYear();</script>
{% block scripts %}{% endblock %}
{% if not partner_agreement_accepted and not request.path.startswith('/partners') and not request.path.startswith('/auth') %}
<div id="partnerPopup" style="display:none" class="fixed inset-0 z-[100] items-center justify-center p-4 bg-black/70 backdrop-blur-sm">
  <div class="max-w-lg w-full rounded-2xl border border-ink-600 bg-ink-900 p-6 shadow-2xl">
    <div class="flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-ops-300 mb-2">Partner Program</div>
    <h2 class="text-2xl font-extrabold tracking-tight">Become a Partner with OpsLab Systems</h2>
    <p class="text-gray-400 mt-3 text-sm">List your company or developer community on the platform and get your own page. Partners agree to a short, fair agreement covering independent-contractor status, refunds, conduct and more.</p>
    <div class="mt-5 flex flex-wrap gap-2">
      <a href="{{ url_for('partners.agreement') }}" class="px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl">Read full agreement</a>
      <a href="{{ url_for('partners.landing') }}" class="px-5 py-2.5 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-xl">Become a partner</a>
      <button type="button" onclick="dismissPartnerPopup()" class="px-4 py-2.5 text-sm font-semibold text-gray-400 hover:text-gray-200">Not now</button>
    </div>
  </div>
</div>
<script>
  function dismissPartnerPopup(){
    document.cookie = "ols_partner_seen=1; path=/; max-age=" + (60*60*24*30);
    var p = document.getElementById('partnerPopup'); if (p) p.style.display='none';
    document.body.style.overflow='';
  }
  (function(){
    if (document.cookie.indexOf('ols_partner_seen=1') === -1){
      var p = document.getElementById('partnerPopup');
      if (p){ setTimeout(function(){ p.style.display='flex'; document.body.style.overflow='hidden'; }, 1200); }
    }
  })();
</script>
{% endif %}
</body>
</html>
__OPSLAB_EOF__
write "app/templates/admin/_layout.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}Admin · {% block admin_title %}{% endblock %} · OpsLab Systems{% endblock %}

{% block head_extra %}
<style>
  /* Admin shell */
  .admin-shell {
    display: grid;
    grid-template-columns: 250px 1fr;
    min-height: calc(100vh - 4rem);
    gap: 0;
  }
  @media (max-width: 1023px) {
    .admin-shell { grid-template-columns: 1fr; }
    .admin-sidebar { display: none; }
  }

  /* Sidebar */
  .admin-sidebar {
    background: linear-gradient(180deg, rgba(7,11,22,.7), rgba(4,7,14,.9));
    border-right: 1px solid rgba(27,42,74,.5);
    padding: 24px 16px;
    position: sticky;
    top: 4rem;
    height: calc(100vh - 4rem);
    overflow-y: auto;
  }
  .nav-section {
    font-size: 10px; font-weight: 700;
    text-transform: uppercase; letter-spacing: .15em;
    color: #6b7280;
    margin: 18px 12px 6px;
  }
  .nav-section:first-child { margin-top: 0; }

  .nav-item {
    display: flex; align-items: center; gap: 10px;
    padding: 9px 12px;
    border-radius: 10px;
    font-size: 13px; font-weight: 500;
    color: #cbd5e1;
    text-decoration: none;
    transition: background-color .15s, color .15s;
  }
  .nav-item:hover {
    background: rgba(33,150,243,.07);
    color: white;
  }
  .nav-item.active {
    background: linear-gradient(90deg, rgba(33,150,243,.2), rgba(33,150,243,.05));
    color: white;
    border-left: 2px solid #2196f3;
    padding-left: 10px;
  }
  .nav-item .ic {
    width: 16px; height: 16px;
    color: #6b7280;
    flex-shrink: 0;
  }
  .nav-item.active .ic, .nav-item:hover .ic { color: #71b7ff; }
  .nav-item .badge {
    margin-left: auto;
    font-size: 10px;
    background: rgba(33,150,243,.15);
    color: #93c5fd;
    padding: 1px 6px;
    border-radius: 999px;
    font-weight: 600;
  }

  /* Main area */
  .admin-main {
    padding: 32px 32px 80px;
    min-width: 0;  /* allows children to truncate */
  }
  @media (max-width: 640px) {
    .admin-main { padding: 24px 16px 60px; }
  }

  /* Page header */
  .page-head {
    display: flex; flex-wrap: wrap; align-items: end; justify-content: space-between;
    gap: 16px;
    padding-bottom: 18px;
    border-bottom: 1px solid rgba(27,42,74,.5);
    margin-bottom: 24px;
  }
  .page-head h1 {
    font-size: 28px; font-weight: 800; letter-spacing: -.02em;
    line-height: 1.1;
  }
  .page-head .eyebrow {
    font-size: 10px; font-weight: 700;
    text-transform: uppercase; letter-spacing: .25em;
    color: #71b7ff;
    margin-bottom: 6px;
  }

  /* Cards */
  .a-card {
    background: linear-gradient(180deg, rgba(11,18,36,.5), rgba(7,11,22,.4));
    border: 1px solid rgba(27,42,74,.6);
    border-radius: 14px;
  }
  .a-card-hd {
    padding: 14px 18px;
    border-bottom: 1px solid rgba(27,42,74,.5);
    display: flex; align-items: center; justify-content: space-between;
    font-size: 11px; font-weight: 700;
    text-transform: uppercase; letter-spacing: .15em;
    color: #93a3b8;
  }
  .a-card-bd { padding: 18px; }

  /* Stat tile */
  .stat-tile {
    background: linear-gradient(180deg, rgba(11,18,36,.6), rgba(7,11,22,.5));
    border: 1px solid rgba(27,42,74,.6);
    border-radius: 14px;
    padding: 16px;
    transition: border-color .2s, transform .2s;
  }
  .stat-tile:hover { border-color: rgba(33,150,243,.4); transform: translateY(-1px); }
  .stat-tile .label {
    font-size: 10px; font-weight: 700;
    text-transform: uppercase; letter-spacing: .15em;
    color: #6b7280;
  }
  .stat-tile .value {
    font-size: 28px; font-weight: 800; line-height: 1;
    margin-top: 6px;
  }
  .stat-tile .sub {
    font-size: 11px; color: #6b7280; margin-top: 6px;
  }

  /* Form helpers */
  .field-row {
    display: grid;
    grid-template-columns: 200px 1fr;
    gap: 24px;
    padding: 18px 0;
    border-bottom: 1px solid rgba(27,42,74,.3);
  }
  .field-row:last-child { border-bottom: 0; padding-bottom: 0; }
  @media (max-width: 640px) {
    .field-row { grid-template-columns: 1fr; gap: 6px; }
  }
  .field-label {
    font-size: 13px; font-weight: 600; color: #e6edf7;
  }
  .field-help {
    font-size: 11px; color: #6b7280; margin-top: 3px;
  }
  .field-input input,
  .field-input textarea,
  .field-input select {
    width: 100%;
  }

  /* Button styles */
  .btn {
    display: inline-flex; align-items: center; justify-content: center;
    gap: 8px;
    padding: 8px 14px;
    border-radius: 8px;
    font-size: 13px; font-weight: 600;
    transition: all .15s;
    cursor: pointer;
    border: 1px solid transparent;
  }
  .btn-primary {
    background: linear-gradient(135deg, #2196f3, #0d47a1);
    color: white;
    box-shadow: 0 4px 12px -2px rgba(33,150,243,.4);
  }
  .btn-primary:hover { box-shadow: 0 6px 18px -2px rgba(33,150,243,.55); transform: translateY(-1px); }
  .btn-ghost {
    background: rgba(255,255,255,.03);
    border-color: rgba(27,42,74,.7);
    color: #cbd5e1;
  }
  .btn-ghost:hover { background: rgba(255,255,255,.07); color: white; }
  .btn-danger {
    background: rgba(239,68,68,.1);
    border-color: rgba(239,68,68,.3);
    color: #fca5a5;
  }
  .btn-danger:hover { background: rgba(239,68,68,.18); color: #fecaca; }
  .btn-sm { padding: 5px 10px; font-size: 11px; border-radius: 6px; }

  /* Sticky save bar */
  .save-bar {
    position: sticky; bottom: 0;
    background: linear-gradient(180deg, rgba(4,7,14,.4), rgba(4,7,14,.95) 40%);
    backdrop-filter: blur(10px);
    padding: 14px 0 4px;
    margin-top: 32px;
    display: flex; align-items: center; justify-content: space-between;
    gap: 12px;
    border-top: 1px solid rgba(27,42,74,.5);
    z-index: 10;
  }

  /* Toast */
  .toast {
    position: fixed;
    bottom: 24px; right: 24px;
    background: linear-gradient(135deg, #16a34a, #15803d);
    color: white;
    padding: 12px 18px;
    border-radius: 10px;
    font-size: 13px; font-weight: 600;
    box-shadow: 0 14px 40px -10px rgba(22,163,74,.5);
    opacity: 0; transform: translateY(8px);
    pointer-events: none;
    transition: all .3s;
    z-index: 100;
  }
  .toast.show { opacity: 1; transform: none; }
  .toast.error {
    background: linear-gradient(135deg, #dc2626, #991b1b);
    box-shadow: 0 14px 40px -10px rgba(220,38,38,.5);
  }

  /* Tab nav */
  .tabs {
    display: flex; gap: 4px;
    border-bottom: 1px solid rgba(27,42,74,.5);
    margin-bottom: 24px;
    overflow-x: auto;
  }
  .tab {
    padding: 10px 16px;
    font-size: 13px; font-weight: 600;
    color: #94a3b8;
    border-bottom: 2px solid transparent;
    transition: all .15s;
    white-space: nowrap;
    cursor: pointer;
  }
  .tab:hover { color: white; }
  .tab.active {
    color: #71b7ff;
    border-bottom-color: #2196f3;
  }
  .tab-panel { display: none; }
  .tab-panel.active { display: block; }
</style>
{% endblock %}

{% block content %}
<div class="admin-shell">

  <!-- ═══ SIDEBAR ═══════════════════════════════════════════════════ -->
  <aside class="admin-sidebar">

    <div class="flex items-center gap-2 mb-6 px-3">
      <div class="w-7 h-7 rounded-lg bg-gradient-to-br from-ops-400 to-ops-700 flex items-center justify-center text-xs font-extrabold">
        🛡
      </div>
      <div>
        <div class="text-xs font-bold tracking-wide">Admin Console</div>
        <div class="text-[10px] text-gray-500">OpsLab Systems</div>
      </div>
    </div>

    <div class="nav-section">Overview</div>
    <a href="{{ url_for('admin.dashboard') }}"
       class="nav-item {% if request.endpoint == 'admin.dashboard' %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V7M3 7l9-4 9 4M3 7l9 4 9-4M12 11v8"/></svg>
      Dashboard
    </a>

    <div class="nav-section">Tickets</div>
    <a href="{{ url_for('tickets.index') }}"
       class="nav-item {% if request.endpoint and request.endpoint.startswith('tickets.') %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5"/></svg>
      All Tickets
    </a>

    <div class="nav-section">Manage</div>
    <a href="{{ url_for('quickjobs.admin_list') }}"
       class="nav-item {% if request.endpoint and request.endpoint.startswith('quickjobs.admin') %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/></svg>
      Quick Jobs
    </a>
    <a href="{{ url_for('reviews.admin_list') }}"
       class="nav-item {% if request.endpoint and request.endpoint.startswith('reviews.admin') %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M11.049 2.927c.3-.921 1.603-.921 1.902 0l1.519 4.674a1 1 0 00.95.69h4.915c.969 0 1.371 1.24.588 1.81l-3.976 2.888a1 1 0 00-.363 1.118l1.518 4.674c.3.922-.755 1.688-1.538 1.118l-3.976-2.888a1 1 0 00-1.176 0l-3.976 2.888c-.783.57-1.838-.196-1.538-1.118l1.518-4.674a1 1 0 00-.363-1.118l-3.976-2.888c-.784-.57-.38-1.81.588-1.81h4.914a1 1 0 00.951-.69l1.519-4.674z"/></svg>
      Reviews
    </a>
    <a href="{{ url_for('callouts.admin_list') }}"
       class="nav-item {% if request.endpoint and request.endpoint.startswith('callouts.admin') %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M3 5a2 2 0 012-2h3.28a1 1 0 01.948.684l1.498 4.493a1 1 0 01-.502 1.21l-2.257 1.13a11.042 11.042 0 005.516 5.516l1.13-2.257a1 1 0 011.21-.502l4.493 1.498a1 1 0 01.684.949V19a2 2 0 01-2 2h-1C9.716 21 3 14.284 3 6V5z"/></svg>
      Call-outs
    </a>
    <a href="{{ url_for('partners.admin_list') }}"
       class="nav-item {% if request.endpoint and request.endpoint.startswith('partners.admin') %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17 20h5v-2a4 4 0 00-3-3.87M9 20H4v-2a4 4 0 013-3.87m6-1.13a4 4 0 10-4-4 4 4 0 004 4zm6 0a3 3 0 10-3-3"/></svg>
      Partners
    </a>
    <a href="{{ url_for('admin.users') }}"
       class="nav-item {% if request.endpoint == 'admin.users' %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
      Users
    </a>
    <a href="{{ url_for('admin.companies') }}"
       class="nav-item {% if request.endpoint and request.endpoint.startswith('admin.compan') %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"/></svg>
      Companies
    </a>
    <a href="{{ url_for('admin.api_keys') }}"
       class="nav-item {% if request.endpoint == 'admin.api_keys' %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/></svg>
      API Keys
    </a>

    <div class="nav-section">Site</div>
    <a href="/admin/content/"
       class="nav-item {% if request.endpoint and request.endpoint.startswith('content.') %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>
      Homepage Editor
    </a>
    <a href="/admin/settings/"
       class="nav-item {% if request.endpoint and request.endpoint.startswith('settings.') %}active{% endif %}">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
      Settings
    </a>

    <div class="nav-section">Quick links</div>
    <a href="{{ url_for('main.index') }}" class="nav-item" target="_blank">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>
      View public site
    </a>
    <a href="/api/v1/health" class="nav-item" target="_blank">
      <svg class="ic" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>
      API health
    </a>
  </aside>

  <!-- ═══ MAIN ══════════════════════════════════════════════════════ -->
  <main class="admin-main">
    {% block admin_content %}{% endblock %}
  </main>
</div>

<!-- Toast -->
<div id="toast" class="toast"></div>

<script>
  // Global toast helper for admin pages
  window.toast = function(msg, kind) {
    const t = document.getElementById('toast');
    t.textContent = msg;
    t.className = 'toast show' + (kind === 'error' ? ' error' : '');
    clearTimeout(window._toastTimer);
    window._toastTimer = setTimeout(() => t.classList.remove('show'), 2400);
  };

  // Helper used in some templates to call POST endpoints with CSRF/headers
  window.adminFetch = async function(url, opts = {}) {
    const r = await fetch(url, {
      method: opts.method || 'POST',
      headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) },
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
    if (!r.ok) {
      let detail = '';
      try { detail = (await r.json()).error || ''; } catch {}
      throw new Error(detail || `HTTP ${r.status}`);
    }
    try { return await r.json(); } catch { return {}; }
  };
</script>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/index.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}OpsLab Systems · Web, FiveM, hosting & on-site IT{% endblock %}

{# ────────────────────────────────────────────────────────────────────────
   HOW TO EDIT YOUR CONTACT / ON-SITE DETAILS
   Search this file for  "EDIT:"  — every placeholder is marked.
   The on-site phone, WhatsApp, email and service area all live in the
   "ON-SITE IT & NETWORKING" section below.
   ──────────────────────────────────────────────────────────────────────── #}

{% block head_extra %}
<style>
  /* Lean, grounded primitives — no drifting blobs, no fake-terminal theatre. */
  .card {
    background: #0b1224;
    border: 1px solid #1b2a4a;
    border-radius: 16px;
    transition: border-color .2s ease, transform .2s ease;
  }
  .card:hover { border-color: rgba(33,150,243,.45); transform: translateY(-2px); }

  .svc-icon {
    background: rgba(33,150,243,.10);
    border: 1px solid rgba(33,150,243,.30);
    color: #71b7ff;
  }

  .accent { color: #429fff; }

  .tag {
    font-size: 11px; padding: 2px 9px; border-radius: 999px;
    background: rgba(255,255,255,.04); border: 1px solid #1b2a4a; color: #9fb0c9;
  }

  .check {
    width: 20px; height: 20px; border-radius: 6px; flex-shrink: 0;
    background: rgba(33,150,243,.12); border: 1px solid rgba(33,150,243,.35);
    display: inline-flex; align-items: center; justify-content: center; color: #71b7ff;
  }
</style>
{% endblock %}

{% block content %}

<!-- ══════════════════════════════════════════════════════════ HERO ══ -->
<section class="relative">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 pt-16 lg:pt-20 pb-14">
    <div class="grid lg:grid-cols-12 gap-10 items-start">

      <div class="lg:col-span-7">
        <span class="inline-flex items-center gap-2 px-3 py-1.5 mb-6 rounded-full text-[12px] font-semibold tag">
          <span class="live-dot"></span>
          Web · FiveM · Hosting · On-site IT &amp; Networking
        </span>

        <h1 class="text-4xl sm:text-5xl lg:text-6xl font-extrabold tracking-tight leading-[1.05]">
          One person who builds it,<br>
          fixes it, and <span class="accent">turns up in person</span>.
        </h1>

        <p class="mt-6 text-lg text-gray-300 max-w-2xl leading-relaxed">
          OpsLab Systems is a small, hands-on tech outfit: websites and web apps,
          FiveM development, hosting and server setup — and on-site IT and network
          work when you need someone physically there.
        </p>

        <p class="mt-3 text-base text-gray-400 max-w-2xl leading-relaxed">
          Everything runs through one simple ticket system that stays in sync
          between the website and Discord, so nothing gets lost. You talk to the
          person actually doing the work.
        </p>

        <div class="mt-8 flex flex-wrap gap-3">
          {% if current_user.is_authenticated %}
            <a href="{{ url_for('tickets.new') }}"
               class="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">
              Open a ticket
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
            </a>
          {% else %}
            <a href="{{ url_for('auth.register') }}"
               class="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">
              Get started
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
            </a>
          {% endif %}
          <a href="#onsite"
             class="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-white/[.05] border border-ink-600 rounded-xl hover:bg-white/[.09] transition">
            <svg class="w-4 h-4 accent" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17.657 16.657L13.414 20.9a2 2 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
            Need me on-site?
          </a>
        </div>

        <!-- Honest, concrete trust row — no invented statistics -->
        <div class="mt-10 grid sm:grid-cols-3 gap-4 max-w-2xl">
          <div class="flex items-start gap-2.5">
            <span class="check mt-0.5"><svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg></span>
            <span class="text-sm text-gray-300">Talk to the person doing the work — no call-centre.</span>
          </div>
          <div class="flex items-start gap-2.5">
            <span class="check mt-0.5"><svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg></span>
            <span class="text-sm text-gray-300">Tickets sync between web &amp; Discord automatically.</span>
          </div>
          <div class="flex items-start gap-2.5">
            <span class="check mt-0.5"><svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg></span>
            <span class="text-sm text-gray-300">Remote or on-site — your choice.</span>
          </div>
        </div>
      </div>

      <!-- Quick-jump card: makes the page easy to navigate -->
      <div class="lg:col-span-5">
        <div class="card p-6">
          <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500 mb-4">Jump to</div>
          <div class="grid grid-cols-2 gap-2.5">
            <a href="#onsite" class="flex items-center gap-2.5 px-3 py-3 rounded-xl bg-ops-500/[.08] border border-ops-500/30 hover:border-ops-500/60 transition">
              <svg class="w-5 h-5 accent" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17.657 16.657L13.414 20.9a2 2 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
              <span class="text-sm font-semibold text-white">On-site &amp; networking</span>
            </a>
            <a href="#services" class="flex items-center gap-2.5 px-3 py-3 rounded-xl bg-white/[.03] border border-ink-600 hover:border-ops-500/50 transition">
              <svg class="w-5 h-5 text-gray-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h16"/></svg>
              <span class="text-sm font-semibold text-white">Services</span>
            </a>
            <a href="#companies" class="flex items-center gap-2.5 px-3 py-3 rounded-xl bg-white/[.03] border border-ink-600 hover:border-ops-500/50 transition">
              <svg class="w-5 h-5 text-gray-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0H5m14 0h2M5 21H3m4-12h2m-2 4h2m6-4h2m-2 4h2"/></svg>
              <span class="text-sm font-semibold text-white">Brands</span>
            </a>
            <a href="#licenses" class="flex items-center gap-2.5 px-3 py-3 rounded-xl bg-white/[.03] border border-ink-600 hover:border-ops-500/50 transition">
              <svg class="w-5 h-5 text-gray-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/></svg>
              <span class="text-sm font-semibold text-white">Licenses</span>
            </a>
            <a href="#how-it-works" class="flex items-center gap-2.5 px-3 py-3 rounded-xl bg-white/[.03] border border-ink-600 hover:border-ops-500/50 transition">
              <svg class="w-5 h-5 text-gray-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
              <span class="text-sm font-semibold text-white">How it works</span>
            </a>
            <a href="#faq" class="flex items-center gap-2.5 px-3 py-3 rounded-xl bg-white/[.03] border border-ink-600 hover:border-ops-500/50 transition">
              <svg class="w-5 h-5 text-gray-400" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
              <span class="text-sm font-semibold text-white">FAQ</span>
            </a>
          </div>
        </div>
      </div>

    </div>
  </div>
</section>


<!-- ══════════════════════════════════════ ON-SITE IT & NETWORKING ══ -->
<section id="onsite" class="py-16 border-y border-ops-500/20 bg-ops-500/[.04] scroll-mt-20">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="grid lg:grid-cols-12 gap-10 items-start">

      <div class="lg:col-span-7">
        <div class="text-[11px] font-bold uppercase tracking-[.25em] accent mb-3">In person · on-site</div>
        <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight">
          Need someone there in person? Quick and easy.
        </h2>
        <p class="mt-4 text-gray-300 text-lg leading-relaxed max-w-2xl">
          For network setup, cabling, hardware and anything that needs hands on
          the kit, I come to you. No drawn-out process — call, message, or book a
          call-out and we'll sort a time.
        </p>

        <div class="mt-8 grid sm:grid-cols-2 gap-3">
          {% set onsite_items = [
            ('Network setup & cabling', 'Routers, switches, structured cabling, patch panels.'),
            ('Wi-Fi & coverage', 'Access points, mesh, dead-spot fixes, guest networks.'),
            ('Hardware install & repair', 'PCs, NAS, printers, peripherals — set up and fixed on site.'),
            ('Servers & racks', 'On-prem servers, rack tidy-ups, NVR/CCTV networking.'),
            ('Internet & ISP issues', 'Diagnosing drops, line faults, router/modem config.'),
            ('General IT call-outs', 'Anything that needs a person on the ground.'),
          ] %}
          {% for title, desc in onsite_items %}
          <div class="flex items-start gap-3 p-3 rounded-xl bg-ink-900/50 border border-ink-600">
            <span class="check mt-0.5"><svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg></span>
            <div>
              <div class="text-sm font-semibold text-white">{{ title }}</div>
              <div class="text-xs text-gray-400 mt-0.5">{{ desc }}</div>
            </div>
          </div>
          {% endfor %}
        </div>
      </div>

      <div class="lg:col-span-5">
        <div class="card p-6 sm:p-7">
          <div class="flex items-center gap-2 mb-1">
            <span class="live-dot"></span>
            <span class="text-[11px] font-bold uppercase tracking-widest text-gray-400">
              <!-- EDIT: your service area -->
              Providing services across the Scottish Borders and outside of this area at a charge
            </span>
          </div>
          <h3 class="text-xl font-bold text-white mt-2">Book an on-site visit</h3>
          <p class="text-sm text-gray-400 mt-1">Fastest first. Pick whatever suits you.</p>

          <div class="mt-5 space-y-2.5">
            <!-- EDIT: phone number (used in both the link and the label) -->
            <a href="tel:+440000000000"
               class="flex items-center gap-3 p-3.5 rounded-xl bg-ink-900/60 border border-ink-600 hover:border-ops-500/60 transition group">
              <span class="svc-icon w-10 h-10 rounded-lg flex items-center justify-center">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M3 5a2 2 0 012-2h3.28a1 1 0 01.948.684l1.498 4.493a1 1 0 01-.502 1.21l-2.257 1.13a11.042 11.042 0 005.516 5.516l1.13-2.257a1 1 0 011.21-.502l4.493 1.498a1 1 0 01.684.949V19a2 2 0 01-2 2h-1C9.716 21 3 14.284 3 6V5z"/></svg>
              </span>
              <div class="flex-1">
                <div class="text-sm font-semibold text-white">Call</div>
                <div class="text-xs text-gray-400">+44 0000 000 000</div>
              </div>
              <svg class="w-4 h-4 text-gray-500 group-hover:accent transition" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
            </a>

            <!-- EDIT: WhatsApp number, international format, no + or spaces -->
            <a href="https://wa.me/440000000000"
               class="flex items-center gap-3 p-3.5 rounded-xl bg-ink-900/60 border border-ink-600 hover:border-ops-500/60 transition group">
              <span class="w-10 h-10 rounded-lg flex items-center justify-center" style="background:rgba(37,211,102,.12);border:1px solid rgba(37,211,102,.35);color:#25d366;">
                <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M.057 24l1.687-6.163a11.867 11.867 0 01-1.587-5.946C.16 5.335 5.495 0 12.05 0a11.82 11.82 0 018.413 3.488 11.82 11.82 0 013.484 8.414c-.003 6.557-5.338 11.892-11.893 11.892a11.9 11.9 0 01-5.688-1.448L.057 24zm6.597-3.807c1.676.995 3.276 1.591 5.392 1.592 5.448 0 9.886-4.434 9.889-9.885.002-5.462-4.415-9.89-9.881-9.892-5.452 0-9.887 4.434-9.889 9.884a9.86 9.86 0 001.515 5.26l-.999 3.648 3.973-1.607z"/></svg>
              </span>
              <div class="flex-1">
                <div class="text-sm font-semibold text-white">WhatsApp</div>
                <div class="text-xs text-gray-400">Message me directly</div>
              </div>
              <svg class="w-4 h-4 text-gray-500 group-hover:accent transition" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
            </a>

            <a href="{{ url_for('callouts.book') }}" target="_blank" rel="noopener"
               class="flex items-center gap-3 p-3.5 rounded-xl bg-ops-500/[.10] border border-ops-500/40 hover:border-ops-500/70 transition group">
              <span class="svc-icon w-10 h-10 rounded-lg flex items-center justify-center">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"/></svg>
              </span>
              <div class="flex-1">
                <div class="text-sm font-semibold text-white">Book a call-out</div>
                <div class="text-xs text-gray-400">In-person, phone or online — request a time</div>
              </div>
              <svg class="w-4 h-4 accent" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
            </a>

            <!-- EDIT: your email address -->
            <a href="mailto:hello@opslabsystems.cloud"
               class="flex items-center gap-3 p-3.5 rounded-xl bg-ink-900/60 border border-ink-600 hover:border-ops-500/60 transition group">
              <span class="svc-icon w-10 h-10 rounded-lg flex items-center justify-center">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"/></svg>
              </span>
              <div class="flex-1">
                <div class="text-sm font-semibold text-white">Email</div>
                <div class="text-xs text-gray-400">hello@opslabsystems.cloud</div>
              </div>
              <svg class="w-4 h-4 text-gray-500 group-hover:accent transition" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
            </a>
          </div>

          <div class="mt-5 pt-4 border-t border-ink-600/60 flex items-center gap-2 text-xs text-gray-500">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
            <!-- EDIT: your hours -->
            <span>Call-outs Mon–Sat. Same-week slots where possible.</span>
          </div>
        </div>
      </div>

    </div>
  </div>
</section>


<!-- ══════════════════════════════════════════════════════ SERVICES ══ -->
<section id="services" class="py-20 scroll-mt-20">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="max-w-2xl mb-12">
      <div class="text-[11px] font-bold uppercase tracking-[.25em] accent mb-3">What I do</div>
      <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Services, all under one roof.</h2>
      <p class="mt-4 text-gray-400 text-lg">
        One contact, one ticket system. No chasing freelancers across five platforms.
      </p>
    </div>

    <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">

      {% set services = [
        ('Website development', 'Custom sites, dashboards, landing pages, e-commerce and ongoing maintenance.', ['Flask','React','Next.js','WordPress'],
         'M3 7h18M3 7v10a2 2 0 002 2h14a2 2 0 002-2V7M3 7l2-3h14l2 3M8 13h.01M12 13h.01M16 13h.01'),
        ('FiveM development', 'Scripts, MLOs, custom maps and full server builds for QBCore, ESX or standalone.', ['QBCore','ESX','Lua','MLO'],
         'M9 10l-2 2v3a2 2 0 002 2h6a2 2 0 002-2v-3l-2-2M9 10V7a3 3 0 016 0v3M9 10h6'),
        ('Tech support', 'Debugging, troubleshooting and rapid fixes — remote or on-site.', ['Debugging','Log analysis','Triage'],
         'M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065zM15 12a3 3 0 11-6 0 3 3 0 016 0z'),
        ('Hosting', 'VPS, dedicated and game-server hosting. Provisioning, migration and management.', ['VPS','Dedicated','Game servers'],
         'M4 7c0-1.105 3.582-2 8-2s8 .895 8 2-3.582 2-8 2-8-.895-8-2zm0 0v10c0 1.105 3.582 2 8 2s8-.895 8-2V7M4 12c0 1.105 3.582 2 8 2s8-.895 8-2'),
        ('System setup', 'OS install, hardening, monitoring and performance tuning — Linux and Windows.', ['Linux','Windows Server','Hardening'],
         'M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z'),
        ('On-site IT & networking', 'Cabling, Wi-Fi, hardware and network installs — in person, at your place.', ['Networking','Cabling','Wi-Fi'],
         'M17.657 16.657L13.414 20.9a2 2 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0zM15 11a3 3 0 11-6 0 3 3 0 016 0z'),
      ] %}

      {% for title, desc, tags, icon in services %}
      <a href="{% if title == 'On-site IT & networking' %}#onsite{% elif current_user.is_authenticated %}{{ url_for('tickets.new') }}{% else %}{{ url_for('auth.register') }}{% endif %}"
         class="card group p-6 block">
        <div class="svc-icon w-11 h-11 rounded-xl flex items-center justify-center mb-4">
          <svg class="w-6 h-6" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="{{ icon }}"/></svg>
        </div>
        <h3 class="text-lg font-bold mb-2">{{ title }}</h3>
        <p class="text-sm text-gray-400 mb-4 leading-relaxed">{{ desc }}</p>
        <div class="flex flex-wrap gap-1.5">
          {% for t in tags %}<span class="tag">{{ t }}</span>{% endfor %}
        </div>
        <div class="mt-4 text-xs accent font-semibold flex items-center gap-1 opacity-0 group-hover:opacity-100 transition">
          {% if title == 'On-site IT & networking' %}See on-site options{% else %}Open a ticket{% endif %}
          <svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
        </div>
      </a>
      {% endfor %}
    </div>
  </div>
</section>


<!-- ══════════════════════════════════════════════ BRANDS / COMPANIES ══ -->
<section id="companies" class="py-20 border-t border-ink-600/40 scroll-mt-20">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="max-w-2xl mb-12">
      <div class="text-[11px] font-bold uppercase tracking-[.25em] accent mb-3">Brands &amp; projects</div>
      <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight">The brands I build and run.</h2>
      <p class="mt-4 text-gray-400 text-lg">Each one's a focused project. Open a ticket against any of them.</p>
    </div>

    {% if companies %}
    <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
      {% for c in companies %}
      <a href="{{ url_for('tickets.new') }}?company_id={{ c.id }}"
         class="card group p-6 block">
        <div class="flex items-start gap-4">
          {% if c.logo_url %}
            <img src="{{ c.logo_url }}" alt="{{ c.name }}" class="w-12 h-12 rounded-xl object-cover border border-ink-600/60">
          {% else %}
            <div class="w-12 h-12 rounded-xl flex items-center justify-center text-lg font-bold flex-shrink-0"
                 style="background: {{ c.accent_color or '#2196f3' }}1f; color: {{ c.accent_color or '#71b7ff' }};">
              {{ c.name[0]|upper }}
            </div>
          {% endif %}
          <div class="flex-1 min-w-0">
            <div class="text-base font-bold text-white group-hover:accent transition">{{ c.name }}</div>
            {% if c.tagline %}<div class="text-xs text-gray-400 mt-1">{{ c.tagline }}</div>{% endif %}
          </div>
        </div>
        {% if c.description %}
          <p class="text-sm text-gray-400 mt-4 leading-relaxed line-clamp-3">{{ c.description }}</p>
        {% endif %}
        <div class="mt-4 pt-4 border-t border-ink-600/40 flex items-center justify-between">
          {% set _cats = c.categories.all() if c.categories.__class__.__name__ == 'AppenderQuery' else (c.categories or []) %}
          <span class="text-[11px] font-semibold uppercase tracking-widest text-gray-500">
            {{ _cats|length }} service{% if _cats|length != 1 %}s{% endif %}
          </span>
          <span class="text-xs font-semibold accent flex items-center gap-1">
            Open ticket
            <svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
          </span>
        </div>
      </a>
      {% endfor %}
    </div>
    {% else %}
    <div class="text-center py-12 text-sm text-gray-500">No brands listed yet.</div>
    {% endif %}
  </div>
</section>


<!-- ══════════════════════════════════════════════ LICENSE MANAGER ══ -->
<section id="licenses" class="py-20 border-t border-ink-600/40 scroll-mt-20">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="grid lg:grid-cols-2 gap-12 items-center">

      <div>
        <div class="text-[11px] font-bold uppercase tracking-[.25em] accent mb-3">License Manager</div>
        <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight leading-tight">
          License your software, control activations, track usage.
        </h2>
        <p class="mt-4 text-gray-400 text-lg leading-relaxed">
          A licensing platform for the software I sell. Issue keys, lock to IPs or
          hardware, set expiry, and manage tiers and features per customer. A
          self-serve customer portal is included.
        </p>

        <ul class="mt-6 space-y-3 text-sm text-gray-300">
          {% set lic_points = [
            ('Tiered licensing', 'Starter / Basic / Pro / Enterprise per product.'),
            ('IP & hardware locks', 'Bind keys to specific machines or networks.'),
            ('Real-time validation API', 'Software checks in; you control access.'),
            ('Per-feature toggles', 'Enable or disable modules per customer, instantly.'),
          ] %}
          {% for t, d in lic_points %}
          <li class="flex items-start gap-3">
            <span class="check mt-0.5"><svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg></span>
            <span><b class="text-white">{{ t }}</b> — {{ d }}</span>
          </li>
          {% endfor %}
        </ul>

        <div class="mt-8 flex flex-wrap items-center gap-3">
          <a href="/licenses/auth/login"
             class="inline-flex items-center justify-center gap-2 px-5 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"/></svg>
            Admin sign-in
          </a>
          <a href="/licenses/portal/login"
             class="inline-flex items-center justify-center gap-2 px-5 py-3 text-sm font-semibold text-gray-300 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 hover:text-white transition">
            Customer portal
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
          </a>
        </div>
      </div>

      <div>
        <div class="card overflow-hidden p-0">
          <div class="flex items-center gap-2 px-4 py-3 border-b border-ink-600/60 bg-ink-900/60">
            <span class="w-2.5 h-2.5 rounded-full bg-red-500/50"></span>
            <span class="w-2.5 h-2.5 rounded-full bg-yellow-500/50"></span>
            <span class="w-2.5 h-2.5 rounded-full bg-green-500/50"></span>
            <span class="ml-3 text-[11px] font-mono text-gray-500 truncate">/licenses/admin/licenses</span>
            <span class="ml-auto text-[10px] uppercase tracking-widest text-gray-600">Preview</span>
          </div>
          <div class="p-5 space-y-2.5">
            <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500 mb-1">Active keys</div>
            <div class="flex items-center gap-3 p-3 rounded-lg bg-ink-900/60 border border-ink-600/50">
              <span class="w-2 h-2 rounded-full bg-green-400"></span>
              <span class="font-mono text-xs accent">A3F7-XKQ2-9JNP-VBHM</span>
              <span class="ml-auto px-2 py-0.5 rounded-md text-[10px] font-bold uppercase tracking-widest bg-ops-500/15 text-ops-300">Enterprise</span>
            </div>
            <div class="flex items-center gap-3 p-3 rounded-lg bg-ink-900/60 border border-ink-600/50">
              <span class="w-2 h-2 rounded-full bg-green-400"></span>
              <span class="font-mono text-xs text-gray-300">7K2M-Q3PX-N5RT-9HVZ</span>
              <span class="ml-auto px-2 py-0.5 rounded-md text-[10px] font-bold uppercase tracking-widest bg-purple-500/15 text-purple-300">Pro</span>
            </div>
            <div class="flex items-center gap-3 p-3 rounded-lg bg-ink-900/60 border border-ink-600/50">
              <span class="w-2 h-2 rounded-full bg-yellow-400"></span>
              <span class="font-mono text-xs text-gray-300">B8XZ-LP4M-3K2J-W5DR</span>
              <span class="ml-auto px-2 py-0.5 rounded-md text-[10px] font-bold uppercase tracking-widest bg-blue-500/15 text-blue-300">Basic</span>
            </div>
            <div class="flex items-center gap-3 p-3 rounded-lg bg-ink-900/60 border border-ink-600/50">
              <span class="w-2 h-2 rounded-full bg-red-400"></span>
              <span class="font-mono text-xs text-gray-500 line-through">Q1MT-4FB7-X9YE-PR2H</span>
              <span class="ml-auto px-2 py-0.5 rounded-md text-[10px] font-bold uppercase tracking-widest bg-red-500/15 text-red-300">Expired</span>
            </div>
          </div>
        </div>
      </div>

    </div>
  </div>
</section>


<!-- ══════════════════════════════════════════════════ HOW IT WORKS ══ -->
<section id="how-it-works" class="py-20 border-t border-ink-600/40 scroll-mt-20">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="max-w-2xl mb-12">
      <div class="text-[11px] font-bold uppercase tracking-[.25em] accent mb-3">How it works</div>
      <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight">From request to resolution.</h2>
      <p class="mt-4 text-gray-400 text-lg">A real workflow — not a contact form into the void.</p>
    </div>

    <div class="grid md:grid-cols-3 gap-4">
      {% set steps = [
        ('1', 'Open a ticket', 'Pick a service and answer a few short questions — on the web or in Discord, your call.'),
        ('2', 'A private channel opens', 'You get a locked Discord channel mirrored to the web dashboard. Both stay in sync.'),
        ('3', 'Sorted and archived', 'Resolved, transcript saved and searchable. Reopen any time if it comes back.'),
      ] %}
      {% for n, title, desc in steps %}
      <div class="card p-6">
        <div class="w-10 h-10 rounded-xl bg-ops-500/15 border border-ops-500/40 accent flex items-center justify-center font-extrabold mb-4">{{ n }}</div>
        <h3 class="font-bold text-lg mb-2">{{ title }}</h3>
        <p class="text-sm text-gray-400 leading-relaxed">{{ desc }}</p>
      </div>
      {% endfor %}
    </div>
  </div>
</section>


<!-- ════════════════════════════════════════════════════════ WHY US ══ -->
<section id="features" class="py-20 border-t border-ink-600/40 scroll-mt-20">
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="grid lg:grid-cols-12 gap-12 items-start">
      <div class="lg:col-span-5">
        <div class="text-[11px] font-bold uppercase tracking-[.25em] accent mb-3">Why OpsLab</div>
        <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Built for real conversations.</h2>
        <p class="mt-4 text-gray-400 text-lg leading-relaxed">
          Not a contact form. Not a chatbot loop. Not "we'll get back to you in
          5–7 business days." A live, two-way line between you and the person
          doing the work — on whatever platform you actually use.
        </p>
      </div>

      <div class="lg:col-span-7 grid sm:grid-cols-2 gap-4">
        {% set feats = [
          ('Two-way sync', 'Reply on the web, it lands in Discord. Reply in Discord, it shows on the web.', 'M17 8h2a2 2 0 012 2v6a2 2 0 01-2 2h-2v4l-4-4H9a1.994 1.994 0 01-1.414-.586'),
          ('Private channels', 'Each ticket gets a locked Discord channel — only you and the people on the job.', 'M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z'),
          ('One point of contact', 'No "let me check with someone." The person you talk to is the person doing it.', 'M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m12.728 0l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z'),
          ('Full transcripts', 'Every ticket archived in full — web and Discord messages both — even after closing.', 'M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z'),
        ] %}
        {% for title, desc, icon in feats %}
        <div class="card p-6">
          <div class="svc-icon w-10 h-10 rounded-lg flex items-center justify-center mb-3">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="{{ icon }}"/></svg>
          </div>
          <h3 class="font-bold mb-1">{{ title }}</h3>
          <p class="text-sm text-gray-400 leading-relaxed">{{ desc }}</p>
        </div>
        {% endfor %}
      </div>
    </div>
  </div>
</section>


<!-- ═══════════════════════════════════════════════════════ REVIEWS ══ -->
{% if site_reviews %}
<section id="reviews" class="py-20 border-t border-ink-600/40 scroll-mt-20">
  <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
    <div class="text-xs font-bold uppercase tracking-widest text-ops-300 mb-2">What people say</div>
    <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight mb-10">Reviews</h2>

    <div id="revSlider" class="relative min-h-[200px]">
      {% for r in site_reviews %}
      <figure class="rev-slide absolute inset-0 transition-opacity duration-700 ease-in-out {{ 'opacity-100' if loop.first else 'opacity-0 pointer-events-none' }}" data-rev="{{ loop.index0 }}">
        <div class="text-yellow-400 text-2xl mb-4">{{ r.stars }}</div>
        <blockquote class="text-xl sm:text-2xl font-medium text-gray-100 leading-relaxed max-w-3xl mx-auto">“{{ r.body }}”</blockquote>
        <figcaption class="mt-5 text-gray-400">
          <span class="font-semibold text-white">{{ r.name }}</span>
          {% if r.organisation or r.country %}<span class="text-sm"> · {{ [r.organisation, r.country]|select|join(' · ') }}</span>{% endif %}
        </figcaption>
      </figure>
      {% endfor %}
    </div>

    {% if site_reviews|length > 1 %}
    <div id="revDots" class="flex items-center justify-center gap-2 mt-8">
      {% for r in site_reviews %}
      <button class="rev-dot w-2.5 h-2.5 rounded-full transition {{ 'bg-ops-400' if loop.first else 'bg-ink-600 hover:bg-ink-500' }}" data-go="{{ loop.index0 }}" aria-label="Go to review {{ loop.index }}"></button>
      {% endfor %}
    </div>
    {% endif %}

    <div class="mt-10 flex items-center justify-center gap-3">
      <a href="{{ url_for('reviews.index') }}" class="px-5 py-2.5 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">Read all reviews</a>
      <a href="{{ url_for('reviews.new') }}" class="px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Leave a review</a>
    </div>
  </div>

  <script>
  (function(){
    var slides = Array.prototype.slice.call(document.querySelectorAll('#revSlider .rev-slide'));
    var dots   = Array.prototype.slice.call(document.querySelectorAll('#revDots .rev-dot'));
    if (slides.length < 2) return;
    var i = 0, timer = null, DELAY = 20000;
    function show(n){
      i = (n + slides.length) % slides.length;
      slides.forEach(function(s, idx){
        var on = idx === i;
        s.classList.toggle('opacity-100', on);
        s.classList.toggle('opacity-0', !on);
        s.classList.toggle('pointer-events-none', !on);
      });
      dots.forEach(function(d, idx){
        d.classList.toggle('bg-ops-400', idx === i);
        d.classList.toggle('bg-ink-600', idx !== i);
      });
    }
    function next(){ show(i + 1); }
    function start(){ stop(); timer = setInterval(next, DELAY); }
    function stop(){ if (timer) clearInterval(timer); }
    dots.forEach(function(d){
      d.addEventListener('click', function(){ show(parseInt(d.dataset.go, 10)); start(); });
    });
    var slider = document.getElementById('revSlider');
    slider.addEventListener('mouseenter', stop);
    slider.addEventListener('mouseleave', start);
    start();
  })();
  </script>
</section>
{% endif %}


<!-- ═══════════════════════════════════════════════════════════ FAQ ══ -->
<section id="faq" class="py-20 border-t border-ink-600/40 scroll-mt-20">
  <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="mb-10">
      <div class="text-[11px] font-bold uppercase tracking-[.25em] accent mb-3">FAQ</div>
      <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Common questions.</h2>
    </div>

    {% set faqs = [
      ('Do you actually come out in person?',
       'Yes — for network setup, cabling, Wi-Fi, hardware and anything that needs hands on the equipment. Call, WhatsApp or book a call-out and we sort a time.'),
      ('How do I get started?',
       'If it can be done remotely, register and open a ticket — it takes about 30 seconds and quotes are free. For on-site work, just call or message.'),
      ('How quickly do you respond?',
       'Usually within a few hours during the day. The Discord bot opens your ticket channel instantly, around the clock.'),
      ('Is it free?',
       'Quotes are always free. Paid work is scoped together in the ticket first, so there are no surprises on the bill.'),
      ('Can I just use Discord and skip the website?',
       'You can. Every ticket lives on both — if you only touch Discord, the web side just becomes your searchable record.'),
      ('How do you handle confidentiality?',
       'Each ticket channel is locked to you and whoever is on the job. NDAs are fine for anything that needs formal confidentiality.'),
      ('What payment methods do you take?',
       'We sort it in your ticket once the work is scoped — bank transfer, card or crypto all work.'),
    ] %}

    <div id="faq-accordion" data-accordion="collapse">
      {% for q, a in faqs %}
      <h3 id="faq-head-{{ loop.index }}">
        <button type="button"
          class="flex items-center justify-between w-full gap-3 p-5 text-left font-semibold text-white bg-ink-800/60 border border-ink-600 {% if loop.first %}rounded-t-xl{% endif %}{% if not loop.first %} border-t-0{% endif %} hover:bg-ink-800 transition"
          data-accordion-target="#faq-body-{{ loop.index }}" aria-expanded="false" aria-controls="faq-body-{{ loop.index }}">
          <span>{{ q }}</span>
          <svg data-accordion-icon class="w-4 h-4 shrink-0 rotate-180 transition-transform" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 15l7-7 7 7"/></svg>
        </button>
      </h3>
      <div id="faq-body-{{ loop.index }}" class="hidden" aria-labelledby="faq-head-{{ loop.index }}">
        <div class="p-5 border border-ink-600 border-t-0 {% if loop.last %}rounded-b-xl{% endif %} bg-ink-900/40 text-sm text-gray-400 leading-relaxed">
          {{ a }}
        </div>
      </div>
      {% endfor %}
    </div>
  </div>
</section>


<!-- ═══════════════════════════════════════════════════════════ CTA ══ -->
<section class="py-20">
  <div class="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
    <div class="card p-8 sm:p-12 bg-gradient-to-br from-ops-700/25 to-ink-900 border-ops-500/30">
      <div class="grid md:grid-cols-5 gap-8 items-center">
        <div class="md:col-span-3">
          <h2 class="text-3xl sm:text-4xl font-extrabold tracking-tight leading-tight">Let's sort it out.</h2>
          <p class="mt-3 text-gray-300 text-lg max-w-xl">
            Open a ticket for remote work, or grab me for an on-site visit. Free to
            sign up, no card needed.
          </p>
        </div>
        <div class="md:col-span-2 flex flex-col gap-3 md:items-end">
          {% if current_user.is_authenticated %}
            <a href="{{ url_for('tickets.new') }}"
               class="w-full md:w-auto inline-flex items-center justify-center gap-2 px-7 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">
              Open a ticket
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
            </a>
            <a href="#onsite"
               class="w-full md:w-auto inline-flex items-center justify-center gap-2 px-7 py-3 text-sm font-semibold text-white bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">
              Book an on-site visit
            </a>
          {% else %}
            <a href="{{ url_for('auth.register') }}"
               class="w-full md:w-auto inline-flex items-center justify-center gap-2 px-7 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">
              Create your account
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
            </a>
            <a href="#onsite"
               class="w-full md:w-auto inline-flex items-center justify-center gap-2 px-7 py-3 text-sm font-semibold text-white bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">
              Book an on-site visit
            </a>
          {% endif %}
        </div>
      </div>
    </div>
  </div>
</section>

{% endblock %}
__OPSLAB_EOF__
write "app/templates/gateway.html" << '__OPSLAB_EOF__'
<!doctype html>
<html lang="en" class="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Welcome · OpsLab Systems</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
  <style>
    :root{ --ops:#2196f3; --ops2:#1769aa; }
    *{ box-sizing:border-box; }
    body{
      margin:0; min-height:100vh; font-family:'Plus Jakarta Sans',system-ui,sans-serif;
      color:#e7edf5; background:#0a0f16;
      background-image:radial-gradient(60rem 40rem at 80% -10%, rgba(33,150,243,.16), transparent 60%),
                       radial-gradient(50rem 40rem at -10% 110%, rgba(33,150,243,.10), transparent 55%);
      display:flex; align-items:center; justify-content:center; padding:24px;
    }
    .wrap{ width:100%; max-width:920px; }
    .brand{ display:flex; align-items:center; gap:10px; justify-content:center; margin-bottom:18px; }
    .logo{ width:34px;height:34px;border-radius:9px;background:linear-gradient(135deg,var(--ops),var(--ops2));
           display:flex;align-items:center;justify-content:center;font-weight:800;color:#fff;box-shadow:0 6px 20px rgba(33,150,243,.4); }
    h1{ font-size:clamp(1.7rem,4vw,2.6rem); font-weight:800; text-align:center; margin:.2em 0 .15em; letter-spacing:-.02em; }
    .sub{ text-align:center; color:#9fb0c3; margin:0 auto 34px; max-width:34rem; }
    .grid{ display:grid; grid-template-columns:1fr; gap:18px; }
    @media(min-width:720px){ .grid{ grid-template-columns:1fr 1fr; } }
    .card{
      display:flex; flex-direction:column; text-decoration:none; color:inherit;
      background:rgba(255,255,255,.03); border:1px solid rgba(255,255,255,.10);
      border-radius:20px; padding:28px; transition:transform .18s ease, border-color .18s ease, background .18s ease;
    }
    .card:hover{ transform:translateY(-4px); border-color:rgba(33,150,243,.6); background:rgba(33,150,243,.07); }
    .ic{ width:52px;height:52px;border-radius:14px;display:flex;align-items:center;justify-content:center;margin-bottom:16px;
         background:rgba(33,150,243,.14); border:1px solid rgba(33,150,243,.35); color:#7cc0ff; }
    .ic svg{ width:26px;height:26px; }
    .card h2{ font-size:1.3rem; font-weight:700; margin:0 0 8px; }
    .card p{ color:#9fb0c3; margin:0; line-height:1.55; font-size:.95rem; flex:1; }
    .go{ display:inline-flex; align-items:center; gap:8px; margin-top:20px; font-weight:600; color:#7cc0ff; }
    .go svg{ width:18px;height:18px; transition:transform .18s ease; }
    .card:hover .go svg{ transform:translateX(4px); }
    .foot{ text-align:center; color:#5e6b7a; font-size:.8rem; margin-top:30px; }
    .foot a{ color:#9fb0c3; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="brand">
      <span class="logo">O</span>
      <span style="font-weight:700;font-size:1.05rem;">OpsLab Systems</span>
    </div>
    <h1>Welcome to OpsLab Systems</h1>
    <p class="sub">How can we help you today? Choose the option that best fits what you're after.</p>

    <div class="grid">
      <a class="card" href="/enter?to=cloud">
        <span class="ic">
          <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M3 15a4 4 0 004 4h9a5 5 0 10-.1-9.999 5.002 5.002 0 00-9.78 1.51A4.002 4.002 0 003 15z"/></svg>
        </span>
        <h2>Cloud &amp; Online Services</h2>
        <p>Hosting, cloud infrastructure, remote support and managed services.</p>
        <span class="go">Continue to website
          <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
        </span>
      </a>

      <a class="card" href="/enter?to=onsite">
        <span class="ic">
          <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17.657 16.657L13.414 20.9a2 2 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/><path stroke-linecap="round" stroke-linejoin="round" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/></svg>
        </span>
        <h2>Onsite &amp; In-Person Services</h2>
        <p>Local IT support, installations, business visits and hardware setup.</p>
        <span class="go">View on-site services
          <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
        </span>
      </a>
    </div>

    <a class="card partner-card" href="/partners" style="margin-top:18px;display:flex;align-items:center;gap:16px;text-align:left;flex-wrap:wrap;">
      <span class="ic" style="flex-shrink:0;background:rgba(124,92,255,.14);color:#b9a8ff;box-shadow:inset 0 0 0 1px rgba(124,92,255,.3);">
        <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M17 20h5v-2a4 4 0 00-3-3.87M9 20H4v-2a4 4 0 013-3.87m6-1.13a4 4 0 10-4-4 4 4 0 004 4zm6 0a3 3 0 10-3-3"/></svg>
      </span>
      <span style="flex:1;">
        <h2 style="margin:0 0 4px;">Register your company or community</h2>
        <p style="margin:0;">Run a business or developer community? Become a partner with OpsLab Systems and get your own page.</p>
      </span>
      <span class="go" style="margin:0;white-space:nowrap;">Become a partner
        <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
      </span>
    </a>

    <p class="foot">Across the Scottish Borders &amp; beyond · <a href="/enter?to=cloud">Skip &amp; go to site</a></p>
  </div>
</body>
</html>
__OPSLAB_EOF__
write "app/templates/onsitesupport.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}On-site &amp; In-Person IT Support · OpsLab Systems{% endblock %}
{% block content %}

<style>
  #onsite-acc summary{ list-style:none; }
  #onsite-acc summary::-webkit-details-marker{ display:none; }
  #onsite-acc details[open] .chev{ transform:rotate(180deg); }
  #onsite-acc details[open]{ border-color:rgba(33,150,243,.45); }
</style>

<div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-12 sm:py-16">

  <!-- ── TOP: Need someone on-site? ───────────────────────────────── -->
  <div class="rounded-3xl border border-ops-500/30 bg-ops-500/[.07] p-8 sm:p-12 text-center">
    <div class="flex items-center justify-center gap-2 text-xs font-bold uppercase tracking-widest text-ops-300 mb-3">
      <span class="live-dot"></span> On-site &amp; in-person
    </div>
    <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Need someone on-site?</h1>
    <p class="mt-3 text-gray-300 max-w-xl mx-auto leading-relaxed">
      Request an in-person visit within the Scottish Borders, or a phone/online session if you're
      further afield. We'll confirm a time with you. Outside the area is available at a charge.
    </p>
    <div class="mt-7 flex flex-wrap gap-3 justify-center">
      <a href="{{ url_for('callouts.book') }}" class="inline-flex items-center gap-2 px-7 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">
        Book a call-out
        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
      </a>
      <button onclick="openContactModal()" class="inline-flex items-center gap-2 px-7 py-3 text-sm font-semibold text-white bg-white/10 border border-ink-600 rounded-xl hover:bg-white/15 transition">
        📞 Call us now
      </button>
      <a href="{{ url_for('reviews.index') }}" class="inline-flex items-center gap-2 px-7 py-3 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">Read reviews</a>
      <a href="{{ url_for('callouts.pricing') }}" class="inline-flex items-center gap-2 px-7 py-3 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">View pricing</a>
    </div>
    <div class="mt-4">
      <a href="{{ url_for('main.index') }}" class="text-sm text-gray-400 hover:text-ops-300 transition">Looking for cloud &amp; online services? →</a>
    </div>
  </div>

  <!-- ── Expandable info ──────────────────────────────────────────── -->
  <h2 class="text-xl sm:text-2xl font-extrabold tracking-tight mt-12 mb-4">More about on-site visits</h2>

  <div id="onsite-acc" class="space-y-3">

    {% set svcs = [
      ('Local IT support', 'On-the-spot troubleshooting and repairs for homes and businesses — slow machines, network drop-outs, email and printer problems, virus clean-ups and general "it just stopped working" fixes.', 'M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.324.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 011.37.49l1.296 2.247a1.125 1.125 0 01-.26 1.431l-1.003.827c-.293.24-.438.613-.431.992a6.759 6.759 0 010 .255c-.007.378.138.75.43.99l1.005.828c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 01-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.57 6.57 0 01-.22.128c-.331.183-.581.495-.644.869l-.213 1.28c-.09.543-.56.941-1.11.941h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 01-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 01-1.369-.49l-1.297-2.247a1.125 1.125 0 01.26-1.431l1.004-.827c.292-.24.437-.613.43-.992a6.932 6.932 0 010-.255c.007-.378-.138-.75-.43-.99l-1.004-.828a1.125 1.125 0 01-.26-1.43l1.297-2.247a1.125 1.125 0 011.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.281z'),
      ('Installations', 'Networking, Wi-Fi, CCTV, devices and peripherals fitted and configured properly the first time — including cabling, mesh coverage and smart-home or office kit.', 'M9 17v-2m3 2v-4m3 4v-6m2 10H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z'),
      ('Business visits', 'Scheduled on-site visits to keep your office running smoothly — regular check-ins, user setups, account changes and quick fixes so your team stays productive.', 'M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5'),
      ('Hardware setup', 'New PCs, laptops, servers and equipment set up, data migrated and everything ready to go — so you can switch on and start working.', 'M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z'),
      ('Coverage &amp; charges', 'In-person visits are provided across the Scottish Borders. We can also travel outside the area at an additional charge, or handle things by phone and online if that suits you better.', 'M17.657 16.657L13.414 20.9a2 2 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z M15 11a3 3 0 11-6 0 3 3 0 016 0z'),
      ('Same-day &amp; next-day call-outs', 'I do my best to offer same-day or next-day call-outs. It isn’t always possible — it depends on your location, how booked-up the day is, and parts availability — but tell me your preferred date and time and I’ll confirm the soonest slot I can.', 'M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z'),
      ('How a call-out works', 'Tap “Book a call-out”, tell us what you need and a preferred time, and we’ll confirm with you. Prefer to talk first? Hit “Call us now” to phone or WhatsApp us directly.', 'M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z')
    ] %}

    {% for name, desc, icon in svcs %}
    <details class="rounded-2xl border border-ink-600 bg-ink-800/40 overflow-hidden transition-colors">
      <summary class="flex items-center gap-4 p-5 cursor-pointer hover:bg-white/[.03] transition">
        <span class="svc-icon w-11 h-11 rounded-xl flex items-center justify-center shrink-0">
          <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="1.7" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="{{ icon }}"/></svg>
        </span>
        <span class="flex-1 font-bold text-white">{{ name|safe }}</span>
        <svg class="chev w-5 h-5 text-gray-400 transition-transform shrink-0" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7"/></svg>
      </summary>
      <div class="px-5 pb-5 sm:pl-20 text-gray-300 leading-relaxed">{{ desc|safe }}</div>
    </details>
    {% endfor %}

  </div>

  <div class="mt-10 text-center">
    <a href="{{ url_for('callouts.book') }}" class="inline-flex items-center gap-2 px-7 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Book a call-out</a>
  </div>
</div>

<!-- Contact modal -->
<div id="contactModal" class="fixed inset-0 bg-black/60 hidden items-center justify-center z-50">
  <div class="bg-ink-900 border border-ink-600 rounded-2xl p-6 max-w-sm w-full mx-4">
    <h3 class="text-xl font-bold text-white mb-2">Contact OpsLab Networking</h3>
    <p class="text-gray-400 mb-6">Choose how you'd like to get in touch with us.</p>
    <div class="space-y-3">
      <a href="tel:+447448421725" class="flex items-center justify-center w-full px-4 py-3 bg-blue-600 hover:bg-blue-700 text-white font-semibold rounded-xl transition">📞 Call +44 7448 421725</a>
      <a href="https://wa.me/447448421725" target="_blank" rel="noopener" class="flex items-center justify-center w-full px-4 py-3 bg-green-600 hover:bg-green-700 text-white font-semibold rounded-xl transition">💬 WhatsApp us</a>
    </div>
    <button onclick="closeContactModal()" class="mt-4 w-full px-4 py-3 bg-white/5 hover:bg-white/10 text-gray-300 rounded-xl transition">Close</button>
  </div>
</div>

<script>
function openContactModal(){
  var m=document.getElementById('contactModal');
  m.classList.remove('hidden'); m.classList.add('flex');
}
function closeContactModal(){
  var m=document.getElementById('contactModal');
  m.classList.add('hidden'); m.classList.remove('flex');
}
document.getElementById('contactModal').addEventListener('click', function(e){
  if(e.target === this) closeContactModal();
});
document.addEventListener('keydown', function(e){ if(e.key==='Escape') closeContactModal(); });
</script>

{% endblock %}
__OPSLAB_EOF__
write "app/templates/auth/login.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block content %}
<section class="relative min-h-[calc(100vh-4rem)] flex items-center justify-center py-16 px-4 overflow-hidden">
  <!-- Ambient background -->
  <div class="absolute inset-0 grid-overlay pointer-events-none opacity-40"></div>
  <div class="absolute top-1/4 -left-32 w-[500px] h-[500px] bg-ops-700/20 rounded-full blur-3xl pointer-events-none"></div>
  <div class="absolute bottom-1/4 -right-32 w-[500px] h-[500px] bg-ops-500/15 rounded-full blur-3xl pointer-events-none"></div>

  <div class="relative w-full max-w-md animate-fade-up">
    <!-- Card -->
    <div class="relative">
      <div class="absolute -inset-2 bg-gradient-to-tr from-ops-700/30 to-ops-400/20 rounded-3xl blur-2xl opacity-50"></div>
      <div class="relative bg-ink-800/80 backdrop-blur-xl border border-ink-600 rounded-2xl p-8 shadow-2xl">

        <!-- Logo -->
        <div class="flex justify-center mb-6">
          <svg viewBox="0 0 64 64" width="48" height="48">
            <polygon points="32,4 56,18 56,46 32,60 8,46 8,18" fill="none" stroke="#2196f3" stroke-width="4"/>
            <polygon points="32,4 56,18 32,32" fill="#2196f3"/>
            <polygon points="32,32 56,18 56,46 32,60" fill="#ffffff" opacity=".95"/>
          </svg>
        </div>

        <h1 class="text-3xl font-extrabold text-center tracking-tight">Welcome back</h1>
        <p class="text-center text-sm text-gray-400 mt-2">Sign in to your Ops Labs account</p>

        <form method="post" class="mt-8 space-y-5">
          <div>
            <label class="block text-xs font-semibold text-gray-300 mb-1.5 uppercase tracking-wider">Username or Email</label>
            <div class="relative">
              <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none text-gray-500">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/></svg>
              </div>
              <input type="text" name="identifier" required autofocus
                class="form-input w-full pl-10 pr-4 py-2.5 text-sm"
                placeholder="admin or admin@opslabs.local">
            </div>
          </div>

          <div>
            <div class="flex items-center justify-between mb-1.5">
              <label class="block text-xs font-semibold text-gray-300 uppercase tracking-wider">Password</label>
              <a href="{{ url_for('auth.forgot') }}" class="text-xs text-ops-400 hover:text-ops-300">Forgot?</a>
            </div>
            <div class="relative">
              <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none text-gray-500">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/></svg>
              </div>
              <input type="password" name="password" required
                class="form-input w-full pl-10 pr-4 py-2.5 text-sm"
                placeholder="••••••••">
            </div>
          </div>

          <button type="submit" class="w-full inline-flex justify-center items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow hover:scale-[1.01] transition">
            Sign in
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 5l7 7m0 0l-7 7m7-7H3"/></svg>
          </button>
        </form>

        {% if sso_providers %}
        <div class="my-6 flex items-center gap-4">
          <div class="flex-1 h-px bg-ink-600"></div>
          <span class="text-xs text-gray-500 uppercase tracking-widest">or continue with</span>
          <div class="flex-1 h-px bg-ink-600"></div>
        </div>
        <div class="grid grid-cols-1 {{ 'sm:grid-cols-2' if sso_providers|length > 1 }} gap-3">
          {% for pid, p in sso_providers.items() %}
          <a href="{{ url_for('sso.start', provider=pid, next=request.args.get('next','')) }}"
             class="inline-flex items-center justify-center gap-2.5 px-4 py-2.5 text-sm font-semibold rounded-xl border border-ink-600 hover:opacity-90 transition"
             style="background:{{ p.color }};color:{{ p.text }};">
            <svg class="w-4 h-4" viewBox="0 0 24 24" fill="currentColor"><path d="{{ p.icon }}"/></svg>
            {{ p.label }}
          </a>
          {% endfor %}
        </div>
        {% endif %}

        <!-- Divider -->
        <div class="my-6 flex items-center gap-4">
          <div class="flex-1 h-px bg-ink-600"></div>
          <span class="text-xs text-gray-500 uppercase tracking-widest">or</span>
          <div class="flex-1 h-px bg-ink-600"></div>
        </div>

        <a href="{{ url_for('auth.register') }}" class="w-full inline-flex justify-center items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">
          Create an account
        </a>
      </div>
    </div>

    <p class="text-center text-xs text-gray-500 mt-6">By signing in you agree to Ops Labs' terms of service.</p>
  </div>
</section>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/partners/landing.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}Become a Partner · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-16 text-center">
  <div class="text-xs font-bold uppercase tracking-widest text-ops-300 mb-3">Partner Program</div>
  <h1 class="text-4xl sm:text-5xl font-extrabold tracking-tight">Become a Partner with OpsLab Systems</h1>
  <p class="text-gray-400 mt-4 text-lg">List your company or developer community on the OpsLab platform, get your own page, and reach more customers — with a clear, fair partner agreement.</p>

  <div class="mt-8 flex flex-wrap justify-center gap-3">
    {% if accepted %}
      <a href="{{ url_for('partners.new') }}" class="px-7 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Create a company</a>
      <a href="{{ url_for('partners.mine') }}" class="px-7 py-3 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10">My companies</a>
    {% else %}
      <a href="{{ url_for('partners.agreement') }}" class="px-7 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Read &amp; sign the agreement</a>
      {% if not current_user.is_authenticated %}
      <a href="{{ url_for('auth.register') }}" class="px-7 py-3 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10">Create an account</a>
      {% endif %}
    {% endif %}
  </div>

  <div class="grid sm:grid-cols-3 gap-4 mt-12 text-left">
    {% set steps = [
      ('1', 'Sign the agreement', 'Read and electronically sign the partner agreement.'),
      ('2', 'Register your company', 'Add your details, services and legal pages.'),
      ('3', 'Get approved & go live', 'We review it, then it publishes under OpsLab.')
    ] %}
    {% for n, t, d in steps %}
    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
      <div class="w-8 h-8 rounded-lg bg-ops-500/15 text-ops-300 font-bold flex items-center justify-center mb-3">{{ n }}</div>
      <div class="font-semibold text-white">{{ t }}</div>
      <p class="text-sm text-gray-400 mt-1">{{ d }}</p>
    </div>
    {% endfor %}
  </div>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/partners/agreement.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}Partner Agreement · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
  <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Partner &amp; Independent Service Provider Agreement</h1>
  <p class="text-gray-500 text-sm mt-1">Version {{ version }}</p>

  {% for cat, msg in get_flashed_messages(with_categories=true) %}
    <div class="mt-5 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
  {% endfor %}

  <div class="mt-6 rounded-2xl border border-ink-600 bg-ink-900/40 p-6 max-h-[55vh] overflow-y-auto text-sm text-gray-300 leading-relaxed whitespace-pre-line">{{ text }}</div>

  {% if acceptance %}
    <div class="mt-6 rounded-xl border border-green-500/30 bg-green-500/10 text-green-200 p-4 text-sm">
      ✓ Signed by <strong>{{ acceptance.full_legal_name }}</strong> on {{ acceptance.accepted_at.strftime('%d %b %Y, %H:%M') }} (v{{ acceptance.version }}).
      <div class="mt-3">
        <a href="{{ url_for('partners.new') }}" class="inline-block px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl">Create a company →</a>
      </div>
    </div>
  {% elif current_user.is_authenticated %}
    <form method="post" action="{{ url_for('partners.accept') }}" class="mt-6 rounded-2xl border border-ink-600 bg-ink-800/40 p-6 space-y-4">
      <div>
        <label class="block text-sm font-semibold mb-1.5">Full legal name <span class="text-red-400">*</span></label>
        <input name="full_legal_name" required class="form-input w-full" placeholder="As it appears on legal documents">
      </div>
      <label class="flex items-start gap-3 text-sm text-gray-300">
        <input type="checkbox" name="agree" class="mt-1"> I have read and accept the Partner Agreement, and confirm the information I provide is true.
      </label>
      <button class="px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Sign &amp; accept</button>
    </form>
  {% else %}
    <div class="mt-6 rounded-2xl border border-ink-600 bg-ink-800/40 p-6 text-sm text-gray-300">
      Please <a href="{{ url_for('auth.login', next=url_for('partners.agreement')) }}" class="text-ops-300 font-semibold">log in</a>
      or <a href="{{ url_for('auth.register') }}" class="text-ops-300 font-semibold">create an account</a> to sign the agreement.
    </div>
  {% endif %}
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/partners/register.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}Register a company · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
  <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Register your company</h1>
  <p class="text-gray-400 mt-2 text-sm">Tell us about your company. After you submit, our team reviews it before it goes live.</p>

  {% for cat, msg in get_flashed_messages(with_categories=true) %}
    <div class="mt-5 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
  {% endfor %}

  <form method="post" class="mt-6 space-y-5">
    <div>
      <label class="block text-sm font-semibold mb-1.5">Company name <span class="text-red-400">*</span></label>
      <input name="name" required value="{{ form.get('name','') }}" class="form-input w-full" placeholder="e.g. Borders Dev Co">
    </div>
    <div class="grid sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-sm font-semibold mb-1.5">Company type</label>
        <select name="ctype" class="form-select w-full">
          {% for t in types %}<option {{ 'selected' if form.get('ctype')==t }}>{{ t }}</option>{% endfor %}
        </select>
      </div>
      <div>
        <label class="block text-sm font-semibold mb-1.5">Legal business status</label>
        <select name="legal_status" class="form-select w-full">
          {% for l in legal %}<option {{ 'selected' if form.get('legal_status')==l }}>{{ l }}</option>{% endfor %}
        </select>
      </div>
    </div>
    <div class="grid sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-sm font-semibold mb-1.5">Full legal name of owner</label>
        <input name="owner_legal_name" value="{{ form.get('owner_legal_name','') }}" class="form-input w-full">
      </div>
      <div>
        <label class="block text-sm font-semibold mb-1.5">Country / region</label>
        <input name="country" value="{{ form.get('country','') }}" class="form-input w-full">
      </div>
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Description</label>
      <textarea name="description" rows="3" class="form-textarea w-full" placeholder="What does your company do?">{{ form.get('description','') }}</textarea>
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Services offered</label>
      <textarea name="services" rows="3" class="form-textarea w-full" placeholder="List your services, one per line">{{ form.get('services','') }}</textarea>
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Pricing / packages <span class="text-gray-500 font-normal">(optional)</span></label>
      <textarea name="pricing" rows="2" class="form-textarea w-full">{{ form.get('pricing','') }}</textarea>
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">External website <span class="text-gray-500 font-normal">(optional)</span></label>
      <input name="external_url" value="{{ form.get('external_url','') }}" class="form-input w-full" placeholder="https://…">
    </div>
    <div class="grid sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-sm font-semibold mb-1.5">Terms &amp; Conditions <span class="text-gray-500 font-normal">(optional)</span></label>
        <textarea name="terms" rows="3" class="form-textarea w-full">{{ form.get('terms','') }}</textarea>
      </div>
      <div>
        <label class="block text-sm font-semibold mb-1.5">Privacy Policy <span class="text-gray-500 font-normal">(optional)</span></label>
        <textarea name="privacy" rows="3" class="form-textarea w-full">{{ form.get('privacy','') }}</textarea>
      </div>
    </div>
    <button class="px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Submit for review</button>
  </form>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/partners/mine.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}My companies · OpsLab Systems{% endblock %}
{% set colors = {'gray':'bg-white/5 text-gray-300 border-ink-600','amber':'bg-amber-500/15 text-amber-300 border-amber-500/30','blue':'bg-blue-500/15 text-blue-300 border-blue-500/30','green':'bg-green-500/15 text-green-300 border-green-500/30','red':'bg-red-500/15 text-red-300 border-red-500/30'} %}
{% block content %}
<div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
  <div class="flex items-center justify-between gap-4 mb-8">
    <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">My companies</h1>
    <a href="{{ url_for('partners.new') }}" class="px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl whitespace-nowrap">+ New company</a>
  </div>

  {% for cat, msg in get_flashed_messages(with_categories=true) %}
    <div class="mb-5 text-sm px-4 py-2.5 rounded-lg bg-green-500/10 border border-green-500/30 text-green-200">{{ msg }}</div>
  {% endfor %}

  {% if companies %}
  <div class="space-y-4">
    {% for c in companies %}
    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
      <div class="flex items-start justify-between gap-4">
        <div>
          <div class="font-bold text-lg text-white">{{ c.name }}</div>
          <div class="text-xs text-gray-500 mt-0.5">/partners/{{ c.slug }} · submitted {{ c.created_at.strftime('%d %b %Y') }}</div>
        </div>
        <span class="px-2.5 py-1 rounded-lg text-xs font-bold border {{ colors.get(c.status_color, colors['gray']) }}">{{ c.status_label }}</span>
      </div>

      <div class="mt-4">
        <div class="h-2 rounded-full bg-ink-900 overflow-hidden">
          <div class="h-full bg-gradient-to-r from-ops-500 to-ops-700" style="width: {{ c.progress }}%"></div>
        </div>
      </div>

      {% if c.status == 'rejected' and c.rejection_reason %}
      <div class="mt-4 rounded-lg bg-red-500/10 border border-red-500/30 text-red-200 text-sm p-3">
        <div class="font-semibold mb-1">Reason for rejection</div>{{ c.rejection_reason }}
      </div>
      {% endif %}
      {% if c.review_notes %}
      <div class="mt-3 rounded-lg bg-ink-900/40 border border-ink-600/60 text-sm text-gray-300 p-3">
        <div class="font-semibold text-ops-300 mb-1">Admin feedback / requested changes</div>{{ c.review_notes }}
      </div>
      {% endif %}

      <div class="mt-4 flex gap-2">
        {% if c.is_public %}
        <a href="{{ url_for('partners.public', slug=c.slug) }}" class="px-4 py-2 text-xs font-semibold text-white bg-ops-600 hover:bg-ops-500 rounded-lg">View live page</a>
        {% else %}
        <a href="{{ url_for('partners.public', slug=c.slug) }}" class="px-4 py-2 text-xs font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-lg">Preview</a>
        {% endif %}
      </div>
    </div>
    {% endfor %}
  </div>
  {% else %}
  <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-10 text-center">
    <p class="text-gray-400">You haven't registered a company yet.</p>
    <a href="{{ url_for('partners.new') }}" class="inline-block mt-4 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl">Register a company</a>
  </div>
  {% endif %}
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/partners/public.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}{{ c.name }} · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
  {% if preview %}
  <div class="mb-6 rounded-xl border border-amber-500/30 bg-amber-500/10 text-amber-200 text-sm px-4 py-2.5">
    Preview — this page isn't public yet ({{ c.status_label }}). Only you and staff can see it.
  </div>
  {% endif %}

  <div class="flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-ops-300 mb-2">{{ c.ctype }}{% if c.country %} · {{ c.country }}{% endif %}</div>
  <h1 class="text-4xl font-extrabold tracking-tight">{{ c.name }}</h1>
  {% if c.description %}<p class="text-gray-300 mt-4 text-lg whitespace-pre-line">{{ c.description }}</p>{% endif %}

  {% if c.external_url %}
  <a href="{{ c.external_url }}" target="_blank" rel="nofollow noopener" class="inline-flex items-center gap-2 mt-5 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl">Visit website ↗</a>
  {% endif %}

  {% if c.services %}
  <div class="mt-10">
    <h2 class="text-xl font-bold mb-3">Services</h2>
    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5 text-gray-300 whitespace-pre-line">{{ c.services }}</div>
  </div>
  {% endif %}

  {% if c.pricing %}
  <div class="mt-8">
    <h2 class="text-xl font-bold mb-3">Pricing &amp; packages</h2>
    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5 text-gray-300 whitespace-pre-line">{{ c.pricing }}</div>
  </div>
  {% endif %}

  {% if c.terms or c.privacy %}
  <div class="mt-10 flex flex-wrap gap-4 text-sm">
    {% if c.terms %}<details class="rounded-xl border border-ink-600 bg-ink-800/40 p-4 flex-1 min-w-[240px]"><summary class="font-semibold cursor-pointer">Terms &amp; Conditions</summary><div class="mt-2 text-gray-400 whitespace-pre-line">{{ c.terms }}</div></details>{% endif %}
    {% if c.privacy %}<details class="rounded-xl border border-ink-600 bg-ink-800/40 p-4 flex-1 min-w-[240px]"><summary class="font-semibold cursor-pointer">Privacy Policy</summary><div class="mt-2 text-gray-400 whitespace-pre-line">{{ c.privacy }}</div></details>{% endif %}
  </div>
  {% endif %}

  <p class="text-xs text-gray-600 mt-10">Listed on OpsLab Systems. This company operates as an independent service provider.</p>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/admin/partners/list.html" << '__OPSLAB_EOF__'
{% extends "admin/_layout.html" %}
{% block admin_title %}Partners{% endblock %}
{% set colors = {'gray':'bg-white/5 text-gray-300 border-ink-600','amber':'bg-amber-500/15 text-amber-300 border-amber-500/30','blue':'bg-blue-500/15 text-blue-300 border-blue-500/30','green':'bg-green-500/15 text-green-300 border-green-500/30','red':'bg-red-500/15 text-red-300 border-red-500/30'} %}
{% block admin_content %}
<div class="mb-8">
  <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Partner companies</h1>
  <p class="text-gray-400 mt-1 text-sm">Review submissions, set status, leave feedback, and manage the partner agreement.</p>
</div>

{% for cat, msg in get_flashed_messages(with_categories=true) %}
  <div class="mb-5 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
{% endfor %}

<div class="flex flex-wrap gap-2 mb-5 text-sm">
  {% for key in ['all'] + statuses.keys()|list %}
  <a href="{{ url_for('partners.admin_list', status=key) }}" class="px-3 py-1.5 rounded-lg border {{ 'bg-ops-500/15 text-ops-200 border-ops-500/30' if show==key else 'bg-white/5 text-gray-300 border-ink-600' }}">{{ 'All' if key=='all' else statuses[key][0] }}</a>
  {% endfor %}
</div>

{% if companies %}
<div class="space-y-4">
  {% for c in companies %}
  <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
    <div class="flex items-start justify-between gap-4">
      <div>
        <div class="font-bold text-lg text-white">{{ c.name }}
          <span class="ml-2 px-2 py-0.5 rounded text-xs font-bold border {{ colors.get(c.status_color, colors['gray']) }}">{{ c.status_label }}</span>
        </div>
        <div class="text-xs text-gray-500 mt-1">{{ c.ctype }} · {{ c.legal_status }} · {{ c.country or '—' }} · owner: {{ c.owner.username if c.owner else '—' }}</div>
        <div class="text-xs text-gray-500">/partners/{{ c.slug }} · {{ c.created_at.strftime('%d %b %Y') }}</div>
      </div>
      <div class="flex gap-2 shrink-0">
        <a href="{{ url_for('partners.public', slug=c.slug) }}" target="_blank" class="px-3 py-1.5 text-xs font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-lg">View</a>
        <form method="post" action="{{ url_for('partners.admin_delete', cid=c.id, status=show) }}" onsubmit="return confirm('Delete this company?');">
          <button class="px-3 py-1.5 text-xs font-semibold text-red-300 bg-red-500/10 border border-red-500/30 rounded-lg">Delete</button>
        </form>
      </div>
    </div>

    {% if c.description %}<p class="text-sm text-gray-400 mt-3 whitespace-pre-line">{{ c.description }}</p>{% endif %}

    <form method="post" action="{{ url_for('partners.admin_status', cid=c.id, status=show) }}" class="mt-4 grid sm:grid-cols-2 gap-3">
      <div>
        <label class="block text-xs font-semibold text-gray-400 mb-1">Status</label>
        <select name="status" class="form-select w-full text-sm">
          {% for key, meta in statuses.items() %}<option value="{{ key }}" {{ 'selected' if c.status==key }}>{{ meta[0] }}</option>{% endfor %}
        </select>
      </div>
      <div class="sm:row-span-2">
        <label class="block text-xs font-semibold text-gray-400 mb-1">Feedback / requested changes</label>
        <textarea name="review_notes" rows="3" class="form-textarea w-full text-sm">{{ c.review_notes or '' }}</textarea>
      </div>
      <div>
        <label class="block text-xs font-semibold text-gray-400 mb-1">Rejection reason (if rejected)</label>
        <input name="rejection_reason" value="{{ c.rejection_reason or '' }}" class="form-input w-full text-sm">
      </div>
      <div class="sm:col-span-2">
        <button class="px-4 py-2 text-sm font-semibold text-white bg-ops-600 hover:bg-ops-500 rounded-lg">Save status</button>
      </div>
    </form>
  </div>
  {% endfor %}
</div>
{% else %}
<div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-10 text-center text-gray-400">No companies in this view.</div>
{% endif %}

<details class="mt-10 rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
  <summary class="text-sm font-bold cursor-pointer">Partner agreement text (v{{ agreement_version }})</summary>
  <form method="post" action="{{ url_for('partners.admin_agreement', status=show) }}" class="mt-4 space-y-3">
    <div class="flex items-center gap-3">
      <label class="text-xs font-semibold text-gray-400">Version</label>
      <input name="agreement_version" value="{{ agreement_version }}" class="form-input w-24 text-sm">
      <span class="text-xs text-gray-500">Bump the version to require everyone to re-sign.</span>
    </div>
    <textarea name="agreement_text" rows="14" class="form-textarea w-full text-sm font-mono">{{ agreement_text }}</textarea>
    <button class="px-4 py-2 text-sm font-semibold text-white bg-ops-600 hover:bg-ops-500 rounded-lg">Save agreement</button>
  </form>
</details>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/_base.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}{% block portal_title %}Portal{% endblock %} · OpsLab Systems{% endblock %}

{% block head_extra %}
<style>
  .pcard { background:#0b1224; border:1px solid #1b2a4a; border-radius:16px; }
  .pcard-h { background:#0b1224; border:1px solid #1b2a4a; border-radius:16px; transition:border-color .2s, transform .2s; }
  .pcard-h:hover { border-color:rgba(33,150,243,.45); transform:translateY(-2px); }
  .pnav-link { display:flex; align-items:center; gap:.7rem; padding:.6rem .8rem; border-radius:.7rem; font-size:.9rem; color:#9fb0c9; transition:.15s; white-space:nowrap; }
  .pnav-link:hover { background:rgba(255,255,255,.05); color:#fff; }
  .pnav-link.active { background:rgba(33,150,243,.12); color:#71b7ff; border:1px solid rgba(33,150,243,.3); }
  .pbadge { font-size:11px; padding:2px 9px; border-radius:999px; font-weight:700; letter-spacing:.4px; }
</style>
{% endblock %}

{% block content %}
{% set _u = url_for %}
{% set active = active_page|default('') %}

<!-- Announcement banners -->
{% if portal_announcements %}
  <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 w-full pt-4 space-y-2">
    {% for a in portal_announcements %}
    <div class="flex items-start gap-3 p-4 rounded-xl border
      {% if a.level=='success' %}bg-green-500/10 border-green-500/30 text-green-200
      {% elif a.level=='warning' %}bg-yellow-500/10 border-yellow-500/30 text-yellow-200
      {% elif a.level=='danger' %}bg-red-500/10 border-red-500/30 text-red-200
      {% else %}bg-ops-500/10 border-ops-500/30 text-ops-200{% endif %}">
      <div><div class="font-semibold text-sm">{{ a.title }}</div>{% if a.body %}<div class="text-sm opacity-90 mt-0.5">{{ a.body }}</div>{% endif %}</div>
    </div>
    {% endfor %}
  </div>
{% endif %}

<div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8 w-full">
  <div class="lg:grid lg:grid-cols-12 lg:gap-8">

    <!-- Sidebar (desktop) -->
    <aside class="hidden lg:block lg:col-span-3 xl:col-span-2">
      <div class="pcard p-3 sticky top-20 space-y-1">
        <a href="{{ _u('portal.dashboard') }}"     class="pnav-link {{ 'active' if active=='dashboard' }}"><span>Dashboard</span></a>
        <a href="{{ _u('portal.projects') }}"       class="pnav-link {{ 'active' if active=='projects' }}"><span>Projects</span></a>
        <a href="{{ _u('portal.appointments') }}"   class="pnav-link {{ 'active' if active=='appointments' }}"><span>Appointments</span></a>
        <a href="{{ _u('portal.invoices') }}"        class="pnav-link {{ 'active' if active=='invoices' }}"><span>Invoices</span></a>
        <a href="{{ _u('tickets.index') }}"          class="pnav-link"><span>Support tickets</span></a>
        <a href="{{ _u('portal.notifications') }}"   class="pnav-link {{ 'active' if active=='notifications' }}">
          <span>Notifications</span>
          {% if portal_unread %}<span class="ml-auto pbadge bg-ops-500/20 text-ops-300">{{ portal_unread }}</span>{% endif %}
        </a>
      </div>
    </aside>

    <!-- Main -->
    <div class="lg:col-span-9 xl:col-span-10">
      <!-- Mobile horizontal nav -->
      <div class="lg:hidden -mx-1 mb-5 overflow-x-auto">
        <div class="flex gap-2 px-1 pb-1">
          <a href="{{ _u('portal.dashboard') }}"   class="pnav-link {{ 'active' if active=='dashboard' }}">Dashboard</a>
          <a href="{{ _u('portal.projects') }}"     class="pnav-link {{ 'active' if active=='projects' }}">Projects</a>
          <a href="{{ _u('portal.appointments') }}" class="pnav-link {{ 'active' if active=='appointments' }}">Appointments</a>
          <a href="{{ _u('portal.invoices') }}"      class="pnav-link {{ 'active' if active=='invoices' }}">Invoices</a>
          <a href="{{ _u('portal.notifications') }}" class="pnav-link {{ 'active' if active=='notifications' }}">Alerts{% if portal_unread %} ({{ portal_unread }}){% endif %}</a>
        </div>
      </div>

      <div class="flex items-center justify-between gap-3 mb-6">
        <h1 class="text-2xl sm:text-3xl font-extrabold tracking-tight">{% block portal_heading %}{{ self.portal_title() }}{% endblock %}</h1>
        <div>{% block portal_actions %}{% endblock %}</div>
      </div>

      {% block portal_content %}{% endblock %}
    </div>
  </div>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/dashboard.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'dashboard' %}
{% block portal_title %}Dashboard{% endblock %}
{% block portal_heading %}Welcome back, {{ current_user.username }}{% endblock %}
{% block portal_actions %}
  <a href="{{ url_for('portal.project_new') }}" class="inline-flex items-center gap-2 px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg shadow-glow-sm hover:shadow-glow transition">
    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>New project
  </a>
{% endblock %}

{% block portal_content %}
<!-- Top stat cards -->
<div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
  <div class="pcard p-5">
    <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500">Active services</div>
    <div class="text-3xl font-extrabold mt-1">{{ svc_counts.active }}</div>
    <div class="text-xs text-gray-500 mt-1">{{ svc_counts.pending }} pending · {{ svc_counts.suspended }} suspended</div>
  </div>
  <div class="pcard p-5">
    <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500">Open projects</div>
    <div class="text-3xl font-extrabold mt-1">{{ proj_counts.active }}</div>
    <div class="text-xs text-gray-500 mt-1">{{ proj_counts.completed }} completed</div>
  </div>
  <div class="pcard p-5">
    <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500">Outstanding</div>
    <div class="text-3xl font-extrabold mt-1 {% if outstanding_total %}text-yellow-300{% endif %}">
      £{{ '%.2f'|format(outstanding_total / 100) }}
    </div>
    <div class="text-xs text-gray-500 mt-1">{{ outstanding|length }} invoice{{ '' if outstanding|length==1 else 's' }} due</div>
  </div>
  <div class="pcard p-5">
    <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500">Open tickets</div>
    <div class="text-3xl font-extrabold mt-1">{{ open_tickets }}</div>
    <div class="text-xs text-gray-500 mt-1"><a href="{{ url_for('tickets.index') }}" class="text-ops-400 hover:text-ops-300">View all →</a></div>
  </div>
</div>

<div class="grid lg:grid-cols-3 gap-6">
  <!-- Recent projects -->
  <div class="lg:col-span-2 pcard p-6">
    <div class="flex items-center justify-between mb-4">
      <h2 class="font-bold text-lg">Recent projects</h2>
      <a href="{{ url_for('portal.projects') }}" class="text-sm text-ops-400 hover:text-ops-300">All projects →</a>
    </div>
    {% if recent_projects %}
      <div class="space-y-3">
        {% for p in recent_projects %}
        <a href="{{ url_for('portal.project_detail', pid=p.id) }}" class="block p-4 rounded-xl bg-ink-900/50 border border-ink-600 hover:border-ops-500/50 transition">
          <div class="flex items-center justify-between gap-3">
            <div class="font-semibold truncate">{{ p.title }}</div>
            <span class="pbadge shrink-0" style="background:{{ p.stage_meta.color }}1f;color:{{ p.stage_meta.color }};">{{ p.stage_meta.label }}</span>
          </div>
          <div class="mt-3 h-2 rounded-full bg-ink-600/60 overflow-hidden">
            <div class="h-full rounded-full" style="width:{{ p.effective_percent }}%;background:{{ p.stage_meta.color }};"></div>
          </div>
          <div class="text-xs text-gray-500 mt-1.5">{{ p.effective_percent }}% · updated {{ p.updated_at|dt }}</div>
        </a>
        {% endfor %}
      </div>
    {% else %}
      <div class="text-sm text-gray-500 py-6 text-center">No projects yet. <a href="{{ url_for('portal.project_new') }}" class="text-ops-400">Start one →</a></div>
    {% endif %}
  </div>

  <!-- Side column -->
  <div class="space-y-6">
    <div class="pcard p-6">
      <h2 class="font-bold text-lg mb-4">Upcoming appointments</h2>
      {% if upcoming_appts %}
        <div class="space-y-3">
          {% for a in upcoming_appts %}
          <div class="flex items-start gap-3">
            <div class="w-10 h-10 rounded-lg bg-ops-500/10 border border-ops-500/30 flex items-center justify-center text-ops-300 shrink-0">
              <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"/></svg>
            </div>
            <div class="min-w-0">
              <div class="text-sm font-semibold truncate">{{ a.subject }}</div>
              <div class="text-xs text-gray-500">{{ a.starts_at|dt }}</div>
            </div>
          </div>
          {% endfor %}
        </div>
      {% else %}
        <div class="text-sm text-gray-500">Nothing booked.</div>
      {% endif %}
      <a href="{{ url_for('portal.appointment_book') }}" class="mt-4 inline-flex items-center gap-1.5 text-sm font-semibold text-ops-400 hover:text-ops-300">Book a time →</a>
    </div>

    <div class="pcard p-6">
      <h2 class="font-bold text-lg mb-4">Recent payments</h2>
      {% if recent_payments %}
        <div class="space-y-2">
          {% for pmt in recent_payments %}
          <div class="flex items-center justify-between text-sm">
            <span class="text-gray-400">{{ pmt.created_at|dtdate }}</span>
            <span class="font-semibold text-green-300">{{ pmt.amount_display }}</span>
          </div>
          {% endfor %}
        </div>
      {% else %}
        <div class="text-sm text-gray-500">No payments yet.</div>
      {% endif %}
    </div>
  </div>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/projects.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'projects' %}
{% block portal_title %}Projects{% endblock %}
{% block portal_actions %}
  <a href="{{ url_for('portal.project_new') }}" class="inline-flex items-center gap-2 px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg shadow-glow-sm hover:shadow-glow transition">New project</a>
{% endblock %}
{% block portal_content %}
{% if projects %}
<div class="grid sm:grid-cols-2 gap-4">
  {% for p in projects %}
  <a href="{{ url_for('portal.project_detail', pid=p.id) }}" class="pcard-h p-6 block">
    <div class="flex items-start justify-between gap-3">
      <h3 class="font-bold text-lg truncate">{{ p.title }}</h3>
      <span class="pbadge shrink-0" style="background:{{ p.stage_meta.color }}1f;color:{{ p.stage_meta.color }};">{{ p.stage_meta.label }}</span>
    </div>
    {% if p.summary %}<p class="text-sm text-gray-400 mt-2 line-clamp-2">{{ p.summary }}</p>{% endif %}
    <div class="mt-4 h-2.5 rounded-full bg-ink-600/60 overflow-hidden">
      <div class="h-full rounded-full transition-all" style="width:{{ p.effective_percent }}%;background:{{ p.stage_meta.color }};"></div>
    </div>
    <div class="flex items-center justify-between text-xs text-gray-500 mt-2">
      <span>{{ p.effective_percent }}% complete</span>
      <span>Updated {{ p.updated_at|dtdate }}</span>
    </div>
  </a>
  {% endfor %}
</div>
{% else %}
<div class="pcard p-12 text-center">
  <p class="text-gray-400">No projects yet.</p>
  <a href="{{ url_for('portal.project_new') }}" class="mt-4 inline-flex px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg">Start your first project</a>
</div>
{% endif %}
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/project_new.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'projects' %}
{% block portal_title %}New project{% endblock %}
{% block portal_content %}
<div class="pcard p-6 sm:p-8 max-w-2xl">
  <form method="post" class="space-y-5">
    <div>
      <label class="block text-sm font-semibold mb-1.5">Project title <span class="text-red-400">*</span></label>
      <input name="title" required class="form-input w-full" placeholder="e.g. New booking website">
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Which area?</label>
      <select name="company_id" class="form-select w-full">
        <option value="">— General —</option>
        {% for c in companies %}<option value="{{ c.id }}">{{ c.name }}</option>{% endfor %}
      </select>
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Short summary</label>
      <input name="summary" class="form-input w-full" placeholder="One line about the goal">
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Requirements / details</label>
      <textarea name="requirements" rows="6" class="form-textarea w-full" placeholder="Anything that helps scope the work…"></textarea>
    </div>
    <div class="flex gap-3">
      <button class="px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg shadow-glow-sm hover:shadow-glow transition">Submit project</button>
      <a href="{{ url_for('portal.projects') }}" class="px-5 py-2.5 text-sm font-semibold text-gray-300 bg-white/5 border border-ink-600 rounded-lg hover:bg-white/10 transition">Cancel</a>
    </div>
  </form>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/project_detail.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'projects' %}
{% block portal_title %}{{ p.title }}{% endblock %}
{% block portal_heading %}<a href="{{ url_for('portal.projects') }}" class="text-gray-500 hover:text-gray-300">Projects</a> <span class="text-gray-600">/</span> {{ p.title }}{% endblock %}

{% block portal_content %}
<div class="grid lg:grid-cols-3 gap-6">

  <!-- Left: progress + timeline -->
  <div class="lg:col-span-2 space-y-6">

    <!-- Progress -->
    <div class="pcard p-6">
      <div class="flex items-center justify-between gap-3 mb-4">
        <span class="pbadge" style="background:{{ p.stage_meta.color }}1f;color:{{ p.stage_meta.color }};">{{ p.stage_meta.label }}</span>
        <span class="text-2xl font-extrabold">{{ p.effective_percent }}%</span>
      </div>
      <div class="h-3 rounded-full bg-ink-600/60 overflow-hidden">
        <div class="h-full rounded-full transition-all" style="width:{{ p.effective_percent }}%;background:{{ p.stage_meta.color }};"></div>
      </div>

      <!-- Stage rail -->
      <div class="mt-6 flex flex-wrap gap-1.5">
        {% for s in stages %}
          {% set meta = stage_meta[s] %}
          {% set done = stage_meta[p.stage].pct >= meta.pct %}
          <span class="text-[10px] px-2 py-1 rounded-full border
            {% if s == p.stage %}font-bold{% endif %}"
            style="border-color:{{ meta.color }}{{ '' if done else '33' }};
                   color:{{ meta.color if done else '#64748b' }};
                   background:{{ meta.color ~ '1f' if s == p.stage else 'transparent' }};">
            {{ meta.label }}
          </span>
        {% endfor %}
      </div>

      {% if p.summary %}<p class="text-sm text-gray-400 mt-5">{{ p.summary }}</p>{% endif %}
      {% if p.requirements %}
        <div class="mt-4 p-4 rounded-xl bg-ink-900/50 border border-ink-600">
          <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500 mb-1">Requirements</div>
          <p class="text-sm text-gray-300 whitespace-pre-line">{{ p.requirements }}</p>
        </div>
      {% endif %}
    </div>

    <!-- Timeline -->
    <div class="pcard p-6">
      <h2 class="font-bold text-lg mb-5">Timeline</h2>
      <ol class="relative border-l border-ink-600 ml-2">
        {% for ev in events %}
        <li class="mb-6 ml-5">
          <span class="absolute -left-1.5 w-3 h-3 rounded-full
            {% if ev.kind=='stage_change' %}bg-ops-400{% elif ev.kind=='deploy' %}bg-green-400{% elif ev.kind=='client_update' %}bg-purple-400{% elif ev.kind=='milestone' %}bg-yellow-400{% else %}bg-gray-500{% endif %}"></span>
          <div class="flex items-center gap-2 text-xs text-gray-500">
            <span class="font-semibold text-gray-300">{{ ev.actor.username if ev.actor else 'System' }}</span>
            <span>·</span><span>{{ ev.created_at|dt }}</span>
          </div>
          <div class="text-sm mt-0.5">{{ ev.text }}</div>
        </li>
        {% else %}
        <li class="ml-5 text-sm text-gray-500">No activity yet.</li>
        {% endfor %}
      </ol>
    </div>

    <!-- Add comment -->
    <div class="pcard p-6">
      <form method="post" action="{{ url_for('portal.project_comment', pid=p.id) }}" class="flex gap-3">
        <input name="text" required class="form-input flex-1" placeholder="Add a comment or update…">
        <button class="px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg shrink-0">Post</button>
      </form>
    </div>
  </div>

  <!-- Right: meta + staff controls -->
  <div class="space-y-6">
    <div class="pcard p-6">
      <h2 class="font-bold text-lg mb-4">Details</h2>
      <dl class="space-y-3 text-sm">
        <div class="flex justify-between gap-3"><dt class="text-gray-500">Assigned to</dt><dd class="text-right">{{ p.assigned_staff.username if p.assigned_staff else '—' }}</dd></div>
        <div class="flex justify-between gap-3"><dt class="text-gray-500">Est. completion</dt><dd class="text-right">{{ p.estimated_completion|dtdate if p.estimated_completion else '—' }}</dd></div>
        <div class="flex justify-between gap-3"><dt class="text-gray-500">Created</dt><dd class="text-right">{{ p.created_at|dtdate }}</dd></div>
      </dl>
    </div>

    {% if milestones %}
    <div class="pcard p-6">
      <h2 class="font-bold text-lg mb-4">Milestones</h2>
      <ul class="space-y-2.5">
        {% for m in milestones %}
        <li class="flex items-start gap-2.5 text-sm">
          <span class="w-5 h-5 rounded-md flex items-center justify-center shrink-0 mt-0.5
            {% if m.is_done %}bg-green-500/15 border border-green-500/40 text-green-300{% else %}bg-ink-900 border border-ink-600 text-gray-600{% endif %}">
            {% if m.is_done %}<svg class="w-3 h-3" fill="none" stroke="currentColor" stroke-width="3" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg>{% endif %}
          </span>
          <span class="{{ 'text-gray-400 line-through' if m.is_done else 'text-gray-200' }}">{{ m.title }}</span>
        </li>
        {% endfor %}
      </ul>
    </div>
    {% endif %}

    {% if portal_is_staff and can(current_user, 'project.manage') %}
    <div class="pcard p-6 border-ops-500/30">
      <h2 class="font-bold text-lg mb-4 text-ops-300">Staff controls</h2>
      <form method="post" action="{{ url_for('portal.project_update', pid=p.id) }}" class="space-y-3">
        <div>
          <label class="block text-xs font-semibold text-gray-400 mb-1">Stage</label>
          <select name="stage" class="form-select w-full text-sm">
            {% for s in stages %}<option value="{{ s }}" {{ 'selected' if s==p.stage }}>{{ stage_meta[s].label }}</option>{% endfor %}
          </select>
        </div>
        <div>
          <label class="block text-xs font-semibold text-gray-400 mb-1">Percent override</label>
          <input name="percent_complete" type="number" min="0" max="100" value="{{ p.percent_complete }}" class="form-input w-full text-sm">
        </div>
        <div>
          <label class="block text-xs font-semibold text-gray-400 mb-1">Assign staff</label>
          <select name="assigned_staff_id" class="form-select w-full text-sm">
            <option value="">— Unassigned —</option>
            {% for s in staff %}<option value="{{ s.id }}" {{ 'selected' if p.assigned_staff_id==s.id }}>{{ s.username }}</option>{% endfor %}
          </select>
        </div>
        <div>
          <label class="block text-xs font-semibold text-gray-400 mb-1">Est. completion</label>
          <input name="estimated_completion" type="date" class="form-input w-full text-sm"
                 value="{{ p.estimated_completion.strftime('%Y-%m-%d') if p.estimated_completion else '' }}">
        </div>
        <div>
          <label class="block text-xs font-semibold text-gray-400 mb-1">Update note (optional)</label>
          <input name="note" class="form-input w-full text-sm" placeholder="Visible to the client">
        </div>
        <button class="w-full px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg">Save update</button>
      </form>
    </div>
    {% endif %}
  </div>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/appointments.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'appointments' %}
{% block portal_title %}Appointments{% endblock %}
{% block portal_actions %}
  <a href="{{ url_for('portal.appointment_book') }}" class="inline-flex items-center gap-2 px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg shadow-glow-sm hover:shadow-glow transition">Book a time</a>
{% endblock %}
{% block portal_content %}
<div class="pcard p-6 mb-6">
  <h2 class="font-bold text-lg mb-4">Upcoming</h2>
  {% if upcoming %}
  <div class="space-y-3">
    {% for a in upcoming %}
    <div class="flex items-center gap-4 p-4 rounded-xl bg-ink-900/50 border border-ink-600">
      <div class="text-center shrink-0 w-14">
        <div class="text-xs text-gray-500 uppercase">{{ a.starts_at|dtdate }}</div>
      </div>
      <div class="flex-1 min-w-0">
        <div class="font-semibold truncate">{{ a.subject }}</div>
        <div class="text-xs text-gray-500">{{ a.starts_at|dt }} (Europe/London)</div>
      </div>
      <span class="pbadge" style="background:{{ a.status_meta.color }}1f;color:{{ a.status_meta.color }};">{{ a.status_meta.label }}</span>
      <form method="post" action="{{ url_for('portal.appointment_cancel', aid=a.id) }}">
        <button class="text-xs text-gray-400 hover:text-red-300 px-2 py-1">Cancel</button>
      </form>
    </div>
    {% endfor %}
  </div>
  {% else %}
  <div class="text-sm text-gray-500 py-4">Nothing booked. <a href="{{ url_for('portal.appointment_book') }}" class="text-ops-400">Book a time →</a></div>
  {% endif %}
</div>

{% if past %}
<div class="pcard p-6">
  <h2 class="font-bold text-lg mb-4">Past</h2>
  <div class="space-y-2">
    {% for a in past %}
    <div class="flex items-center justify-between gap-3 text-sm py-2 border-b border-ink-600/40 last:border-0">
      <span class="truncate">{{ a.subject }}</span>
      <span class="text-gray-500 shrink-0">{{ a.starts_at|dt }}</span>
    </div>
    {% endfor %}
  </div>
</div>
{% endif %}
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/appointment_book.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'appointments' %}
{% block portal_title %}Book a time{% endblock %}
{% block portal_content %}
<div class="pcard p-6 sm:p-8 max-w-2xl">
  <form method="get" class="flex flex-wrap items-end gap-3 mb-6 pb-6 border-b border-ink-600/60">
    <div>
      <label class="block text-sm font-semibold mb-1.5">Pick a date</label>
      <input type="date" name="day" value="{{ day_str }}" class="form-input" onchange="this.form.submit()">
    </div>
    <span class="text-xs text-gray-500 pb-2.5">Times shown in Europe/London (24h)</span>
  </form>

  <form method="post" id="bookForm">
    <input type="hidden" name="day" value="{{ day_str }}">
    <input type="hidden" name="slot" id="slotField">
    <input type="hidden" name="duration" value="30">

    <label class="block text-sm font-semibold mb-1.5">Subject <span class="text-red-400">*</span></label>
    <input name="subject" required class="form-input w-full mb-5" placeholder="What's it about?">

    <label class="block text-sm font-semibold mb-2">Available slots — {{ day.strftime('%A %d %b %Y') }}</label>
    {% if slots %}
      <div class="grid grid-cols-3 sm:grid-cols-4 gap-2 mb-5">
        {% for s in slots %}
        <button type="button" data-slot="{{ s }}"
          class="slot px-3 py-2.5 rounded-lg text-sm font-semibold bg-ink-900/60 border border-ink-600 hover:border-ops-500/60 transition">
          {{ s }}
        </button>
        {% endfor %}
      </div>
      <label class="block text-sm font-semibold mb-1.5">Notes (optional)</label>
      <textarea name="notes" rows="3" class="form-textarea w-full mb-5" placeholder="Anything useful beforehand…"></textarea>
      <button id="submitBtn" disabled class="px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg disabled:opacity-40 disabled:cursor-not-allowed transition">
        Request selected time
      </button>
    {% else %}
      <div class="p-4 rounded-xl bg-ink-900/50 border border-ink-600 text-sm text-gray-400">
        No free slots that day (closed, fully booked, or a blackout date). Try another date.
      </div>
    {% endif %}
  </form>
</div>

<script>
  (function () {
    var chosen = null;
    document.querySelectorAll('.slot').forEach(function (b) {
      b.addEventListener('click', function () {
        document.querySelectorAll('.slot').forEach(function (x) {
          x.classList.remove('border-ops-500','bg-ops-500/15','text-ops-300');
        });
        b.classList.add('border-ops-500','bg-ops-500/15','text-ops-300');
        chosen = b.dataset.slot;
        document.getElementById('slotField').value = chosen;
        document.getElementById('submitBtn').disabled = false;
      });
    });
  })();
</script>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/invoices.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'invoices' %}
{% block portal_title %}Invoices{% endblock %}
{% block portal_content %}
{% if invoices %}
<div class="pcard overflow-hidden">
  <div class="overflow-x-auto">
    <table class="w-full text-sm">
      <thead class="bg-ink-900/60 text-gray-400 text-[11px] uppercase tracking-widest">
        <tr>
          <th class="text-left px-5 py-3">Invoice</th>
          <th class="text-left px-5 py-3 hidden sm:table-cell">Issued</th>
          <th class="text-left px-5 py-3">Status</th>
          <th class="text-right px-5 py-3">Total</th>
          <th class="px-5 py-3"></th>
        </tr>
      </thead>
      <tbody>
        {% for inv in invoices %}
        <tr class="border-t border-ink-600/40 hover:bg-white/[.02]">
          <td class="px-5 py-3 font-mono text-ops-300">{{ inv.number }}</td>
          <td class="px-5 py-3 text-gray-400 hidden sm:table-cell">{{ inv.issued_at|dtdate if inv.issued_at else '—' }}</td>
          <td class="px-5 py-3"><span class="pbadge" style="background:{{ inv.status_meta.color }}1f;color:{{ inv.status_meta.color }};">{{ inv.status_meta.label }}</span></td>
          <td class="px-5 py-3 text-right font-semibold">{{ inv.total_display }}</td>
          <td class="px-5 py-3 text-right"><a href="{{ url_for('portal.invoice_detail', iid=inv.id) }}" class="text-ops-400 hover:text-ops-300 font-semibold">View →</a></td>
        </tr>
        {% endfor %}
      </tbody>
    </table>
  </div>
</div>
{% else %}
<div class="pcard p-12 text-center text-gray-400">No invoices yet.</div>
{% endif %}
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/invoice_detail.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'invoices' %}
{% block portal_title %}{{ inv.number }}{% endblock %}
{% block portal_heading %}<a href="{{ url_for('portal.invoices') }}" class="text-gray-500 hover:text-gray-300">Invoices</a> <span class="text-gray-600">/</span> {{ inv.number }}{% endblock %}
{% block portal_content %}
{% if request.args.get('paid') %}
<div class="mb-5 p-4 rounded-xl bg-green-500/10 border border-green-500/30 text-green-200 text-sm">Payment received — thank you!</div>
{% endif %}

<div class="pcard p-6 sm:p-8 max-w-3xl">
  <div class="flex items-start justify-between gap-4 mb-6">
    <div>
      <div class="font-mono text-ops-300">{{ inv.number }}</div>
      <div class="text-xs text-gray-500 mt-1">Issued {{ inv.issued_at|dtdate if inv.issued_at else '—' }} · Due {{ inv.due_at|dtdate if inv.due_at else '—' }}</div>
    </div>
    <span class="pbadge" style="background:{{ inv.status_meta.color }}1f;color:{{ inv.status_meta.color }};">{{ inv.status_meta.label }}</span>
  </div>

  <div class="overflow-x-auto">
    <table class="w-full text-sm">
      <thead class="text-gray-500 text-[11px] uppercase tracking-widest border-b border-ink-600">
        <tr><th class="text-left py-2">Description</th><th class="text-right py-2">Qty</th><th class="text-right py-2">Unit</th><th class="text-right py-2">Amount</th></tr>
      </thead>
      <tbody>
        {% for li in inv.line_items %}
        <tr class="border-b border-ink-600/40">
          <td class="py-3">{{ li.description }}</td>
          <td class="py-3 text-right text-gray-400">{{ li.quantity }}</td>
          <td class="py-3 text-right text-gray-400">£{{ '%.2f'|format(li.unit_cents/100) }}</td>
          <td class="py-3 text-right font-semibold">£{{ '%.2f'|format(li.amount_cents/100) }}</td>
        </tr>
        {% endfor %}
      </tbody>
      <tfoot>
        <tr><td colspan="3" class="py-3 text-right font-bold">Total</td><td class="py-3 text-right text-lg font-extrabold">{{ inv.total_display }}</td></tr>
      </tfoot>
    </table>
  </div>

  {% if inv.notes %}<p class="text-sm text-gray-400 mt-4">{{ inv.notes }}</p>{% endif %}

  <div class="mt-6 flex flex-wrap gap-3">
    {% if inv.is_payable %}
      {% if stripe_on %}
      <form method="post" action="{{ url_for('portal.invoice_pay', iid=inv.id) }}">
        <button class="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">
          Pay {{ inv.total_display }} online
        </button>
      </form>
      {% else %}
      <div class="text-sm text-yellow-300/90 p-3 rounded-lg bg-yellow-500/10 border border-yellow-500/30">
        Online payment isn't switched on yet (Stripe keys not set). The invoice is still viewable.
      </div>
      {% endif %}
    {% elif inv.status == 'paid' %}
      <div class="text-sm text-green-300 flex items-center gap-2">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
        Paid {{ inv.paid_at|dtdate }}
      </div>
    {% endif %}
  </div>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/portal/notifications.html" << '__OPSLAB_EOF__'
{% extends "portal/_base.html" %}
{% set active_page = 'notifications' %}
{% block portal_title %}Notifications{% endblock %}
{% block portal_actions %}
  {% if portal_unread %}
  <form method="post" action="{{ url_for('portal.notifications_read_all') }}">
    <button class="px-4 py-2 text-sm font-semibold text-gray-300 bg-white/5 border border-ink-600 rounded-lg hover:bg-white/10 transition">Mark all read</button>
  </form>
  {% endif %}
{% endblock %}
{% block portal_content %}
{% if items %}
<div class="pcard divide-y divide-ink-600/40">
  {% for n in items %}
  <a href="{{ n.url or '#' }}" class="flex items-start gap-3 p-4 hover:bg-white/[.02] transition {{ '' if n.is_read else 'bg-ops-500/[.04]' }}">
    <span class="w-2 h-2 rounded-full mt-2 shrink-0 {{ 'bg-transparent' if n.is_read else 'bg-ops-400' }}"></span>
    <div class="min-w-0 flex-1">
      <div class="font-semibold text-sm {{ 'text-gray-400' if n.is_read else 'text-white' }}">{{ n.title }}</div>
      {% if n.body %}<div class="text-sm text-gray-500 mt-0.5">{{ n.body }}</div>{% endif %}
    </div>
    <span class="text-xs text-gray-600 shrink-0">{{ n.created_at|dt }}</span>
  </a>
  {% endfor %}
</div>
{% else %}
<div class="pcard p-12 text-center text-gray-400">You're all caught up.</div>
{% endif %}
{% endblock %}
__OPSLAB_EOF__
write "app/templates/admin/jobs/list.html" << '__OPSLAB_EOF__'
{% extends "admin/_layout.html" %}
{% block admin_title %}Quick Jobs{% endblock %}
{% block admin_content %}
<div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
  <div>
    <div class="text-xs font-bold uppercase tracking-widest text-ops-400 mb-1">Work</div>
    <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Quick Jobs</h1>
    <p class="text-sm text-gray-400 mt-1">{{ jobs|length }} job{{ '' if jobs|length==1 else 's' }} · create one, then share the link.</p>
  </div>
  <a href="{{ url_for('quickjobs.admin_new') }}" class="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow hover:scale-[1.02] transition self-start sm:self-auto">
    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>
    New job
  </a>
</div>

<div class="flex flex-wrap gap-2 mb-5 text-sm">
  <a href="{{ url_for('quickjobs.admin_list') }}" class="px-3 py-1.5 rounded-lg border {{ 'border-ops-500 text-ops-300 bg-ops-500/10' if not status else 'border-ink-600 text-gray-400 hover:text-white' }}">All</a>
  {% for key, meta in status_meta.items() %}
  <a href="{{ url_for('quickjobs.admin_list', status=key) }}" class="px-3 py-1.5 rounded-lg border {{ 'border-ops-500 text-ops-300 bg-ops-500/10' if status==key else 'border-ink-600 text-gray-400 hover:text-white' }}">{{ meta.label }}</a>
  {% endfor %}
</div>

{% if jobs %}
<div class="rounded-2xl border border-ink-600 overflow-hidden bg-ink-800/40">
  <div class="overflow-x-auto">
    <table class="w-full text-sm">
      <thead class="bg-ink-900/60 text-gray-400 text-[11px] uppercase tracking-widest">
        <tr>
          <th class="text-left px-5 py-3">Job</th>
          <th class="text-left px-5 py-3 hidden sm:table-cell">Client</th>
          <th class="text-left px-5 py-3">Status</th>
          <th class="text-left px-5 py-3 hidden md:table-cell">Scheduled</th>
          <th class="px-5 py-3"></th>
        </tr>
      </thead>
      <tbody>
        {% for j in jobs %}
        <tr class="border-t border-ink-600/40 hover:bg-white/[.02]">
          <td class="px-5 py-3 font-semibold">{{ j.title }}</td>
          <td class="px-5 py-3 text-gray-400 hidden sm:table-cell">{{ j.client_name or '—' }}</td>
          <td class="px-5 py-3"><span class="pill" style="background:{{ j.status_meta.color }}1f;color:{{ j.status_meta.color }};border:1px solid {{ j.status_meta.color }}55;">{{ j.status_meta.label }}</span></td>
          <td class="px-5 py-3 text-gray-400 hidden md:table-cell">{{ j.scheduled_day.strftime('%d %b %Y') if j.scheduled_day else '—' }}{{ ' · ' ~ j.scheduled_time if j.scheduled_time else '' }}</td>
          <td class="px-5 py-3 text-right"><a href="{{ url_for('quickjobs.admin_detail', job_id=j.id) }}" class="text-ops-400 hover:text-ops-300 font-semibold">Open →</a></td>
        </tr>
        {% endfor %}
      </tbody>
    </table>
  </div>
</div>
{% else %}
<div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-12 text-center">
  <p class="text-gray-400">No jobs yet.</p>
  <a href="{{ url_for('quickjobs.admin_new') }}" class="mt-4 inline-flex px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl">Create your first job</a>
</div>
{% endif %}
{% endblock %}
__OPSLAB_EOF__
write "app/templates/admin/jobs/form.html" << '__OPSLAB_EOF__'
{% extends "admin/_layout.html" %}
{% block admin_title %}New Job{% endblock %}
{% block admin_content %}
<div class="mb-8">
  <div class="text-xs font-bold uppercase tracking-widest text-ops-400 mb-1">Work</div>
  <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">New quick job</h1>
  <p class="text-sm text-gray-400 mt-1">Fill in the details. You'll get a shareable link on the next screen.</p>
</div>

<form method="post" class="max-w-2xl space-y-5">
  <div>
    <label class="block text-sm font-semibold mb-1.5">Job title <span class="text-red-400">*</span></label>
    <input name="title" required class="form-input w-full" placeholder="e.g. Mobile tyre fitting — 2 fronts">
  </div>
  <div>
    <label class="block text-sm font-semibold mb-1.5">Details</label>
    <textarea name="details" rows="5" class="form-textarea w-full" placeholder="What the job involves, what's included, anything the client should know…"></textarea>
  </div>
  <div class="grid sm:grid-cols-2 gap-4">
    <div>
      <label class="block text-sm font-semibold mb-1.5">Location</label>
      <input name="location" class="form-input w-full" placeholder="Address / area">
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Contact phone</label>
      <input name="contact_phone" class="form-input w-full" placeholder="Optional">
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Price (£)</label>
      <input name="price" inputmode="decimal" class="form-input w-full" placeholder="e.g. 80.00 (optional)">
    </div>
    <div>
      <label class="block text-sm font-semibold mb-1.5">Client name</label>
      <input name="client_name" class="form-input w-full" placeholder="Optional">
    </div>
    <div class="sm:col-span-2">
      <label class="block text-sm font-semibold mb-1.5">Client email</label>
      <input name="client_email" type="email" class="form-input w-full" placeholder="Optional — for your records">
    </div>
    <div class="sm:col-span-2">
      <label class="block text-sm font-semibold mb-1.5">Client phone</label>
      <input name="client_phone" class="form-input w-full" placeholder="Optional">
    </div>
  </div>

  <div class="rounded-xl border border-ink-600 bg-ink-900/40 p-4 space-y-4">
    <label class="flex items-center gap-3 cursor-pointer">
      <input type="checkbox" name="allow_client_scheduling" checked class="w-4 h-4 rounded accent-ops-500">
      <span class="text-sm font-medium">Let the client pick the day from the share link</span>
    </label>
    <label class="flex items-center gap-3 cursor-pointer">
      <input type="checkbox" name="allow_client_edits" checked class="w-4 h-4 rounded accent-ops-500">
      <span class="text-sm font-medium">Let the client edit items, details &amp; cancel from the link</span>
    </label>
    <div class="grid sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-xs font-semibold text-gray-400 mb-1">…or set the day now</label>
        <input name="scheduled_day" type="date" class="form-input w-full">
      </div>
      <div>
        <label class="block text-xs font-semibold text-gray-400 mb-1">Time (optional, 24h)</label>
        <input name="scheduled_time" type="time" class="form-input w-full">
      </div>
    </div>
  </div>

  <div class="flex gap-3">
    <button class="px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Create &amp; get link</button>
    <a href="{{ url_for('quickjobs.admin_list') }}" class="px-5 py-2.5 text-sm font-semibold text-gray-300 bg-white/5 border border-ink-600 rounded-xl hover:bg-white/10 transition">Cancel</a>
  </div>
</form>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/admin/jobs/detail.html" << '__OPSLAB_EOF__'
{% extends "admin/_layout.html" %}
{% block admin_title %}{{ job.title }}{% endblock %}
{% block admin_content %}
<div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4 mb-8">
  <div>
    <div class="text-xs font-bold uppercase tracking-widest text-ops-400 mb-1"><a href="{{ url_for('quickjobs.admin_list') }}" class="hover:text-ops-300">Quick Jobs</a></div>
    <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">{{ job.title }}</h1>
    <div class="mt-2"><span class="pill" style="background:{{ job.status_meta.color }}1f;color:{{ job.status_meta.color }};border:1px solid {{ job.status_meta.color }}55;">{{ job.status_meta.label }}</span></div>
  </div>
</div>

<div class="grid lg:grid-cols-3 gap-6">
  <div class="lg:col-span-2 space-y-6">
    <!-- Share link -->
    <div class="rounded-2xl border border-ops-500/30 bg-ops-500/[.06] p-5">
      <div class="text-sm font-bold mb-2 text-ops-200">Share link</div>
      <div class="flex flex-col sm:flex-row gap-2">
        <input id="shareUrl" readonly value="{{ share_url }}" class="form-input w-full font-mono text-sm">
        <div class="flex gap-2">
          <button type="button" onclick="copyShare()" id="copyBtn" class="px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg whitespace-nowrap">Copy</button>
          <a href="{{ share_url }}" target="_blank" class="px-4 py-2 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-lg whitespace-nowrap">Open</a>
        </div>
      </div>
      <p class="text-xs text-gray-400 mt-2">Anyone with this link can view the job{{ ' and choose a day' if job.allow_client_scheduling and job.status=='new' else '' }}. No account needed.</p>
      <form method="post" action="{{ url_for('quickjobs.admin_regen', job_id=job.id) }}" class="mt-2" onsubmit="return confirm('Regenerate the link? The current link will stop working.');">
        <button class="text-xs text-gray-400 hover:text-red-300">↻ Regenerate link</button>
      </form>
    </div>

    <!-- Edit details -->
    <form method="post" action="{{ url_for('quickjobs.admin_edit', job_id=job.id) }}" class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5 space-y-4">
      <div class="text-sm font-bold">Details</div>
      <input name="title" value="{{ job.title }}" class="form-input w-full" placeholder="Title">
      <textarea name="details" rows="4" class="form-textarea w-full" placeholder="Details">{{ job.details or '' }}</textarea>
      <div class="grid sm:grid-cols-2 gap-4">
        <input name="location" value="{{ job.location or '' }}" class="form-input w-full" placeholder="Address / location">
        <input name="contact_phone" value="{{ job.contact_phone or '' }}" class="form-input w-full" placeholder="Our contact phone">
        <input name="price" value="{{ '%.2f'|format(job.price_cents/100) if job.price_cents is not none else '' }}" class="form-input w-full" placeholder="Flat price £ (used if no items)">
        <input name="client_name" value="{{ job.client_name or '' }}" class="form-input w-full" placeholder="Client name">
        <input name="client_email" value="{{ job.client_email or '' }}" class="form-input w-full" placeholder="Client email">
        <input name="client_phone" value="{{ job.client_phone or '' }}" class="form-input w-full" placeholder="Client phone">
      </div>
      <label class="flex items-center gap-3 cursor-pointer">
        <input type="checkbox" name="allow_client_scheduling" {{ 'checked' if job.allow_client_scheduling }} class="w-4 h-4 rounded accent-ops-500">
        <span class="text-sm">Let the client pick the day from the link</span>
      </label>
      <label class="flex items-center gap-3 cursor-pointer">
        <input type="checkbox" name="allow_client_edits" {{ 'checked' if job.allow_client_edits }} class="w-4 h-4 rounded accent-ops-500">
        <span class="text-sm">Let the client edit items, details &amp; cancel from the link</span>
      </label>
      <button class="px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg">Save details</button>
    </form>

    <!-- Line items -->
    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
      <div class="flex items-center justify-between mb-3">
        <div class="text-sm font-bold">Items</div>
        <div class="text-sm">Total <span class="font-extrabold">{{ job.total_display }}</span></div>
      </div>
      {% if job.items %}
      <div class="rounded-xl border border-ink-600 overflow-hidden divide-y divide-ink-600/50 mb-4">
        {% for it in job.items %}
        <div class="flex items-center gap-3 p-3 bg-ink-900/30">
          <div class="flex-1 min-w-0">
            <div class="text-sm text-gray-100 truncate">{{ it.label }}</div>
            <div class="text-xs text-gray-500">{{ it.unit_display }} × {{ it.quantity }}{% if it.source == 'client' %} · <span class="text-ops-300">added by client</span>{% endif %}</div>
          </div>
          <div class="text-sm font-semibold">{{ it.amount_display }}</div>
          <form method="post" action="{{ url_for('quickjobs.admin_item_remove', job_id=job.id, item_id=it.id) }}"><button class="text-gray-500 hover:text-red-400 px-1" title="Remove">✕</button></form>
        </div>
        {% endfor %}
      </div>
      {% else %}
      <p class="text-sm text-gray-400 mb-4">No items. Add some below, or set a flat price in Details.</p>
      {% endif %}
      <form method="post" action="{{ url_for('quickjobs.admin_item_add', job_id=job.id) }}" class="flex flex-col sm:flex-row gap-2 sm:items-end">
        <div class="flex-1"><label class="block text-[11px] text-gray-500 mb-1">Item</label><input name="label" required class="form-input w-full" placeholder="e.g. Front tyre fitting"></div>
        <div class="w-full sm:w-28"><label class="block text-[11px] text-gray-500 mb-1">Unit £</label><input name="unit_price" inputmode="decimal" class="form-input w-full" placeholder="0.00"></div>
        <div class="w-full sm:w-16"><label class="block text-[11px] text-gray-500 mb-1">Qty</label><input name="quantity" value="1" class="form-input w-full"></div>
        <button class="px-4 py-2.5 text-sm font-semibold text-white bg-ops-600 hover:bg-ops-500 rounded-lg whitespace-nowrap">Add</button>
      </form>
      <p class="text-[11px] text-gray-500 mt-2">When items exist, the total is their sum and the flat price is ignored.</p>
    </div>
  </div>

  <!-- Side: schedule + status -->
  <div class="space-y-6">
    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
      <div class="text-sm font-bold mb-3">Schedule</div>
      {% if job.scheduled_day %}
        <div class="mb-3 p-3 rounded-lg bg-green-500/10 border border-green-500/30">
          <div class="text-sm font-semibold text-green-200">{{ job.scheduled_day.strftime('%A %d %b %Y') }}{{ ' · ' ~ job.scheduled_time if job.scheduled_time else '' }}</div>
          <div class="text-xs text-gray-400 mt-0.5">Set by {{ job.scheduled_by or 'admin' }}</div>
        </div>
      {% else %}
        <p class="text-sm text-gray-400 mb-3">No day set yet.</p>
      {% endif %}
      <form method="post" action="{{ url_for('quickjobs.admin_schedule', job_id=job.id) }}" class="space-y-3">
        <div>
          <label class="block text-xs font-semibold text-gray-400 mb-1">Day</label>
          <input name="scheduled_day" type="date" value="{{ job.scheduled_day.strftime('%Y-%m-%d') if job.scheduled_day else '' }}" class="form-input w-full text-sm">
        </div>
        <div>
          <label class="block text-xs font-semibold text-gray-400 mb-1">Time (24h)</label>
          <input name="scheduled_time" type="time" value="{{ job.scheduled_time or '' }}" class="form-input w-full text-sm">
        </div>
        <button class="w-full px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg">Set day</button>
        <p class="text-[11px] text-gray-500">Leave the day blank and save to clear it (reopens client scheduling).</p>
      </form>
    </div>

    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
      <div class="text-sm font-bold mb-3">Payment</div>
      {% if not job.has_price %}
        <p class="text-sm text-gray-400">No price set. Add a price in Details to enable a Pay button on the share link.</p>
      {% elif job.is_paid %}
        <div class="mb-3 p-3 rounded-lg bg-green-500/10 border border-green-500/30">
          <div class="text-sm font-semibold text-green-200">Paid · {{ job.total_display }}</div>
          <div class="text-xs text-gray-400 mt-0.5">{{ job.paid_at.strftime('%d %b %Y %H:%M') if job.paid_at else '' }} · via {{ job.paid_via or 'stripe' }}</div>
        </div>
        <form method="post" action="{{ url_for('quickjobs.admin_mark_paid', job_id=job.id) }}">
          <input type="hidden" name="paid" value="0">
          <button class="text-xs text-gray-400 hover:text-red-300">Mark as unpaid</button>
        </form>
      {% else %}
        <div class="mb-3">
          <div class="text-xs text-gray-500">Amount due</div>
          <div class="text-xl font-extrabold">{{ job.total_display }}</div>
        </div>
        {% if stripe_on %}
          <p class="text-xs text-gray-400 mb-3">The share link shows a <span class="text-ops-300 font-semibold">Pay</span> button (Stripe Checkout). It'll be marked paid automatically once they pay.</p>
        {% else %}
          <p class="text-xs text-yellow-300/90 mb-3">Stripe isn't configured, so the Pay button is hidden on the share link. Set STRIPE_SECRET_KEY to enable it.</p>
        {% endif %}
        <form method="post" action="{{ url_for('quickjobs.admin_mark_paid', job_id=job.id) }}">
          <input type="hidden" name="paid" value="1">
          <button class="w-full px-4 py-2 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-lg hover:bg-white/10 transition">Mark as paid manually</button>
        </form>
      {% endif %}
    </div>

    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5 space-y-2">
      <div class="text-sm font-bold mb-2">Status</div>
      {% for key, meta in status_meta.items() %}
        {% if key != job.status %}
        <form method="post" action="{{ url_for('quickjobs.admin_status', job_id=job.id) }}">
          <input type="hidden" name="status" value="{{ key }}">
          <button class="w-full text-left px-3 py-2 text-sm rounded-lg bg-white/5 border border-ink-600 hover:bg-white/10 transition">Mark {{ meta.label.lower() }}</button>
        </form>
        {% endif %}
      {% endfor %}
    </div>

    <form method="post" action="{{ url_for('quickjobs.admin_delete', job_id=job.id) }}" onsubmit="return confirm('Delete this job permanently?');">
      <button class="w-full px-4 py-2.5 text-sm font-semibold text-red-300 bg-red-500/10 border border-red-500/30 rounded-xl hover:bg-red-500/20 transition">Delete job</button>
    </form>
  </div>
</div>

<script>
  function copyShare(){
    var f=document.getElementById('shareUrl'); f.select(); f.setSelectionRange(0,99999);
    navigator.clipboard.writeText(f.value).then(function(){
      var b=document.getElementById('copyBtn'); var t=b.textContent; b.textContent='Copied!';
      setTimeout(function(){b.textContent=t;},1500);
    });
  }
</script>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/public/job.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}{{ job.title }} · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-2xl mx-auto px-4 sm:px-6 py-10 sm:py-16 w-full">

  <div class="rounded-2xl border border-ink-600 bg-ink-800/50 overflow-hidden">
    <!-- Header -->
    <div class="p-6 sm:p-8 border-b border-ink-600/60 bg-gradient-to-br from-ops-500/10 to-transparent">
      <div class="flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-ops-300 mb-2">
        <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/></svg>
        Job details
      </div>
      <h1 class="text-2xl sm:text-3xl font-extrabold tracking-tight">{{ job.title }}</h1>
      <div class="mt-3 flex items-center gap-2">
        <span class="pill" style="background:{{ job.status_meta.color }}1f;color:{{ job.status_meta.color }};border:1px solid {{ job.status_meta.color }}55;">{{ job.status_meta.label }}</span>
        {% if job.is_paid %}<span class="pill" style="background:#22c55e1f;color:#86efac;border:1px solid #22c55e55;">Paid</span>{% endif %}
      </div>
    </div>

    <!-- Body -->
    <div class="p-6 sm:p-8 space-y-6">

      {% for cat, msg in get_flashed_messages(with_categories=true) %}
        <div class="text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
      {% endfor %}

      {% if job.details %}
      <div>
        <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500 mb-1">Description</div>
        <p class="text-gray-200 whitespace-pre-line leading-relaxed">{{ job.details }}</p>
      </div>
      {% endif %}

      {% if job.contact_phone %}
      <p class="text-sm text-gray-400">Questions? Call us on <span class="text-gray-200 font-medium">{{ job.contact_phone }}</span>.</p>
      {% endif %}

      <!-- Items + total -->
      <div class="pt-5 border-t border-ink-600/60">
        <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500 mb-2">{{ 'Your order' if job.client_can_edit else 'Items' }}</div>

        {% if job.items %}
        <div class="rounded-xl border border-ink-600 overflow-hidden divide-y divide-ink-600/50">
          {% for it in job.items %}
          <div class="flex items-center gap-3 p-3 bg-ink-900/30">
            <div class="flex-1 min-w-0">
              <div class="text-sm text-gray-100 truncate">{{ it.label }}</div>
              <div class="text-xs text-gray-500">{{ it.unit_display }} each</div>
            </div>
            {% if job.client_can_edit %}
            <div class="flex items-center gap-1">
              <form method="post" action="{{ url_for('quickjobs.public_item_qty', token=job.token, item_id=it.id) }}"><input type="hidden" name="action" value="dec"><button class="w-7 h-7 rounded-md bg-white/5 border border-ink-600 text-gray-300 hover:bg-white/10">−</button></form>
              <span class="w-8 text-center text-sm">{{ it.quantity }}</span>
              <form method="post" action="{{ url_for('quickjobs.public_item_qty', token=job.token, item_id=it.id) }}"><input type="hidden" name="action" value="inc"><button class="w-7 h-7 rounded-md bg-white/5 border border-ink-600 text-gray-300 hover:bg-white/10">+</button></form>
            </div>
            {% else %}
            <span class="text-sm text-gray-400">×{{ it.quantity }}</span>
            {% endif %}
            <div class="w-20 text-right text-sm font-semibold">{{ it.amount_display }}</div>
            {% if job.client_can_edit %}
            <form method="post" action="{{ url_for('quickjobs.public_item_remove', token=job.token, item_id=it.id) }}"><button class="text-gray-500 hover:text-red-400 px-1" title="Remove">✕</button></form>
            {% endif %}
          </div>
          {% endfor %}
          <div class="flex items-center justify-between p-3 bg-ink-800/70">
            <span class="text-sm font-bold">Total</span>
            <span class="text-lg font-extrabold">{{ job.total_display }}</span>
          </div>
        </div>
        {% elif job.total_cents %}
        <div class="flex items-center justify-between p-3 rounded-xl border border-ink-600 bg-ink-900/30">
          <span class="text-sm text-gray-300">Price</span>
          <span class="text-lg font-extrabold">{{ job.total_display }}</span>
        </div>
        {% else %}
        <p class="text-sm text-gray-500">No items yet.</p>
        {% endif %}

        {% if job.client_can_edit %}
        <form method="post" action="{{ url_for('quickjobs.public_item_add', token=job.token) }}" class="mt-3 flex flex-col sm:flex-row gap-2 sm:items-end">
          <div class="flex-1"><label class="block text-[11px] text-gray-500 mb-1">Add an item</label><input name="label" required class="form-input w-full" placeholder="e.g. Extra callout"></div>
          <div class="w-full sm:w-28"><label class="block text-[11px] text-gray-500 mb-1">Price (£)</label><input name="unit_price" inputmode="decimal" class="form-input w-full" placeholder="0.00"></div>
          <div class="w-full sm:w-16"><label class="block text-[11px] text-gray-500 mb-1">Qty</label><input name="quantity" value="1" class="form-input w-full"></div>
          <button class="px-4 py-2.5 text-sm font-semibold text-white bg-ops-600 hover:bg-ops-500 rounded-lg whitespace-nowrap">Add</button>
        </form>
        {% endif %}
      </div>

      <!-- Payment -->
      {% if job.has_price and job.status != 'cancelled' %}
      <div class="pt-5 border-t border-ink-600/60">
        {% if request.args.get('paid') and not job.is_paid %}
          <p class="text-sm text-gray-400 mb-3">Finishing up your payment… refresh in a moment if the status hasn't updated.</p>
        {% endif %}
        {% if job.is_paid %}
          <div class="flex items-center justify-between gap-3 p-4 rounded-xl bg-green-500/10 border border-green-500/30">
            <div class="flex items-center gap-2 text-green-200 font-semibold">
              <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
              Paid
            </div>
            <span class="text-lg font-extrabold text-green-200">{{ job.total_display }}</span>
          </div>
        {% else %}
          <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 p-4 rounded-xl bg-ink-900/50 border border-ink-600">
            <div>
              <div class="text-xs text-gray-500">Amount due</div>
              <div class="text-2xl font-extrabold">{{ job.total_display }}</div>
            </div>
            {% if stripe_on %}
            <form method="post" action="{{ url_for('quickjobs.public_pay', token=job.token) }}">
              <button class="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M3 10h18M7 15h1m4 0h1m-7 4h12a3 3 0 003-3V8a3 3 0 00-3-3H6a3 3 0 00-3 3v8a3 3 0 003 3z"/></svg>
                Pay {{ job.total_display }}
              </button>
            </form>
            {% else %}
            <span class="text-sm text-yellow-300/90">Online payment isn't switched on yet.</span>
            {% endif %}
          </div>
          {% if stripe_on %}<p class="text-xs text-gray-500 mt-2">Secure payment via Stripe.</p>{% endif %}
        {% endif %}
      </div>
      {% endif %}

      <!-- Scheduling -->
      <div class="pt-5 border-t border-ink-600/60">
        {% if job.status == 'cancelled' %}
          <div class="p-4 rounded-xl bg-red-500/10 border border-red-500/30 text-sm text-red-200">This job has been cancelled.</div>
        {% elif job.scheduled_day %}
          <div class="flex items-center gap-3 p-4 rounded-xl bg-green-500/10 border border-green-500/30">
            <svg class="w-6 h-6 text-green-300 shrink-0" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
            <div>
              <div class="text-sm text-gray-400">Scheduled for</div>
              <div class="text-lg font-bold text-green-200">{{ job.scheduled_day.strftime('%A %d %B %Y') }}{{ ' · ' ~ job.scheduled_time if job.scheduled_time else '' }}</div>
            </div>
          </div>
          {% if job.client_can_edit %}
          <details class="mt-3 group">
            <summary class="text-sm text-ops-300 hover:text-ops-200 cursor-pointer select-none">Change the day</summary>
            <form method="post" action="{{ url_for('quickjobs.public_reschedule', token=job.token) }}" class="mt-3 flex flex-col sm:flex-row gap-3 sm:items-end">
              <div class="flex-1"><label class="block text-xs text-gray-400 mb-1">New date</label><input name="scheduled_day" type="date" min="{{ today }}" required class="form-input w-full"></div>
              <div><label class="block text-xs text-gray-400 mb-1">Time (optional)</label><input name="scheduled_time" type="time" class="form-input w-full"></div>
              <button class="px-5 py-2.5 text-sm font-semibold text-white bg-white/5 border border-ink-600 rounded-lg hover:bg-white/10 whitespace-nowrap">Update day</button>
            </form>
          </details>
          {% endif %}
        {% elif job.is_open_for_scheduling %}
          <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500 mb-2">Choose a day</div>
          <form method="post" action="{{ url_for('quickjobs.public_schedule', token=job.token) }}" class="flex flex-col sm:flex-row gap-3 sm:items-end">
            <div class="flex-1"><label class="block text-xs text-gray-400 mb-1">Preferred date</label><input name="scheduled_day" type="date" min="{{ today }}" required class="form-input w-full"></div>
            <div><label class="block text-xs text-gray-400 mb-1">Time (optional)</label><input name="scheduled_time" type="time" class="form-input w-full"></div>
            <button class="px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg shadow-glow-sm hover:shadow-glow transition whitespace-nowrap">Confirm day</button>
          </form>
          <p class="text-xs text-gray-500 mt-2">Times are Europe/London.</p>
        {% else %}
          <div class="p-4 rounded-xl bg-white/5 border border-ink-600 text-sm text-gray-300">A day will be confirmed with you directly.</div>
        {% endif %}
      </div>

      <!-- Your details (editable) -->
      {% if job.client_can_edit %}
      <div class="pt-5 border-t border-ink-600/60">
        <div class="text-[11px] font-bold uppercase tracking-widest text-gray-500 mb-2">Your details</div>
        <form method="post" action="{{ url_for('quickjobs.public_details', token=job.token) }}" class="grid sm:grid-cols-2 gap-3">
          <div><label class="block text-[11px] text-gray-500 mb-1">Name</label><input name="client_name" value="{{ job.client_name or '' }}" class="form-input w-full"></div>
          <div><label class="block text-[11px] text-gray-500 mb-1">Email</label><input name="client_email" type="email" value="{{ job.client_email or '' }}" class="form-input w-full"></div>
          <div><label class="block text-[11px] text-gray-500 mb-1">Phone</label><input name="client_phone" value="{{ job.client_phone or '' }}" class="form-input w-full"></div>
          <div><label class="block text-[11px] text-gray-500 mb-1">Address</label><input name="location" value="{{ job.location or '' }}" class="form-input w-full"></div>
          <div class="sm:col-span-2"><button class="px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg">Save details</button></div>
        </form>
      </div>
      {% elif job.location or job.client_name %}
      <div class="pt-5 border-t border-ink-600/60 grid sm:grid-cols-2 gap-4 text-sm">
        {% if job.client_name %}<div><div class="text-gray-500 text-xs">For</div><div class="text-gray-200">{{ job.client_name }}</div></div>{% endif %}
        {% if job.location %}<div><div class="text-gray-500 text-xs">Address</div><div class="text-gray-200">{{ job.location }}</div></div>{% endif %}
      </div>
      {% endif %}

      <!-- Cancel -->
      {% if job.allow_client_edits and not job.is_paid and job.status != 'cancelled' %}
      <div class="pt-5 border-t border-ink-600/60">
        <form method="post" action="{{ url_for('quickjobs.public_cancel', token=job.token) }}" onsubmit="return confirm('Cancel this job? This cannot be undone here.');">
          <button class="text-sm text-gray-500 hover:text-red-300">Cancel this job</button>
        </form>
      </div>
      {% endif %}
    </div>
  </div>

  <p class="text-center text-xs text-gray-600 mt-6">Powered by <span class="text-ops-500 font-semibold">OpsLab</span> Systems</p>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/reviews/index.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}Reviews · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-5xl mx-auto px-4 sm:px-6 py-12 sm:py-16 w-full">

  <div class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4 mb-10">
    <div>
      <div class="text-xs font-bold uppercase tracking-widest text-ops-300 mb-2">What people say</div>
      <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Reviews</h1>
      {% if avg %}
      <div class="mt-3 flex items-center gap-2 text-gray-300">
        <span class="text-yellow-400 text-lg tracking-tight">{{ '★' * (avg|round(0,'floor')|int) }}{{ '☆' * (5 - (avg|round(0,'floor')|int)) }}</span>
        <span class="font-semibold">{{ avg }}</span>
        <span class="text-gray-500 text-sm">· {{ count }} review{{ 's' if count != 1 }}</span>
      </div>
      {% endif %}
    </div>
    <a href="{{ url_for('reviews.new') }}" class="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition self-start">
      <svg class="w-4 h-4" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/></svg>
      Leave a review
    </a>
  </div>

  {% for cat, msg in get_flashed_messages(with_categories=true) %}
    <div class="mb-6 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
  {% endfor %}

  {% if reviews %}
  <style>#reviewGrid summary::-webkit-details-marker{display:none}</style>
  <div id="reviewGrid" class="grid sm:grid-cols-2 lg:grid-cols-3 gap-5 items-start">
    {% for r in reviews %}
    <div id="review-{{ r.id }}" class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5 flex flex-col scroll-mt-24">
      <div class="text-yellow-400 text-lg mb-3">{{ r.stars }}</div>
      <p class="text-gray-200 leading-relaxed flex-1 whitespace-pre-line">“{{ r.body }}”</p>
      <div class="mt-4 pt-4 border-t border-ink-600/60">
        <div class="font-semibold text-white">{{ r.name }}</div>
        <div class="text-xs text-gray-400">{{ [r.organisation, r.country]|select|join(' · ') }}</div>
      </div>

      <details class="mt-4 review-replies">
        <summary class="text-sm text-ops-300 hover:text-ops-200 cursor-pointer select-none" style="list-style:none">
          💬 View replies ({{ r.reply_count }})
        </summary>
        <div class="mt-3 space-y-3">
          {% for rep in r.replies %}
          <div class="rounded-lg bg-ink-900/40 border border-ink-600/60 p-3">
            <div class="flex items-center gap-2 text-xs">
              <span class="font-semibold {{ 'text-ops-300' if rep.is_staff else 'text-gray-200' }}">{{ rep.name }}</span>
              {% if rep.is_staff %}<span class="px-1.5 py-0.5 rounded bg-ops-500/15 text-ops-300 border border-ops-500/30 text-[10px] font-bold uppercase tracking-wide">OpsLab</span>{% endif %}
              <span class="text-gray-500">· {{ rep.created_at.strftime('%d %b %Y') }}</span>
              {% if current_user.is_authenticated and (current_user.is_staff or current_user.is_admin) %}
              <form method="post" action="{{ url_for('reviews.delete_reply', reply_id=rep.id) }}" class="ml-auto" onsubmit="return confirm('Delete this reply?');">
                <button class="text-gray-500 hover:text-red-400">✕</button>
              </form>
              {% endif %}
            </div>
            <p class="text-sm text-gray-200 mt-1 whitespace-pre-line">{{ rep.body }}</p>
          </div>
          {% else %}
          <p class="text-xs text-gray-500">No replies yet — ask the first question.</p>
          {% endfor %}

          <form method="post" action="{{ url_for('reviews.reply', rid=r.id) }}" class="space-y-2 pt-1">
            {% if not (current_user.is_authenticated and (current_user.is_staff or current_user.is_admin)) %}
            <input name="name" required class="form-input w-full text-sm" placeholder="Your name">
            {% endif %}
            <textarea name="body" required rows="2" class="form-textarea w-full text-sm" placeholder="Ask a question or reply…"></textarea>
            <button class="px-4 py-2 text-xs font-semibold text-white bg-ops-600 hover:bg-ops-500 rounded-lg">
              {{ 'Reply as OpsLab' if (current_user.is_authenticated and (current_user.is_staff or current_user.is_admin)) else 'Post reply' }}
            </button>
          </form>
        </div>
      </details>
    </div>
    {% endfor %}
  </div>
  {% else %}
  <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-10 text-center">
    <p class="text-gray-400">No reviews yet — be the first to leave one!</p>
    <a href="{{ url_for('reviews.new') }}" class="inline-block mt-4 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl">Leave a review</a>
  </div>
  {% endif %}
</div>
<script>
  (function(){
    if (location.hash && location.hash.indexOf('#review-') === 0){
      var el = document.querySelector(location.hash);
      if (el){
        var d = el.querySelector('.review-replies');
        if (d){ d.setAttribute('open',''); }
        el.scrollIntoView();
      }
    }
  })();
</script>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/reviews/new.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}Leave a review · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-xl mx-auto px-4 sm:px-6 py-12 sm:py-16 w-full">
  <div class="text-xs font-bold uppercase tracking-widest text-ops-300 mb-2"><a href="{{ url_for('reviews.index') }}" class="hover:text-ops-200">Reviews</a></div>
  <h1 class="text-3xl font-extrabold tracking-tight mb-6">Leave a review</h1>

  {% for cat, msg in get_flashed_messages(with_categories=true) %}
    <div class="mb-6 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
  {% endfor %}

  <form method="post" class="rounded-2xl border border-ink-600 bg-ink-800/40 p-6 space-y-5">
    <div>
      <label class="block text-sm font-semibold mb-1.5">Your rating</label>
      <div class="star-pick inline-flex flex-row-reverse gap-1 text-3xl">
        {% for n in [5,4,3,2,1] %}
        <input type="radio" id="star{{ n }}" name="rating" value="{{ n }}" class="peer sr-only" {{ 'checked' if (form.get('rating')|int == n) or (not form.get('rating') and n == 5) }}>
        <label for="star{{ n }}" class="cursor-pointer text-ink-600 transition-colors hover:text-yellow-400 peer-checked:text-yellow-400">★</label>
        {% endfor %}
      </div>
      <p class="text-xs text-gray-500 mt-1">Tap a star (1–5).</p>
    </div>

    <div>
      <label class="block text-sm font-semibold mb-1.5">Name <span class="text-red-400">*</span></label>
      <input name="name" required value="{{ form.get('name','') }}" class="form-input w-full" placeholder="Your name">
    </div>

    <div class="grid sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-sm font-semibold mb-1.5">Business / community</label>
        <input name="organisation" value="{{ form.get('organisation','') }}" class="form-input w-full" placeholder="Optional">
      </div>
      <div>
        <label class="block text-sm font-semibold mb-1.5">Country</label>
        <input name="country" list="countrylist" value="{{ form.get('country','') }}" class="form-input w-full" placeholder="Optional">
        <datalist id="countrylist">
          <option>United Kingdom</option><option>Scotland</option><option>South Africa</option>
          <option>Ireland</option><option>United States</option><option>Canada</option>
          <option>Australia</option><option>Germany</option><option>Netherlands</option>
        </datalist>
      </div>
    </div>

    <div>
      <label class="block text-sm font-semibold mb-1.5">Your review <span class="text-red-400">*</span></label>
      <textarea name="body" rows="5" required class="form-textarea w-full" placeholder="Tell others about your experience…">{{ form.get('body','') }}</textarea>
    </div>

    <button class="w-full px-5 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Post review</button>
  </form>
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/admin/reviews/list.html" << '__OPSLAB_EOF__'
{% extends "admin/_layout.html" %}
{% block admin_title %}Reviews{% endblock %}
{% block admin_content %}
<div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
  <div>
    <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Reviews</h1>
    <p class="text-gray-400 mt-1 text-sm">Moderate website testimonials. Approved reviews show on the homepage slider and the public Reviews page.</p>
  </div>
  <a href="{{ url_for('reviews.index') }}" target="_blank" class="px-4 py-2 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-lg self-start">View public page</a>
</div>

<div class="flex gap-2 mb-5 text-sm">
  {% for key, label in [('all','All'),('approved','Shown'),('pending','Hidden')] %}
  <a href="{{ url_for('reviews.admin_list', show=key) }}" class="px-3 py-1.5 rounded-lg border {{ 'bg-ops-500/15 border-ops-500/40 text-ops-200' if show==key else 'bg-white/5 border-ink-600 text-gray-300 hover:bg-white/10' }}">{{ label }}</a>
  {% endfor %}
</div>

{% for cat, msg in get_flashed_messages(with_categories=true) %}
  <div class="mb-5 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
{% endfor %}

<div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5 mb-6">
  <div class="flex items-center gap-2 mb-2">
    <svg class="w-5 h-5 text-ops-300" fill="currentColor" viewBox="0 0 24 24"><path d="M20.3 4.3A19 19 0 0015.6 3l-.2.5c1.7.4 2.6.9 3.6 1.6a13 13 0 00-11.9 0c1-.7 2-1.2 3.6-1.6L10.4 3a19 19 0 00-4.7 1.3C2.7 8.8 2 13.2 2.2 17.6a19 19 0 005.8 2.9l.5-1c-.6-.2-1.3-.5-2-1l.4-.3a13.6 13.6 0 0011.6 0l.4.3c-.7.5-1.4.8-2 1l.5 1a19 19 0 005.8-2.9c.4-5-.8-9.4-2.9-13.3z"/></svg>
    <span class="text-sm font-bold">Discord webhook</span>
    {% if webhook_set %}<span class="px-2 py-0.5 rounded text-[10px] font-bold uppercase tracking-wide bg-green-500/15 text-green-300 border border-green-500/30">Connected</span>{% else %}<span class="px-2 py-0.5 rounded text-[10px] font-bold uppercase tracking-wide bg-white/5 text-gray-400 border border-ink-600">Not set</span>{% endif %}
  </div>
  <p class="text-xs text-gray-400 mb-3">New reviews are posted to this Discord channel as a rich embed. Paste the channel's webhook URL.</p>
  <form method="post" action="{{ url_for('reviews.admin_webhook') }}" class="flex flex-col sm:flex-row gap-2">
    <input name="webhook_url" type="password" autocomplete="off" placeholder="https://discord.com/api/webhooks/…"
           class="form-input flex-1 text-sm" {{ 'value=" "' if webhook_set else '' }}>
    <button name="action" value="save" class="px-4 py-2 text-sm font-semibold text-white bg-ops-600 hover:bg-ops-500 rounded-lg">Save</button>
    <button name="action" value="test" class="px-4 py-2 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-lg hover:bg-white/10">Send test</button>
  </form>
  <p class="text-[11px] text-gray-500 mt-2">Tip: in Discord → channel → Edit → Integrations → Webhooks → New Webhook → Copy URL.</p>
</div>

{% if reviews %}
<div class="space-y-4">
  {% for r in reviews %}
  <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5 {{ 'opacity-60' if not r.approved }}">
    <div class="flex items-start justify-between gap-4">
      <div class="min-w-0">
        <div class="text-yellow-400">{{ r.stars }}</div>
        <p class="text-gray-200 mt-2 whitespace-pre-line">“{{ r.body }}”</p>
        <div class="mt-3 text-sm">
          <span class="font-semibold text-white">{{ r.name }}</span>
          <span class="text-gray-400">{{ ' · ' ~ r.byline.split(' · ')[1:]|join(' · ') if r.organisation or r.country }}</span>
        </div>
        <div class="text-xs text-gray-500 mt-1">{{ r.created_at.strftime('%d %b %Y') }} · {{ 'Shown' if r.approved else 'Hidden' }}</div>
      </div>
      <div class="flex flex-col gap-2 shrink-0">
        <form method="post" action="{{ url_for('reviews.admin_approve', rid=r.id, show=show) }}">
          <button class="w-full px-3 py-1.5 text-xs font-semibold rounded-lg {{ 'bg-white/5 border border-ink-600 text-gray-300 hover:bg-white/10' if r.approved else 'bg-green-500/15 border border-green-500/40 text-green-200' }}">{{ 'Hide' if r.approved else 'Show' }}</button>
        </form>
        {% if r.posted_to_discord %}
        <span class="w-full text-center px-3 py-1.5 text-xs font-semibold text-ops-300 bg-ops-500/10 border border-ops-500/30 rounded-lg">✓ Posted</span>
        {% elif webhook_set %}
        <form method="post" action="{{ url_for('reviews.admin_post', rid=r.id, show=show) }}">
          <button class="w-full px-3 py-1.5 text-xs font-semibold text-white bg-[#5865F2] hover:opacity-90 rounded-lg">Post to Discord</button>
        </form>
        {% else %}
        <span class="w-full text-center px-3 py-1.5 text-xs text-gray-500 border border-ink-600 rounded-lg">Set webhook to post</span>
        {% endif %}
        <form method="post" action="{{ url_for('reviews.admin_delete', rid=r.id, show=show) }}" onsubmit="return confirm('Delete this review permanently?');">
          <button class="w-full px-3 py-1.5 text-xs font-semibold text-red-300 bg-red-500/10 border border-red-500/30 rounded-lg hover:bg-red-500/20">Delete</button>
        </form>
      </div>
    </div>
  </div>
  {% endfor %}
</div>
{% else %}
<div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-10 text-center text-gray-400">No reviews here yet.</div>
{% endif %}
{% endblock %}
__OPSLAB_EOF__
write "app/templates/public/callout.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}Book a call-out · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-xl mx-auto px-4 sm:px-6 py-12 sm:py-16 w-full">

  {% if sent %}
  <div class="rounded-2xl border border-green-500/30 bg-green-500/10 p-8 text-center">
    <svg class="w-12 h-12 text-green-300 mx-auto mb-3" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
    <h1 class="text-2xl font-extrabold mb-2">Request received</h1>
    <p class="text-gray-300">Thanks — we'll be in touch shortly to confirm a time.</p>
    <a href="{{ url_for('main.index') }}" class="inline-block mt-6 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl">Back to home</a>
  </div>
  {% else %}

  <div class="text-xs font-bold uppercase tracking-widest text-ops-300 mb-2">Get in touch</div>
  <h1 class="text-3xl font-extrabold tracking-tight mb-2">Book a call-out</h1>
  <p class="text-gray-400 mb-6">Request an in-person visit across the Scottish Borders, or arrange a phone/online session. Services outside the area are available at a charge.</p>

  {% for cat, msg in get_flashed_messages(with_categories=true) %}
    <div class="mb-6 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
  {% endfor %}

  <form method="post" class="rounded-2xl border border-ink-600 bg-ink-800/40 p-6 space-y-5">
    <div>
      <label class="block text-sm font-semibold mb-1.5">What do you need? <span class="text-red-400">*</span></label>
      <div class="space-y-2" id="modeGroup">
        {% for key, meta in modes.items() %}
        <label class="flex items-start gap-3 p-3 rounded-xl bg-ink-900/50 border border-ink-600 cursor-pointer has-[:checked]:border-ops-500/70 has-[:checked]:bg-ops-500/[.08] transition">
          <input type="radio" name="mode" value="{{ key }}" class="mode-radio mt-0.5 w-4 h-4 accent-ops-500" {{ 'checked' if (form.get('mode')==key) or (not form.get('mode') and loop.first) }} data-inperson="{{ '1' if key in ['in_person','outside'] else '0' }}">
          <span class="text-sm text-gray-200">{{ meta.label }}</span>
        </label>
        {% endfor %}
      </div>
    </div>

    <div class="grid sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-sm font-semibold mb-1.5">Name <span class="text-red-400">*</span></label>
        <input name="name" required value="{{ form.get('name','') }}" class="form-input w-full" placeholder="Your name">
      </div>
      <div>
        <label class="block text-sm font-semibold mb-1.5">Phone <span class="text-red-400">*</span></label>
        <input name="phone" required value="{{ form.get('phone','') }}" class="form-input w-full" placeholder="Best number to reach you">
      </div>
      <div class="sm:col-span-2">
        <label class="block text-sm font-semibold mb-1.5">Email</label>
        <input name="email" type="email" value="{{ form.get('email','') }}" class="form-input w-full" placeholder="you@example.com (optional)">
      </div>
    </div>
    <p class="text-xs text-gray-500 -mt-2">We'll call or text you to confirm a time.</p>

    <div id="addressRow">
      <label class="block text-sm font-semibold mb-1.5">Address / area <span class="text-gray-500 font-normal">(for in-person visits)</span></label>
      <input name="location" value="{{ form.get('location','') }}" class="form-input w-full" placeholder="Town / postcode">
    </div>

    <div class="grid sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-sm font-semibold mb-1.5">Preferred date</label>
        <input name="preferred_day" type="date" value="{{ form.get('preferred_day','') }}" class="form-input w-full">
      </div>
      <div>
        <label class="block text-sm font-semibold mb-1.5">Preferred time</label>
        <select name="preferred_time" class="form-select w-full">
          <option value="">Any time</option>
          {% for h in range(8, 19) %}
            {% for m in ['00','30'] %}
              {% set t = '%02d:%s'|format(h, m) %}
              <option value="{{ t }}" {{ 'selected' if form.get('preferred_time')==t }}>{{ t }}</option>
            {% endfor %}
          {% endfor %}
        </select>
      </div>
    </div>

    <div class="flex items-start gap-2.5 text-sm text-gray-300 bg-ops-500/[.06] border border-ops-500/25 rounded-xl p-3.5">
      <svg class="w-5 h-5 text-ops-300 mt-0.5 shrink-0" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
      <p>I do my best to offer <span class="font-semibold text-white">same-day or next-day</span> call-outs. It isn't always possible — it depends on your location, how booked-up the day is, and parts availability — but pop in your preferred date and time and I'll confirm the soonest slot I can.</p>
    </div>

    <div>
      <label class="block text-sm font-semibold mb-1.5">What can we help with? <span class="text-red-400">*</span></label>
      <select name="service" id="serviceSelect" required class="form-select w-full">
        <option value="">Choose a service…</option>
        {% for grp, opts in service_groups %}
        <optgroup label="{{ grp }}">
          {% for o in opts %}
          <option value="{{ o }}"
                  data-other="{{ '1' if o == other_label else '0' }}"
                  data-price="{{ prices.get(o, '') }}"
                  {{ 'selected' if form.get('service')==o }}>{{ o }}{% if o != other_label and prices.get(o) %} — {{ prices.get(o) }}{% endif %}</option>
          {% endfor %}
        </optgroup>
        {% endfor %}
      </select>
      <div id="estBox" class="hidden mt-2 flex items-center gap-2 text-sm">
        <span class="text-gray-400">Estimated price:</span>
        <span id="estVal" class="font-bold text-white"></span>
        <span class="text-xs text-gray-500">— estimate only, confirmed after assessment</span>
      </div>
    </div>

    <div id="otherWrap" style="display:none;">
      <label class="block text-sm font-semibold mb-1.5">Please describe what you need <span class="text-red-400">*</span></label>
      <textarea name="other_detail" id="otherDetail" rows="4" class="form-textarea w-full" placeholder="Tell us a bit about what you're after…">{{ form.get('other_detail','') }}</textarea>
    </div>

    <button class="w-full px-5 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Send request</button>
  </form>

  <script>
  (function(){
    var radios = Array.prototype.slice.call(document.querySelectorAll('.mode-radio'));
    var addr = document.getElementById('addressRow');
    function syncAddr(){
      var sel = radios.filter(function(r){ return r.checked; })[0];
      var inPerson = sel && sel.dataset.inperson === '1';
      addr.style.display = inPerson ? '' : 'none';
    }
    radios.forEach(function(r){ r.addEventListener('change', syncAddr); });
    syncAddr();

    var svc = document.getElementById('serviceSelect');
    var wrap = document.getElementById('otherWrap');
    var ta = document.getElementById('otherDetail');
    var estBox = document.getElementById('estBox');
    var estVal = document.getElementById('estVal');
    function syncOther(){
      var opt = svc.options[svc.selectedIndex];
      var isOther = opt && opt.getAttribute('data-other') === '1';
      wrap.style.display = isOther ? '' : 'none';
      if (ta) ta.required = isOther;
      var price = opt ? (opt.getAttribute('data-price') || '') : '';
      if (!svc.value || isOther) {
        estBox.classList.add('hidden');
      } else if (price) {
        estVal.textContent = price;
        estBox.classList.remove('hidden');
      } else {
        estVal.textContent = 'confirmed after assessment';
        estBox.classList.remove('hidden');
      }
    }
    svc.addEventListener('change', syncOther);
    syncOther();
  })();
  </script>
  {% endif %}
</div>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/public/pricing.html" << '__OPSLAB_EOF__'
{% extends "base.html" %}
{% block title %}On-site Pricing · OpsLab Systems{% endblock %}
{% block content %}
<div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-12 sm:py-16">

  <div class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4 mb-8">
    <div>
      <div class="flex items-center gap-2 text-xs font-bold uppercase tracking-widest text-ops-300 mb-2">
        <span class="live-dot"></span> Live pricing
      </div>
      <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">On-site service pricing</h1>
      <p class="text-gray-400 mt-2 text-sm max-w-xl">Estimated prices for our on-site &amp; in-person services. These are guide prices — the final cost is confirmed after assessment. Updates automatically.</p>
    </div>
    <a href="{{ url_for('callouts.book') }}" class="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition self-start whitespace-nowrap">Book a call-out</a>
  </div>

  <div class="space-y-5" id="priceList">
    {% for grp, opts in service_groups %}
    <div class="rounded-2xl border border-ink-600 bg-ink-800/40 overflow-hidden">
      <div class="px-5 py-3 bg-ink-900/40 text-sm font-bold text-ops-200">{{ grp }}</div>
      <div class="divide-y divide-ink-600/50">
        {% for o in opts %}
          {% if o != other_label %}
          <div class="flex items-center justify-between gap-4 px-5 py-3">
            <span class="text-sm text-gray-200">{{ o }}</span>
            <span class="text-sm font-bold text-white whitespace-nowrap price-cell" data-key="{{ o }}">{{ prices.get(o) or 'On assessment' }}</span>
          </div>
          {% endif %}
        {% endfor %}
      </div>
    </div>
    {% endfor %}
  </div>

  <p class="text-xs text-gray-500 mt-6">Prices shown are estimates and may vary depending on location, access and parts. Areas outside the Scottish Borders may incur a travel charge. <span id="priceStamp" class="text-gray-600"></span></p>
</div>

<script>
(function(){
  var cells = Array.prototype.slice.call(document.querySelectorAll('.price-cell'));
  var stamp = document.getElementById('priceStamp');
  function apply(data){
    cells.forEach(function(c){
      var k = c.getAttribute('data-key');
      var v = (data && Object.prototype.hasOwnProperty.call(data, k)) ? data[k] : '';
      var next = v || 'On assessment';
      if (c.textContent !== next){
        c.textContent = next;
        c.classList.add('price-flash');
        setTimeout(function(){ c.classList.remove('price-flash'); }, 900);
      }
    });
    if (stamp){ stamp.textContent = '· Updated ' + new Date().toLocaleTimeString(); }
  }
  function poll(){
    fetch('{{ url_for("callouts.pricing_json") }}', {cache:'no-store'})
      .then(function(r){ return r.ok ? r.json() : null; })
      .then(function(d){ if (d) apply(d); })
      .catch(function(){});
  }
  setInterval(poll, 15000);  // live refresh every 15s
  // first refresh shortly after load to set the timestamp
  setTimeout(poll, 2000);
})();
</script>
<style>
  .price-flash{ animation: priceFlash 0.9s ease; }
  @keyframes priceFlash{ 0%{ color:#7cc0ff; } 100%{ color:#fff; } }
</style>
{% endblock %}
__OPSLAB_EOF__
write "app/templates/admin/callouts/list.html" << '__OPSLAB_EOF__'
{% extends "admin/_layout.html" %}
{% block admin_title %}Call-out requests{% endblock %}
{% block admin_content %}
<div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
  <div>
    <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Call-out requests</h1>
    <p class="text-gray-400 mt-1 text-sm">In-person, phone &amp; online requests submitted from the “Book a call-out” page.</p>
  </div>
  <a href="{{ url_for('callouts.admin_prices') }}" class="px-4 py-2 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-lg self-start whitespace-nowrap">Set prices</a>
</div>

<div class="flex flex-wrap gap-2 mb-5 text-sm">
  <a href="{{ url_for('callouts.admin_list') }}" class="px-3 py-1.5 rounded-lg border {{ 'bg-ops-500/15 border-ops-500/40 text-ops-200' if not status else 'bg-white/5 border-ink-600 text-gray-300 hover:bg-white/10' }}">All</a>
  {% for key, meta in status_meta.items() %}
  <a href="{{ url_for('callouts.admin_list', status=key) }}" class="px-3 py-1.5 rounded-lg border {{ 'bg-ops-500/15 border-ops-500/40 text-ops-200' if status==key else 'bg-white/5 border-ink-600 text-gray-300 hover:bg-white/10' }}">{{ meta.label }}</a>
  {% endfor %}
</div>

{% for cat, msg in get_flashed_messages(with_categories=true) %}
  <div class="mb-5 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
{% endfor %}

{% if items %}
<div class="space-y-4">
  {% for r in items %}
  <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
    <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
      <div class="min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-semibold text-white">{{ r.name }}</span>
          <span class="pill" style="background:{{ r.status_meta.color }}1f;color:{{ r.status_meta.color }};border:1px solid {{ r.status_meta.color }}55;">{{ r.status_meta.label }}</span>
        </div>
        <div class="text-sm text-ops-200 mt-1">{{ r.mode_meta.label }}</div>
        <div class="text-sm text-gray-300 mt-2 space-y-0.5">
          {% if r.phone %}<div>📞 {{ r.phone }}</div>{% endif %}
          {% if r.email %}<div>✉️ {{ r.email }}</div>{% endif %}
          {% if r.location %}<div>📍 {{ r.location }}</div>{% endif %}
          {% if r.preferred_day %}<div>🗓 {{ r.preferred_day.strftime('%a %d %b %Y') }}{{ ' · ' ~ r.preferred_time if r.preferred_time else '' }}</div>{% endif %}
        </div>
        {% if r.details %}<p class="text-sm text-gray-300 mt-2 whitespace-pre-line border-l-2 border-ink-600 pl-3">{{ r.details }}</p>{% endif %}
        <div class="text-xs text-gray-500 mt-2">Received {{ r.created_at.strftime('%d %b %Y %H:%M') }}</div>
      </div>
      <div class="flex flex-col gap-2 shrink-0 sm:w-44">
        <form method="post" action="{{ url_for('callouts.admin_status', rid=r.id, status=status) }}" class="flex gap-2">
          <select name="status" class="form-select flex-1 text-sm">
            {% for key, meta in status_meta.items() %}<option value="{{ key }}" {{ 'selected' if r.status==key }}>{{ meta.label }}</option>{% endfor %}
          </select>
          <button class="px-3 py-2 text-xs font-semibold text-white bg-ops-600 hover:bg-ops-500 rounded-lg">Set</button>
        </form>
        <form method="post" action="{{ url_for('callouts.admin_delete', rid=r.id, status=status) }}" onsubmit="return confirm('Delete this request?');">
          <button class="w-full px-3 py-1.5 text-xs font-semibold text-red-300 bg-red-500/10 border border-red-500/30 rounded-lg hover:bg-red-500/20">Delete</button>
        </form>
      </div>
    </div>
  </div>
  {% endfor %}
</div>
{% else %}
<div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-10 text-center text-gray-400">No requests here yet.</div>
{% endif %}
{% endblock %}
__OPSLAB_EOF__
write "app/templates/admin/callouts/prices.html" << '__OPSLAB_EOF__'
{% extends "admin/_layout.html" %}
{% block admin_title %}Call-out prices{% endblock %}
{% block admin_content %}
<div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
  <div>
    <h1 class="text-3xl sm:text-4xl font-extrabold tracking-tight">Call-out prices</h1>
    <p class="text-gray-400 mt-1 text-sm">Set an estimated price for each service. Visitors see it on the Book a call-out form when they choose a service. Leave blank for “confirmed after assessment”.</p>
  </div>
  <div class="flex items-center gap-2 self-start">
    <a href="{{ url_for('callouts.pricing') }}" target="_blank" class="px-4 py-2 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-lg">View live page ↗</a>
    <a href="{{ url_for('callouts.admin_list') }}" class="px-4 py-2 text-sm font-semibold text-gray-200 bg-white/5 border border-ink-600 rounded-lg">← Requests</a>
  </div>
</div>

{% for cat, msg in get_flashed_messages(with_categories=true) %}
  <div class="mb-5 text-sm px-4 py-2.5 rounded-lg {{ 'bg-red-500/10 border border-red-500/30 text-red-200' if cat=='error' else 'bg-green-500/10 border border-green-500/30 text-green-200' }}">{{ msg }}</div>
{% endfor %}

<form method="post" class="space-y-6">
  {% for grp, opts in service_groups %}
  <div class="rounded-2xl border border-ink-600 bg-ink-800/40 p-5">
    <div class="text-sm font-bold text-ops-200 mb-3">{{ grp }}</div>
    <div class="space-y-2">
      {% for o in opts %}
        {% if o != other_label %}
        <div class="flex items-center gap-3">
          <label class="flex-1 text-sm text-gray-200">{{ o }}</label>
          <input name="{{ o }}" value="{{ prices.get(o, '') }}"
                 class="form-input w-44 text-sm" placeholder="e.g. £100 or 100-200">
        </div>
        {% endif %}
      {% endfor %}
    </div>
  </div>
  {% endfor %}

  <div class="sticky bottom-4">
    <button class="w-full px-5 py-3 text-sm font-semibold text-white bg-gradient-to-r from-ops-500 to-ops-700 rounded-xl shadow-glow-sm hover:shadow-glow transition">Save prices</button>
  </div>
</form>
{% endblock %}
__OPSLAB_EOF__
write "INTEGRATION_portal.md" << '__OPSLAB_EOF__'
# OpsLab Systems — Portal Expansion (Phase 1)

This adds a customer **portal** on top of your existing app: dashboard, projects
with progress tracking + timeline, appointments (Europe/London, 24h, conflict
detection), invoices with Stripe checkout, an in-app notification centre, plus
the full data layer + 5-role RBAC for everything in the spec. Built on plain
Flask, your existing Flask-Login auth, and the Flowbite dark theme.

---

## What's included and working (verified end-to-end)

- **Data layer** — `app/models_business.py`: Service, Project (+milestones,
  timeline events), Appointment (+working hours, blackout dates), Invoice
  (+line items, payments), ShopCategory/ShopProduct, Notification, AuditLog,
  StoredFile, UserProfile, LoginEvent, plus schema for KbArticle, Message,
  Announcement, Review (UIs land in later phases). Money is stored as integer
  **cents**.
- **RBAC** — `app/rbac.py`: `super_admin > admin > staff > support > customer`,
  backward compatible with your existing `"admin"`/`"user"`/`"staff"` values.
  Decorators `@require_role`, `@require_permission`.
- **Portal** — `app/portal/`: 15 routes under `/portal` + `/billing/webhook`.
  Customer dashboard, project create/view + visual timeline + progress bar,
  staff stage/percent/assignment controls, appointment booking with live slot
  generation and conflict detection, invoice list/detail + Stripe pay button,
  notification centre.
- **Stripe** — `app/billing.py`: checkout sessions + webhook handler. No-ops
  cleanly until you set keys, so the rest runs without Stripe.
- **A required auth fix** — see the note at the bottom.

## Files

**New:** `app/models_business.py`, `app/rbac.py`, `app/billing.py`,
`app/portal/__init__.py`, `app/portal/routes.py`,
`app/templates/portal/*.html` (10 templates).

**Edited:** `app/__init__.py` (register models + blueprints + Stripe/timezone
config + login-manager fix), `app/templates/base.html` (Dashboard nav link),
`requirements.txt`.

---

## Install

```bash
cd /opt/opslabs            # your deploy path
source .venv/bin/activate  # if you use one
pip install -r requirements.txt
```

## Move to PostgreSQL

1. Create the DB and user:
   ```bash
   sudo -u postgres psql -c "CREATE USER opslabs WITH PASSWORD 'CHANGE_ME';"
   sudo -u postgres psql -c "CREATE DATABASE opslabs OWNER opslabs;"
   ```
2. Point the app at it (add to your `.env` / systemd unit):
   ```
   DATABASE_URL=postgresql+psycopg2://opslabs:CHANGE_ME@127.0.0.1:5432/opslabs
   ```
   Leave `DATABASE_URL` unset and it falls back to the existing SQLite file —
   handy for local dev. **Schema is identical either way.**

The app still calls `db.create_all()` on boot, so tables are created
automatically. If you'd rather use real migrations (recommended for prod):

```bash
export FLASK_APP=wsgi.py        # or run.py — whatever your entrypoint is
flask db migrate -m "portal expansion"
flask db upgrade
```

## Stripe (optional — pay buttons stay disabled until set)

Add to `.env`:
```
STRIPE_SECRET_KEY=sk_live_...
STRIPE_PUBLISHABLE_KEY=pk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
DISPLAY_TIMEZONE=Europe/London
```
Then register the webhook in the Stripe dashboard:
`https://web.opslabsystems.cloud/billing/webhook`
(events: `checkout.session.completed`, `invoice.paid`,
`customer.subscription.deleted`).

## Restart

```bash
systemctl restart opslabs-app.service
```

Then sign in and open **/portal**. The new **Dashboard** link is in the nav for
logged-in users.

---

## Required auth fix (read this)

While testing I found a pre-existing issue that blocks the portal **and already
breaks `/tickets` and `/admin` in a clean build**: the License Manager's
`_setup_independent_login()` calls `lic_lm.init_app(app)` last, which makes its
`AdminUser`-only loader the app-wide Flask-Login manager. That shadows the
scope-aware wrapper it installs on your main manager, so `current_user` comes
back anonymous on every non-`/licenses` page.

The fix is already applied in the edited `app/__init__.py`: right after
`licenses.register(app)` it re-asserts your OpsLabs manager as active and adds a
scoped `unauthorized_handler` so `/licenses/*` still redirects to the licenses
login. Verified: `/tickets`, `/admin`, `/portal` all authenticate; `/licenses`
admin still gates to `/licenses/auth/login`. If your production somehow relies
on `lic_lm` being the global manager, remove those lines — but in this codebase
as shipped, the app needs them.

---

## Deferred to later phases (schema is already in place)

E-commerce storefront/cart + product admin, Stripe subscriptions UI + customer
billing portal, PDF invoices, file uploads + ClamAV virus scanning, knowledge
base, internal messaging, reviews, announcement management UI, real-time
activity feed, and Celery/Redis background jobs (email/PDF/webhook retries).
Each builds on the models and RBAC shipped here.
__OPSLAB_EOF__

# ── Repoint OpsLabs admin renders to de-collided template names ──────────
_ADM="$APP_ROOT/app/routes/admin.py"
_SET="$APP_ROOT/app/routes/admin_settings.py"
[ -f "$_ADM" ] && sed -i \
  -e 's#render_template("admin/dashboard.html"#render_template("admin/ops_dashboard.html"#g' \
  -e 's#render_template("admin/users.html"#render_template("admin/ops_users.html"#g' "$_ADM"
[ -f "$_SET" ] && sed -i 's#"admin/settings.html"#"admin/ops_settings.html"#g' "$_SET"

# ── Restore ANY templates missing on this server (never clobbers existing) ─
# Your live app/templates was missing files (index.html, admin/dashboard.html…);
# this copies any template present in the bundle but absent on the server.
_BUNDLE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -n "$_BUNDLE" ] && [ -d "$_BUNDLE/app/templates" ]; then
  say "Restoring any missing templates…"
  ( cd "$_BUNDLE/app/templates" && find . -type f -name '*.html' | sed 's#^\./##' ) | while IFS= read -r rel; do
    _dst="$APP_ROOT/app/templates/$rel"
    if [ ! -f "$_dst" ]; then
      mkdir -p "$(dirname "$_dst")"
      cp "$_BUNDLE/app/templates/$rel" "$_dst"
      echo "   restored app/templates/$rel"
    fi
  done
  ok "Missing templates restored"
else
  warn "Bundle templates not found next to the script — run from inside the unzipped folder."
fi

ok "All files written"

# ── Ensure new deps are present in requirements.txt (append if missing) ──
REQ="$APP_ROOT/requirements.txt"
if [ -f "$REQ" ]; then
  grep -qi '^psycopg2' "$REQ" || echo 'psycopg2-binary>=2.9' >> "$REQ"
  grep -qi '^stripe'   "$REQ" || echo 'stripe>=9.0'          >> "$REQ"
  grep -qi '^Authlib'  "$REQ" || echo 'Authlib>=1.3'         >> "$REQ"
  ok "requirements.txt updated"
fi

# ── Install deps ─────────────────────────────────────────────────────────
# Find a pip: explicit VENV → common venv paths → system pip3
PIP=""
if [ -n "$VENV" ] && [ -x "$VENV/bin/pip" ]; then PIP="$VENV/bin/pip"
elif [ -x "$APP_ROOT/.venv/bin/pip" ]; then PIP="$APP_ROOT/.venv/bin/pip"
elif [ -x "$APP_ROOT/venv/bin/pip" ];  then PIP="$APP_ROOT/venv/bin/pip"
elif command -v pip3 >/dev/null 2>&1;  then PIP="pip3"
fi

if [ -n "$PIP" ]; then
  say "Installing deps with: $PIP"
  "$PIP" install --upgrade psycopg2-binary 'stripe>=9.0' 'Authlib>=1.3' >/dev/null 2>&1 \
    && ok "psycopg2-binary + stripe + Authlib installed" \
    || warn "pip install hit an issue — run: $PIP install psycopg2-binary stripe Authlib"
else
  warn "No pip found. Activate your venv and run: pip install psycopg2-binary stripe Authlib"
fi

# ── Restart service ──────────────────────────────────────────────────────
if [ "$DO_RESTART" = "1" ] && command -v systemctl >/dev/null 2>&1 \
   && systemctl list-unit-files 2>/dev/null | grep -q "^$SERVICE"; then
  say "Restarting $SERVICE"
  systemctl restart "$SERVICE" && ok "$SERVICE restarted" || warn "Could not restart $SERVICE — restart it manually."
else
  warn "Service '$SERVICE' not restarted (not found or --no-restart). Restart your app manually."
fi

# ── Done ─────────────────────────────────────────────────────────────────
cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
 Done. The portal is mounted at /portal (Dashboard link is in the nav).

 NEXT — optional but recommended:

 1) PostgreSQL: add to your .env / systemd unit, then restart:
      DATABASE_URL=postgresql+psycopg2://opslabs:PASSWORD@127.0.0.1:5432/opslabs
    (unset = falls back to SQLite; tables auto-create on boot either way)

 2) Stripe (pay buttons stay off until set):
      STRIPE_SECRET_KEY=sk_live_...
      STRIPE_PUBLISHABLE_KEY=pk_live_...
      STRIPE_WEBHOOK_SECRET=whsec_...
    Webhook URL: https://YOURDOMAIN/billing/webhook

 ROLLBACK if needed:
      tar -xzf _backups/pre-portal-*.tar.gz -C .
      systemctl restart YOUR_SERVICE

 See INTEGRATION_portal.md for the auth-fix note and deferred features.
────────────────────────────────────────────────────────────────────────
NOTE
