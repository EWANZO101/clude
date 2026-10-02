import json
import re
import secrets
import uuid
from datetime import datetime, timedelta

from flask_login import UserMixin
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from app.extensions import db

_ph = PasswordHasher()


def gen_uuid():
    return str(uuid.uuid4())


def gen_token(nbytes=32):
    return secrets.token_urlsafe(nbytes)


# --- PIN policy ---------------------------------------------------------
# Kept deliberately simple (numeric, fixed length range) so requirements
# are easy to state to a user and to validate consistently client- and
# server-side, rather than a free-text password-strength-style policy.
PIN_MIN_LENGTH = 4
PIN_MAX_LENGTH = 6
PIN_PATTERN = re.compile(r"^\d{4,6}$")

# Preset choices surfaced in the admin PIN-policy UI, in days. "Custom"
# accepts any positive integer of days on top of these.
PIN_EXPIRY_PRESETS_DAYS = {"1m": 30, "3m": 90, "6m": 180, "12m": 365}
DEFAULT_PIN_EXPIRY_DAYS = 90  # 3 months, per spec


def is_valid_pin_format(raw_pin: str) -> bool:
    return bool(PIN_PATTERN.match(raw_pin or ""))


# Roles available within a company. Order = ascending privilege for convenience only;
# actual permission checks go through ROLE_PERMISSIONS below (Part 3/8 will extend this
# into a fully editable AdminRole table, mirroring the kiosk-local Admin Panel pattern).
COMPANY_ROLES = ["owner", "administrator", "manager", "operator"]

# Coarse-grained permission matrix for Part 1/2. Extended in later parts as instance,
# update, and config management endpoints are added.
#
# "operate_kiosk" (added for the Client Portal) is deliberately narrower than
# "manage_instances": start/stop/restart, and managing Items & Tools / Local Kiosk
# Users on an instance the role can already see. It does NOT cover anything that
# changes how the instance is set up or who can reach it (rename, delete, enrollment
# tokens, remote access, running an arbitrary shell command, or editing raw JSON
# config) — those stay behind "manage_instances" / "manage_config". Every role that
# already has manage_instances gets operate_kiosk too, since it's a subset of what
# they could already do — granting it costs them nothing.
#
# "operator" is the Client Portal role: a customer's own staff, logged in to see
# only their own company's instances, with just enough permission to run them day to
# day (operate_kiosk) and push an already-published update to ONE instance at a time
# ("operate_kiosk_updates" — deliberately separate from "manage_updates": that
# permission also unlocks bulk-scheduling across the whole fleet and staged
# rollouts, which stay restricted to owner/administrator, same as before this role
# existed) — never config, enrollment tokens, member management, or company
# settings.
ROLE_PERMISSIONS = {
    "owner": {
        "manage_company", "manage_members", "manage_roles",
        "manage_instances", "manage_config", "manage_updates", "operate_kiosk",
        "view_instances", "view_billing", "manage_billing",
    },
    "administrator": {
        "manage_members",
        "manage_instances", "manage_config", "manage_updates", "operate_kiosk",
        "view_instances",
    },
    "manager": {
        "manage_instances", "manage_config", "operate_kiosk",
        "view_instances",
    },
    "operator": {
        "view_instances", "operate_kiosk", "operate_kiosk_updates",
    },
}


class User(UserMixin, db.Model):
    __tablename__ = "users"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    email_verified = db.Column(db.Boolean, nullable=False, default=False)

    full_name = db.Column(db.String(255), nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)

    is_active = db.Column(db.Boolean, nullable=False, default=True)
    is_platform_admin = db.Column(db.Boolean, nullable=False, default=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    last_login_at = db.Column(db.DateTime, nullable=True)

    # True only for the single synthetic row created by
    # get_client_portal_service_user() below — never a real person, can't
    # log in (is_active is False, password is an unusable random value).
    # Exists purely as a "users.id"-safe FK target for actions a Client
    # Portal account (ClientUser — a completely separate login, see
    # client_portal.py) takes on an instance, since InstanceCommand /
    # UpdateDeployment's requested_by_id columns are NOT NULL foreign keys
    # into this table and a ClientUser's own id must never be written
    # there (different table, colliding id space). Filtered out of
    # platform.list_users so it never shows up as a real account.
    is_service_account = db.Column(db.Boolean, nullable=False, default=False)

    # --- PIN security ---
    # pin_must_change defaults True so existing accounts (created before this
    # feature existed) are treated the same as a brand-new signup: gated
    # into PIN setup on their next request, not silently exempted just
    # because they predate the column. See needs_pin_setup().
    pin_hash = db.Column(db.String(255), nullable=True)
    pin_set_at = db.Column(db.DateTime, nullable=True)
    pin_must_change = db.Column(db.Boolean, nullable=False, default=True)

    memberships = db.relationship(
        "CompanyMembership", back_populates="user", cascade="all, delete-orphan"
    )
    pin_history = db.relationship(
        "UserPinHistory", back_populates="user", cascade="all, delete-orphan",
        order_by="UserPinHistory.created_at.desc()",
    )

    # --- password helpers ---
    def set_password(self, raw_password: str):
        self.password_hash = _ph.hash(raw_password)

    def check_password(self, raw_password: str) -> bool:
        try:
            ok = _ph.verify(self.password_hash, raw_password)
        except VerifyMismatchError:
            return False
        except Exception:
            return False
        if ok and _ph.check_needs_rehash(self.password_hash):
            self.set_password(raw_password)
            db.session.commit()
        return ok

    def get_id(self):
        # Flask-Login identity — use public_id rather than the raw integer PK.
        return self.public_id

    def role_in(self, company_id: int):
        for m in self.memberships:
            if m.company_id == company_id:
                return m.role
        return None

    def has_permission(self, company_id: int, permission: str) -> bool:
        role = self.role_in(company_id)
        if role is None:
            return False
        return permission in ROLE_PERMISSIONS.get(role, set())

    # --- PIN helpers ---
    def needs_pin_setup(self) -> bool:
        """True if the user has never set a PIN, or an admin has reset it
        (pin_must_change) and they need to choose a new one before
        continuing. Distinct from pin_is_expired() — this is "no valid PIN
        exists at all" rather than "one exists but is stale"."""
        return self.pin_hash is None or self.pin_must_change

    def pin_expiry_days_effective(self):
        """The PIN expiry policy that applies to this user: the STRICTEST
        (lowest) pin_expiry_days among every company they belong to, so
        that belonging to one company with a tighter rotation policy can
        never be loosened by also belonging to a more relaxed one. Returns
        None (no expiry enforced) only for a user with no company
        memberships at all, e.g. a platform-admin-only account."""
        days = [
            m.company.pin_expiry_days for m in self.memberships
            if m.company and m.company.pin_expiry_days
        ]
        return min(days) if days else None

    def pin_is_expired(self) -> bool:
        if self.pin_hash is None:
            return False  # no PIN at all is needs_pin_setup()'s job, not this
        expiry_days = self.pin_expiry_days_effective()
        if not expiry_days:
            return False
        if self.pin_set_at is None:
            return True
        return (datetime.utcnow() - self.pin_set_at).days >= expiry_days

    def pin_was_used_before(self, raw_pin: str) -> bool:
        """Checks a candidate PIN against the current PIN and everything in
        this user's PIN history. Deliberately checks ALL history, not just
        the last N, per "must not be allowed to reuse their previous
        PINs" (no "previous N" qualifier given)."""
        if self.pin_hash and self._verify_pin_hash(self.pin_hash, raw_pin):
            return True
        return any(self._verify_pin_hash(h.pin_hash, raw_pin) for h in self.pin_history)

    @staticmethod
    def _verify_pin_hash(pin_hash: str, raw_pin: str) -> bool:
        try:
            return _ph.verify(pin_hash, raw_pin)
        except VerifyMismatchError:
            return False
        except Exception:
            return False

    def check_pin(self, raw_pin: str) -> bool:
        if not self.pin_hash:
            return False
        return self._verify_pin_hash(self.pin_hash, raw_pin)

    def set_pin(self, raw_pin: str):
        """Archives the current PIN hash (if any) into history, then sets
        the new one. Does NOT check pin_was_used_before — callers must do
        that first; this just commits the change once a caller has already
        decided the new PIN is acceptable."""
        if self.pin_hash:
            db.session.add(UserPinHistory(user_id=self.id, pin_hash=self.pin_hash))
        self.pin_hash = _ph.hash(raw_pin)
        self.pin_set_at = datetime.utcnow()
        self.pin_must_change = False

    def companies(self):
        return [m.company for m in self.memberships]

    def __repr__(self):
        return f"<User {self.email}>"


class UserPinHistory(db.Model):
    """Archive of a user's previous PIN hashes, used only to enforce
    "can't reuse a previous PIN" — never used to check the CURRENT PIN
    (that's User.pin_hash / check_pin). Append-only: rows are never
    updated, only inserted (by User.set_pin) and cascade-deleted if the
    user account itself is deleted."""
    __tablename__ = "user_pin_history"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    pin_hash = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    user = db.relationship("User", back_populates="pin_history")


class PlatformSetting(db.Model):
    """Singleton row (id is always 1) for platform-wide toggles that don't
    belong to any one company — whether public self-signup is open, and
    the Client Portal's idle-logout duration. Kept as its own tiny table
    rather than a config file so a platform admin can flip it from the UI
    without a redeploy."""
    __tablename__ = "platform_settings"

    id = db.Column(db.Integer, primary_key=True)
    signups_enabled = db.Column(db.Boolean, nullable=False, default=True)
    # Client Portal only — a ClientUser's session auto-logs-out after this
    # many minutes idle (see client_portal/_base.html's JS). The real
    # kiosk terminal has its own separate setting for the same idea
    # (kiosk_app's AUTO_LOGOUT_MINUTES, pushed per-instance via the
    # existing Configuration panel — see instances.py's set_auto_logout)
    # since it isn't platform-wide, it's one value per kiosk.
    client_portal_auto_logout_minutes = db.Column(db.Integer, nullable=False, default=2)

    @classmethod
    def get(cls):
        row = cls.query.get(1)
        if row is None:
            row = cls(id=1, signups_enabled=True, client_portal_auto_logout_minutes=2)
            db.session.add(row)
            db.session.commit()
        return row


class Company(db.Model):
    __tablename__ = "companies"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    name = db.Column(db.String(255), nullable=False)
    slug = db.Column(db.String(255), unique=True, nullable=False, index=True)

    # Free-text company info fields per spec section 7 ("Enter company information").
    contact_email = db.Column(db.String(255), nullable=True)
    contact_phone = db.Column(db.String(64), nullable=True)
    address = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Update scheduling (Part 5, spec Section 24 priority hierarchy):
    # a company-wide override of the 9PM UK system default. Null = inherit.
    default_update_time = db.Column(db.Time, nullable=True)
    update_countdown_minutes = db.Column(db.Integer, nullable=False, default=15)

    # How often members of this company must set a new PIN (see User PIN
    # helpers above). Company-scoped rather than global so different
    # companies on the same platform can run stricter/looser rotation
    # policies — User.pin_expiry_days_effective() takes the strictest
    # value across all of a user's companies if they belong to more than
    # one.
    pin_expiry_days = db.Column(db.Integer, nullable=False, default=DEFAULT_PIN_EXPIRY_DAYS)

    memberships = db.relationship(
        "CompanyMembership", back_populates="company", cascade="all, delete-orphan"
    )
    invites = db.relationship(
        "CompanyInvite", back_populates="company", cascade="all, delete-orphan"
    )
    instances = db.relationship(
        "Instance", back_populates="company", cascade="all, delete-orphan"
    )
    enrollment_tokens = db.relationship(
        "EnrollmentToken", back_populates="company", cascade="all, delete-orphan"
    )

    def __repr__(self):
        return f"<Company {self.name}>"


PRODUCT_ACCESS_STATUSES = ("pending", "approved", "rejected")
PRODUCT_ACCESS_STATUS_LABELS = {"pending": "Pending", "approved": "Approved", "rejected": "Rejected"}


class Product(db.Model):
    """A distinct system/offering on the platform — the Kiosk System is
    the first one, seeded by migration 008900b88a30's successor (see
    migrations/versions/), but this exists so a completely different
    future product needs nothing more than a new row here plus its own
    blueprint(s) gated by company_has_product() below. Deliberately no
    foreign key anywhere back to kiosk-specific tables (Instance etc.) —
    a Product is just a name or company access is checked against by
    slug; what a product actually *does* lives entirely in its own
    blueprint/templates, unknown to this model."""
    __tablename__ = "products"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)
    # Stable programmatic identifier a blueprint's access-gate checks
    # against (see company_has_product) — never shown to a user, never
    # renamed once other code depends on it. `name`/`description` are the
    # user-facing, freely-editable side of the same row.
    slug = db.Column(db.String(64), unique=True, nullable=False)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_active = db.Column(db.Boolean, nullable=False, default=True)  # inactive = hidden from new requests, not deleted
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def __repr__(self):
        return f"<Product {self.slug}>"


class CompanyProductAccess(db.Model):
    """One company's relationship to one product — no row at all means
    "never requested, no access" (the default for every company from now
    on, per the "companies should not automatically have access to any
    product" requirement); a row's `status` tracks the rest of the
    lifecycle. requested_by_id is null for a row created by an admin's
    direct grant rather than a company's own request."""
    __tablename__ = "company_product_access"
    __table_args__ = (
        db.UniqueConstraint("company_id", "product_id", name="uq_company_product_access"),
    )

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=False)
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), nullable=False)
    status = db.Column(db.String(16), nullable=False, default="pending")

    requested_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    requested_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    note = db.Column(db.Text, nullable=True)  # optional "why we want this" from the company

    decided_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    decided_at = db.Column(db.DateTime, nullable=True)
    decision_note = db.Column(db.Text, nullable=True)

    company = db.relationship("Company")
    product = db.relationship("Product")
    requested_by = db.relationship("User", foreign_keys=[requested_by_id])
    decided_by = db.relationship("User", foreign_keys=[decided_by_id])

    def status_label(self):
        return PRODUCT_ACCESS_STATUS_LABELS.get(self.status, self.status)


def company_has_product(company_id: int, slug: str) -> bool:
    """The single source of truth for "can this company use this product"
    — every product-gated blueprint's before_request hook calls this
    (see instances.py/rollouts.py), and it's exactly as strict as the rows
    in company_product_access: no row, or a row that isn't 'approved',
    both mean no access."""
    return db.session.query(CompanyProductAccess.id).join(
        Product, CompanyProductAccess.product_id == Product.id
    ).filter(
        CompanyProductAccess.company_id == company_id,
        Product.slug == slug,
        CompanyProductAccess.status == "approved",
    ).first() is not None


_KIOSK_PRODUCT_ID_CACHE = {}


def kiosk_product_id() -> int:
    """The 'kiosk' Product row's id — every pre-existing EnrollmentToken/
    Instance has product_id=NULL, meaning kiosk implicitly, but
    UpdatePackage.product_id is NOT NULL (see its own docstring for why),
    so anywhere that needs to compare against 'the kiosk product' by id
    resolves it here rather than hardcoding 1. Cached per-process (this
    row is seeded once by migration e7cf76d928c6 and never changes) to
    avoid a query on every release upload/instance registration."""
    cached = _KIOSK_PRODUCT_ID_CACHE.get("id")
    if cached is not None:
        return cached
    product_id = db.session.query(Product.id).filter_by(slug="kiosk").scalar()
    if product_id is None:
        raise RuntimeError("no 'kiosk' Product row found — expected migration e7cf76d928c6 to have seeded one")
    _KIOSK_PRODUCT_ID_CACHE["id"] = product_id
    return product_id


class CompanyMembership(db.Model):
    """Join table: which role a user holds within a given company."""
    __tablename__ = "company_memberships"
    __table_args__ = (
        db.UniqueConstraint("user_id", "company_id", name="uq_user_company"),
    )

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=False)
    role = db.Column(db.String(32), nullable=False, default="operator")
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    user = db.relationship("User", back_populates="memberships")
    company = db.relationship("Company", back_populates="memberships")


class CompanyInvite(db.Model):
    """Pending invitation for an email address to join a company at a given role."""
    __tablename__ = "company_invites"

    id = db.Column(db.Integer, primary_key=True)
    token = db.Column(db.String(64), unique=True, nullable=False, default=lambda: uuid.uuid4().hex)

    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=False)
    email = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(32), nullable=False, default="operator")

    invited_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    accepted_at = db.Column(db.DateTime, nullable=True)
    revoked = db.Column(db.Boolean, nullable=False, default=False)

    company = db.relationship("Company", back_populates="invites")
    invited_by = db.relationship("User")


# ---------------------------------------------------------------------------
# Part 2: Instances & enrollment tokens
# ---------------------------------------------------------------------------

SUPPORTED_OS = ["ubuntu", "debian", "windows"]

# Coarse connection/lifecycle status as reported by the Instance Agent's heartbeat.
# The richer update-specific state machine (Update Available, Installing, Rolled
# Back, etc. — spec Section 33) is layered on top of this in Part 6.
INSTANCE_STATUSES = ["online", "offline"]


class EnrollmentToken(db.Model):
    """A company-scoped token the Linux install script / Windows MSI uses to
    register a brand-new instance against the right company, without the
    customer ever handling per-instance secrets by hand (spec Section 5/6:
    'require as little manual configuration as possible').
    """
    __tablename__ = "enrollment_tokens"

    id = db.Column(db.Integer, primary_key=True)
    token = db.Column(db.String(64), unique=True, nullable=False, default=lambda: gen_token(24))

    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=False)
    # Which product this token enrolls an instance for. Nullable, meaning
    # "kiosk" — every token created before this column existed stays NULL
    # and keeps registering plain Kiosk instances exactly as before; a new
    # product's token sets this explicitly. See Instance.product_id below
    # for the same convention on the resulting instance.
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), nullable=True)
    label = db.Column(db.String(255), nullable=True)  # e.g. "Branch 2 rollout"

    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    expires_at = db.Column(db.DateTime, nullable=True)  # null = no expiry
    max_uses = db.Column(db.Integer, nullable=True)      # null = unlimited
    use_count = db.Column(db.Integer, nullable=False, default=0)
    revoked = db.Column(db.Boolean, nullable=False, default=False)

    # Distinct from expires_at above, which is when the TOKEN itself stops
    # being usable for new enrollments. This is the licensing term handed
    # to whichever instance registers with it — e.g. a token sold as
    # "1 year" sets that instance's Instance.license_expires_at to
    # registration time + this many days (see agent_api.py::register_instance).
    # Null = the resulting instance never expires on its own (still
    # suspendable by hand from the instance page either way).
    license_duration_days = db.Column(db.Integer, nullable=True)

    company = db.relationship("Company", back_populates="enrollment_tokens")
    created_by = db.relationship("User")
    product = db.relationship("Product")

    def is_valid(self) -> bool:
        if self.revoked:
            return False
        if self.expires_at is not None and datetime.utcnow() > self.expires_at:
            return False
        if self.max_uses is not None and self.use_count >= self.max_uses:
            return False
        return True


class Instance(db.Model):
    """One installed kiosk (Instance Agent + Kiosk Application) as tracked by
    the Admin Panel. Full status/update-state fields are extended in later
    parts; this holds identity, credentials, and basic connection info.
    """
    __tablename__ = "instances"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid, index=True)

    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=False)

    # Which product this instance runs — one Instance is one Agent
    # installation supervising exactly one app, decided once at registration
    # by which EnrollmentToken.product_id was used (see agent_api.py's
    # register_instance). Nullable, meaning "kiosk": every instance
    # registered before this column existed stays NULL and is completely
    # unaffected. For a non-kiosk instance, the columns below named
    # app_version/kiosk_process_status/last_kiosk_* are reused generically
    # for that one product's status — deliberately not renamed (this is a
    # live table), so the naming is a documented quirk, not a bug.
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), nullable=True)

    # Customer-assigned display name (spec Section 7: "Name the instance").
    # Null until the customer sets one in the Admin Panel; falls back to the
    # hostname reported at registration for display purposes.
    name = db.Column(db.String(255), nullable=True)

    hostname = db.Column(db.String(255), nullable=True)
    os = db.Column(db.String(32), nullable=False)
    os_version = db.Column(db.String(128), nullable=True)
    agent_version = db.Column(db.String(32), nullable=True)
    app_version = db.Column(db.String(32), nullable=True)

    # Last Known Good (spec Section 31) — only ever set once a deployment
    # actually passes its health check, never optimistically.
    last_known_good_version = db.Column(db.String(32), nullable=True)

    # Per-instance credential (spec Section 15: "per-instance credentials/identity").
    # The raw secret is shown to the agent exactly once, at registration time —
    # only its hash is stored here.
    secret_hash = db.Column(db.String(255), nullable=False)

    connection_status = db.Column(db.String(16), nullable=False, default="offline")
    last_seen_at = db.Column(db.DateTime, nullable=True)

    local_ip = db.Column(db.String(64), nullable=True)
    public_ip = db.Column(db.String(64), nullable=True)
    port = db.Column(db.Integer, nullable=True)

    tunnel_connected = db.Column(db.Boolean, nullable=False, default=False)
    # running|stopped|not_configured|giving_up|suspended. "suspended" is set
    # directly by suspend_license() below, not reported by the Agent (which
    # can't report anything at all once suspended — see is_licensed()) —
    # it's the one value this column takes on without ever coming from a
    # heartbeat, precisely because a suspended instance's heartbeats are
    # rejected before they'd otherwise overwrite it. reactivate_license()
    # clears it back to None ("no heartbeat yet") rather than guessing.
    kiosk_process_status = db.Column(db.String(16), nullable=True)

    registered_via_token_id = db.Column(db.Integer, db.ForeignKey("enrollment_tokens.id"), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # What the Admin Panel last told this instance's Agent to do via the
    # "configure" command (see instances.py::kiosk_configure) — remembered
    # here purely so that form can pre-fill instead of always rendering
    # blank. Null means "the Admin Panel has never sent a configure command
    # for this instance" (e.g. it's running whatever kiosk_start_command
    # the Agent auto-defaulted locally after an install — see the Instance
    # Agent's update_manager.py::_auto_default_kiosk_command) — NOT the
    # same thing as "nothing is configured to run", which is why the
    # kiosk_configure route requires explicit confirmation before it will
    # submit a blank start command over one of these.
    last_kiosk_start_command = db.Column(db.String(1000), nullable=True)
    last_kiosk_working_dir = db.Column(db.String(500), nullable=True)
    last_kiosk_health_check_url = db.Column(db.String(500), nullable=True)
    last_kiosk_health_check_command = db.Column(db.String(500), nullable=True)
    last_kiosk_inventory_sync_url = db.Column(db.String(500), nullable=True)

    # Update scheduling (Part 5): kiosk-specific override, highest priority
    # below a one-time individual schedule. Null = inherit company/system.
    scheduled_update_time = db.Column(db.Time, nullable=True)

    # Licensing: a platform admin's own on/off switch, independent of
    # whether the Agent is actually reachable. license_status is the
    # manual half ("suspended" always wins regardless of expiry);
    # license_expires_at is the time-based half (None = never expires).
    # Enforced centrally in instance_auth_required (app/instance_auth.py)
    # — every /api/v1/instances/* call an Agent makes checks is_licensed()
    # first, so a suspended/expired instance's Agent starts getting 403s
    # on heartbeat/commands/config/updates/sync alike. The Agent itself
    # (agent/heartbeat.py's run_heartbeat_loop) additionally stops its
    # locally supervised kiosk process on seeing that specific 403 — see
    # that module's own note — so this is a real kill switch, not just a
    # "looks offline in the dashboard" cosmetic state. Only ever set via
    # the instance detail page's License panel (manage_instances-gated),
    # never via the Client Portal.
    license_status = db.Column(db.String(16), nullable=False, default="active")  # "active" | "suspended"
    license_expires_at = db.Column(db.DateTime, nullable=True)

    # Backup schedule (see app/backup_scheduling.py) — one time-of-day +
    # IANA timezone pair governs both halves independently: kiosk_app's own
    # background thread reads backup_time/backup_timezone/
    # backup_local_daily_enabled straight off its applied config (same
    # channel as auto_logout_minutes) to decide when to write a LOCAL
    # backup file, entirely on its own with no Agent/Admin Panel
    # involvement; separately, this Admin Panel uses the same time/tz
    # against backup_cloud_enabled + last_cloud_backup_at (computed
    # entirely server-side, same "is it due yet" philosophy as
    # UpdateDeployment's target_time_utc) to decide when to hand the Agent
    # a backup_now command whose result gets uploaded here. Null time/tz
    # means "no schedule configured yet" — both halves are no-ops until a
    # company sets one from the Client Portal's Backups tab.
    backup_time = db.Column(db.Time, nullable=True)
    backup_timezone = db.Column(db.String(64), nullable=True)
    backup_local_daily_enabled = db.Column(db.Boolean, nullable=False, default=False)
    backup_cloud_enabled = db.Column(db.Boolean, nullable=False, default=False)
    last_cloud_backup_at = db.Column(db.DateTime, nullable=True)

    company = db.relationship("Company", back_populates="instances")
    registered_via_token = db.relationship("EnrollmentToken")
    product = db.relationship("Product")
    configs = db.relationship(
        "InstanceConfig", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceConfig.version.desc()",
    )
    deployments = db.relationship(
        "UpdateDeployment", back_populates="instance", cascade="all, delete-orphan",
        order_by="UpdateDeployment.requested_at.desc()",
    )
    equipment_items = db.relationship(
        "InstanceEquipmentItem", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceEquipmentItem.kind, InstanceEquipmentItem.name",
    )
    local_users = db.relationship(
        "InstanceLocalUser", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceLocalUser.name",
    )
    roles = db.relationship(
        "InstanceRole", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceRole.name",
    )
    item_types = db.relationship(
        "InstanceItemType", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceItemType.name",
    )
    inventory_items = db.relationship(
        "InstanceInventoryItem", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceInventoryItem.name",
    )
    nav_entries = db.relationship(
        "InstanceNavEntry", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceNavEntry.sort_order",
    )
    backups = db.relationship(
        "InstanceBackup", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceBackup.created_at.desc()",
    )

    def set_secret(self, raw_secret: str):
        self.secret_hash = _ph.hash(raw_secret)

    def check_secret(self, raw_secret: str) -> bool:
        try:
            return _ph.verify(self.secret_hash, raw_secret)
        except VerifyMismatchError:
            return False
        except Exception:
            return False

    def display_name(self) -> str:
        return self.name or self.hostname or f"Instance {self.public_id[:8]}"

    def mark_seen(self, **connection_fields):
        self.connection_status = "online"
        self.last_seen_at = datetime.utcnow()
        for key, value in connection_fields.items():
            if value is not None and hasattr(self, key):
                setattr(self, key, value)

    def current_config(self):
        """Most recently applied config, or None if nothing has ever been
        successfully applied."""
        for c in self.configs:
            if c.status == "applied":
                return c
        return None

    def pending_config(self):
        """The newest not-yet-acknowledged config push, if any."""
        for c in self.configs:
            if c.status == "pending":
                return c
        return None

    def active_deployment(self):
        """The deployment currently in flight for this instance, if any
        (spec Section 10: an instance should only ever have one update in
        progress at a time)."""
        for d in self.deployments:
            if d.status in IN_FLIGHT_STATUSES:
                return d
        return None

    def is_licensed(self) -> bool:
        """False blocks every /api/v1/instances/* call this instance's
        Agent makes — see instance_auth_required. Expiry is checked live
        against the current time on every call, not by a background job
        flipping a status, so it takes effect the instant it passes with
        no scheduling lag."""
        if self.license_status == "suspended":
            return False
        if self.license_expires_at is not None and datetime.utcnow() > self.license_expires_at:
            return False
        return True

    def license_display_status(self) -> str:
        """'active' | 'suspended' | 'expired' — for the UI; 'suspended' is
        the manual override, 'expired' is license_expires_at having passed
        on its own. Both mean is_licensed() is False; this just says why."""
        if self.license_status == "suspended":
            return "suspended"
        if self.license_expires_at is not None and datetime.utcnow() > self.license_expires_at:
            return "expired"
        return "active"

    def __repr__(self):
        return f"<Instance {self.public_id} company={self.company_id}>"


# ---------------------------------------------------------------------------
# Kiosk-attached equipment: items & tools
# ---------------------------------------------------------------------------
# "Items" and "tools" attached to / used by a specific kiosk instance — e.g.
# a barcode scanner, receipt printer, card reader, cash drawer. Kept as one
# table with a `kind` discriminator rather than two separate tables since
# both share every field and only differ in how an admin categorizes them;
# splitting would just be duplicated CRUD/import/export/backup code for no
# real behavioral difference.

EQUIPMENT_KINDS = ["item", "tool"]
EQUIPMENT_STATUSES = ["active", "inactive"]
EQUIPMENT_CSV_FIELDS = ["kind", "name", "description", "serial_number", "status", "category"]

# Real Kiosk App inventory sync (see kiosk_app/app/models.py's Item/Tool and
# app/blueprints/agent_api.py's equipment sync endpoints): these live
# alongside the fields above rather than replacing them, since "status"
# here means something different per kind once a kiosk_app counterpart
# exists — "active/inactive" is this equipment record's own on/off state
# (unchanged, always meaningful), while a Tool's real-world checkout state
# ("available"/"checked_out"/"maintenance", driven by what actually
# happens at the kiosk terminal) is its own separate field, not a
# replacement for it. Most of the columns below are only ever populated
# for one kind (see the inline notes) — nullable and simply unused for
# the other, same reasoning EQUIPMENT_KINDS itself gives for one shared
# table over two.
EQUIPMENT_CATEGORIES = ["consumable", "ppe"]  # suggested defaults only — see category's own note
TOOL_STATUSES = ["available", "checked_out", "maintenance"]  # kind == "tool" only


class InstanceEquipmentItem(db.Model):
    __tablename__ = "instance_equipment_items"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    kind = db.Column(db.String(8), nullable=False, default="item")  # "item" | "tool"

    name = db.Column(db.String(255), nullable=False)
    description = db.Column(db.Text, nullable=True)
    serial_number = db.Column(db.String(128), nullable=True)
    status = db.Column(db.String(16), nullable=False, default="active")  # "active" | "inactive"

    # --- Kiosk App sync fields (nullable — populated once a synced kiosk_app
    # Item/Tool exists; blank until then, e.g. for a company with no real
    # Kiosk App installed yet) ---
    sku = db.Column(db.String(64), nullable=True)                       # item: kiosk_app Item.sku
    quantity = db.Column(db.Integer, nullable=True)                     # item: kiosk_app Item.quantity
    unit = db.Column(db.String(32), nullable=True)                     # item: kiosk_app Item.unit
    # Freeform "type" label used two ways: (1) synced up/down as kiosk_app
    # Item.category on kind=="item" rows (kiosk_app itself only recognizes
    # "consumable"/"ppe" there — see its own sync_api.py — so any other
    # value just won't be adopted kiosk-side, no error); (2) on EITHER
    # kind, purely Admin-Panel-local grouping for the Items & Tools
    # accordion (see instances.py's _group_equipment_by_category) — a
    # Tool's category never syncs anywhere, it only organizes this view.
    category = db.Column(db.String(64), nullable=True)
    unit_cost = db.Column(db.Float, nullable=True)                      # item: kiosk_app Item.unit_cost
    tool_status = db.Column(db.String(16), nullable=True)               # tool: kiosk_app Tool.status
    checked_out_by_name = db.Column(db.String(255), nullable=True)      # tool: kiosk_app Tool.checked_out_by_name
    current_project = db.Column(db.String(255), nullable=True)          # tool: kiosk_app Tool.current_project
    purchase_price = db.Column(db.Float, nullable=True)                 # tool: kiosk_app Tool.purchase_price
    # kiosk_app-assigned on either kind (Item.barcode_code / Tool.barcode_code)
    # — always generated kiosk-side, synced up here for display/export only.
    barcode_code = db.Column(db.String(32), nullable=True)

    # Soft-delete tombstone: sync needs "this was deleted" to actually reach
    # the other side rather than being silently un-creatable there — a hard
    # delete here would just look like "never existed" to a Kiosk App that
    # hasn't polled since, which would re-create it right back. See
    # equipment_items()/kind-scoped queries below and the delete routes in
    # instances.py / client_portal.py, which set this instead of deleting.
    deleted_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    added_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    instance = db.relationship("Instance", back_populates="equipment_items")
    added_by = db.relationship("User")

    def to_csv_row(self) -> dict:
        return {
            "kind": self.kind, "name": self.name, "description": self.description or "",
            "serial_number": self.serial_number or "", "status": self.status,
            "category": self.category or "",
        }

    def to_backup_dict(self) -> dict:
        return {
            "kind": self.kind, "name": self.name, "description": self.description,
            "serial_number": self.serial_number, "status": self.status, "category": self.category,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }

    def to_sync_dict(self) -> dict:
        """The shape sent to/received from the Kiosk App's own sync API
        (kiosk_app's Item.to_dict()/Tool equivalent, extended with the
        public_id/updated_at/deleted_at every synced record carries — see
        agent/inventory_sync.py, the only code that reads this on the wire)."""
        return {
            "public_id": self.public_id, "name": self.name, "description": self.description,
            "status": self.status, "sku": self.sku, "quantity": self.quantity, "unit": self.unit,
            "category": self.category, "unit_cost": self.unit_cost, "tool_status": self.tool_status,
            "checked_out_by_name": self.checked_out_by_name, "current_project": self.current_project,
            "purchase_price": self.purchase_price, "barcode_code": self.barcode_code,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else None,
        }


# ---------------------------------------------------------------------------
# Local kiosk users — the people who actually operate a specific kiosk
# terminal day-to-day, distinct from the web dashboard's User/
# CompanyMembership accounts (fleet managers who log into the Admin Panel
# itself). Two-way synced with kiosk_app's own LocalUser (its real login
# accounts — see username/role/badge_code below and
# agent/inventory_sync.py) once a real Kiosk App is installed; managed
# here regardless so an admin/client can set this up remotely without
# touching the physical machine, same as before a synced counterpart
# exists. PIN handling deliberately mirrors User's (same hashing, same
# no-reuse-via-history rule, same shared Company.pin_expiry_days policy).
# ---------------------------------------------------------------------------

LOCAL_USER_STATUSES = ["active", "inactive"]

# Matches kiosk_app's own SIDEBAR_ITEMS exactly (app/models.py there) —
# duplicated rather than imported, per OWNERSHIP.md: the Admin Panel must
# never import from kiosk_app/. Only the keys are needed here (to render
# one checkbox per item on the role sidebar-visibility form); labels/
# sections stay a kiosk_app-only display concern.
SIDEBAR_ITEM_KEYS = [
    "items", "items_low_stock", "tools", "tools_economics", "tools_alerts",
    "wire", "wire_bulk_add", "wire_reporting", "projects", "scan", "stock_audit",
    "inventory_manage",
]

# Matches kiosk_app's own ROLES exactly (app/models.py there) — duplicated
# rather than imported, per OWNERSHIP.md: the Admin Panel must never import
# from kiosk_app/. Least-privileged first so a blank/omitted role defaults
# sensibly.
LOCAL_USER_ROLES = ["stock_user", "supervisor", "admin", "super_admin"]


class ScanToken(db.Model):
    """A read-only, no-login link scoped to exactly one instance's equipment
    barcodes — "anyone with this URL can look up what a scanned code is on
    this one instance", nothing more. Deliberately much narrower than
    EnrollmentToken (which can register a brand-new device): this can never
    create, edit, or delete anything, only look up an InstanceEquipmentItem
    by barcode_code. Powers the phone-camera / physical-scanner mini app at
    /scan/<token> (see app/blueprints/scan_portal.py) — lets a warehouse
    phone or a USB/Bluetooth scanner (which just "types" the code + Enter,
    same as a keyboard) work with zero setup and zero staff login."""
    __tablename__ = "scan_tokens"

    id = db.Column(db.Integer, primary_key=True)
    token = db.Column(db.String(64), unique=True, nullable=False, default=lambda: gen_token(24))

    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    label = db.Column(db.String(255), nullable=True)  # e.g. "Warehouse floor phone"

    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    revoked = db.Column(db.Boolean, nullable=False, default=False)
    last_used_at = db.Column(db.DateTime, nullable=True)
    use_count = db.Column(db.Integer, nullable=False, default=0)

    instance = db.relationship("Instance")
    created_by = db.relationship("User")

    def is_valid(self) -> bool:
        return not self.revoked


class InstanceLocalUser(db.Model):
    __tablename__ = "instance_local_users"
    __table_args__ = (
        # Partial index, not a plain UniqueConstraint: a removed local user
        # (deleted_at set) must free up its username for reuse — a plain
        # constraint would keep it permanently reserved by a soft-deleted
        # row nobody can see anymore, silently blocking "remove Jamie, add
        # a new Jamie" with a confusing collision. Only rows that are
        # still actually visible (deleted_at IS NULL) compete for a
        # username; see the matching deleted_at.is_(None) filter on every
        # clash-check query below and in agent_api.py.
        db.Index(
            "uq_instance_local_user_username", "instance_id", "username",
            unique=True, sqlite_where=db.text("deleted_at IS NULL"),
        ),
    )

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    name = db.Column(db.String(255), nullable=False)
    status = db.Column(db.String(16), nullable=False, default="active")  # "active" | "inactive"

    # --- Kiosk App sync fields (nullable — blank until a synced kiosk_app
    # LocalUser exists for this row; see InstanceEquipmentItem above for the
    # same reasoning) ---
    username = db.Column(db.String(80), nullable=True)                  # kiosk_app LocalUser.username
    role = db.Column(db.String(32), nullable=True, default="stock_user")  # kiosk_app LocalUser.role
    badge_code = db.Column(db.String(32), nullable=True)                # kiosk-assigned, synced up only

    deleted_at = db.Column(db.DateTime, nullable=True)  # soft-delete tombstone — see InstanceEquipmentItem

    pin_hash = db.Column(db.String(255), nullable=True)
    pin_set_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    added_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    instance = db.relationship("Instance", back_populates="local_users")
    added_by = db.relationship("User")
    pin_history = db.relationship(
        "InstanceLocalUserPinHistory", back_populates="local_user", cascade="all, delete-orphan",
        order_by="InstanceLocalUserPinHistory.created_at.desc()",
    )

    def to_sync_dict(self) -> dict:
        """The shape sent to/received from the Kiosk App's own sync API —
        see agent/inventory_sync.py. `pin_hash` travels as-is: both sides
        hash with the same argon2 scheme (User/InstanceLocalUser here,
        LocalUser.set_password there), so a PIN set remotely becomes a
        real login password at the terminal, layered on top of kiosk_app's
        own badge/username-only default — never the raw PIN itself."""
        return {
            "public_id": self.public_id, "name": self.name, "status": self.status,
            "username": self.username, "role": self.role, "badge_code": self.badge_code,
            "pin_hash": self.pin_hash,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else None,
        }

    def pin_expiry_days_effective(self):
        """Same policy as the kiosk's own company — see
        User.pin_expiry_days_effective() for why this lives on Company
        rather than being configured per-user."""
        return self.instance.company.pin_expiry_days if self.instance and self.instance.company else None

    def pin_is_expired(self) -> bool:
        if self.pin_hash is None:
            return False
        days = self.pin_expiry_days_effective()
        if not days:
            return False
        if self.pin_set_at is None:
            return True
        return (datetime.utcnow() - self.pin_set_at).days >= days

    def pin_was_used_before(self, raw_pin: str) -> bool:
        if self.pin_hash and self._verify_pin_hash(self.pin_hash, raw_pin):
            return True
        return any(self._verify_pin_hash(h.pin_hash, raw_pin) for h in self.pin_history)

    @staticmethod
    def _verify_pin_hash(pin_hash: str, raw_pin: str) -> bool:
        try:
            return _ph.verify(pin_hash, raw_pin)
        except VerifyMismatchError:
            return False
        except Exception:
            return False

    def check_pin(self, raw_pin: str) -> bool:
        if not self.pin_hash:
            return False
        return self._verify_pin_hash(self.pin_hash, raw_pin)

    def set_pin(self, raw_pin: str):
        if self.pin_hash:
            db.session.add(InstanceLocalUserPinHistory(local_user_id=self.id, pin_hash=self.pin_hash))
        self.pin_hash = _ph.hash(raw_pin)
        self.pin_set_at = datetime.utcnow()


# ---------------------------------------------------------------------------
# Roles — a read-only cache of kiosk_app's own Role/RolePermission/
# RoleSidebarPermission tables (see kiosk_app/app/role_admin.py), refreshed
# each agent/inventory_sync.py pass via GET /api/sync/roles. Roles
# themselves are edited through the InstanceCommand channel (role_create/
# role_delete/role_set_login/role_set_sidebar — see
# app/blueprints/instances.py's role routes and agent/commands.py), not by
# writing to this table directly from a human-facing route: it's a
# display cache, replaced wholesale each refresh (delete-all + insert-
# fresh for the instance — roles are few, and this is read-only cached
# state, not something that needs per-row last-write-wins merge logic the
# way Items/Tools/Local Users do).
# ---------------------------------------------------------------------------

class InstanceRole(db.Model):
    __tablename__ = "instance_roles"
    __table_args__ = (
        db.UniqueConstraint("instance_id", "name", name="uq_instance_role_name"),
    )

    id = db.Column(db.Integer, primary_key=True)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    name = db.Column(db.String(32), nullable=False)
    is_builtin = db.Column(db.Boolean, nullable=False, default=False)
    user_count = db.Column(db.Integer, nullable=False, default=0)
    login_enabled = db.Column(db.Boolean, nullable=False, default=True)
    sidebar_json = db.Column(db.Text, nullable=True)  # {"items": true, "wire": false, ...}
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)

    instance = db.relationship("Instance")

    def sidebar(self) -> dict:
        try:
            return json.loads(self.sidebar_json) if self.sidebar_json else {}
        except ValueError:
            return {}


# ---------------------------------------------------------------------------
# Generic inventory type system (Track 2 of
# /root/.claude/plans/sprightly-meandering-whisper.md) — new tables only,
# additive. InstanceEquipmentItem and everything built on it (instances.py's
# Items & Tools section, client_portal.py's mirror, the equipment sync
# routes in agent_api.py) are left completely untouched here; nothing reads
# or writes these tables yet. Duplicated shape from kiosk_app/app/models.py's
# own ItemType/ItemTypeField/InventoryItem/InventoryItemEvent/NavEntry per
# OWNERSHIP.md (never import across systems) — unlike InstanceRole's
# read-only cache, InstanceItemType/InstanceItemTypeField/
# InstanceInventoryItem/InstanceInventoryItemEvent carry their own
# updated_at/deleted_at because Phase B's sync protocol v2 lets a type or
# item be created/edited from *either* side, same last-write-wins discipline
# InstanceEquipmentItem already uses today. InstanceNavEntry stays a
# read-only cache like InstanceRole (kiosk is the source of truth for nav
# layout — see the plan's sidebar builder section).
# ---------------------------------------------------------------------------

class InstanceItemType(db.Model):
    __tablename__ = "instance_item_types"
    __table_args__ = (
        db.UniqueConstraint("instance_id", "key", name="uq_instance_item_type_key"),
    )

    id = db.Column(db.Integer, primary_key=True)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    key = db.Column(db.String(64), nullable=False)
    name = db.Column(db.String(255), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_builtin = db.Column(db.Boolean, nullable=False, default=False)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    deleted_at = db.Column(db.DateTime, nullable=True)

    instance = db.relationship("Instance", back_populates="item_types")
    fields = db.relationship(
        "InstanceItemTypeField", back_populates="item_type", cascade="all, delete-orphan",
        order_by="InstanceItemTypeField.sort_order",
    )

    def to_sync_dict(self) -> dict:
        """Sync protocol v2 shape (agent/inventory_sync.py, both directions)
        — mirrors kiosk_app ItemType.to_sync_dict() field-for-field."""
        return {
            "key": self.key, "name": self.name, "description": self.description,
            "is_builtin": self.is_builtin,
            "fields": [f.to_sync_dict() for f in self.fields],
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else None,
        }


class InstanceItemTypeField(db.Model):
    __tablename__ = "instance_item_type_fields"

    id = db.Column(db.Integer, primary_key=True)
    instance_item_type_id = db.Column(db.Integer, db.ForeignKey("instance_item_types.id"), nullable=False)
    key = db.Column(db.String(64), nullable=False)
    label = db.Column(db.String(255), nullable=False)
    field_type = db.Column(db.String(32), nullable=False, default="text")
    options_json = db.Column(db.Text, nullable=True)
    required = db.Column(db.Boolean, nullable=False, default=False)
    sort_order = db.Column(db.Integer, nullable=False, default=0)

    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    deleted_at = db.Column(db.DateTime, nullable=True)

    item_type = db.relationship("InstanceItemType", back_populates="fields")

    def options(self) -> list:
        try:
            return json.loads(self.options_json) if self.options_json else []
        except ValueError:
            return []

    def to_sync_dict(self) -> dict:
        return {
            "key": self.key, "label": self.label, "field_type": self.field_type,
            "options": self.options(), "required": self.required, "sort_order": self.sort_order,
        }


class InstanceInventoryItem(db.Model):
    __tablename__ = "instance_inventory_items"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    item_type_key = db.Column(db.String(64), nullable=False)

    name = db.Column(db.String(255), nullable=False)
    sku = db.Column(db.String(64), nullable=True)
    serial_number = db.Column(db.String(128), nullable=True)
    status = db.Column(db.String(16), nullable=False, default="active")

    quantity_value = db.Column(db.Float, nullable=True)
    quantity_unit = db.Column(db.String(16), nullable=True)

    custom_fields = db.Column(db.Text, nullable=True)

    barcode_code = db.Column(db.String(32), nullable=True)
    checked_out_by_name = db.Column(db.String(255), nullable=True)
    current_project = db.Column(db.String(255), nullable=True)

    deleted_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)
    added_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    instance = db.relationship("Instance", back_populates="inventory_items")
    added_by = db.relationship("User")
    events = db.relationship(
        "InstanceInventoryItemEvent", back_populates="item", cascade="all, delete-orphan",
        order_by="InstanceInventoryItemEvent.occurred_at.desc()",
    )

    def custom_fields_dict(self) -> dict:
        try:
            return json.loads(self.custom_fields) if self.custom_fields else {}
        except ValueError:
            return {}

    def to_sync_dict(self) -> dict:
        return {
            "public_id": self.public_id, "item_type_key": self.item_type_key, "name": self.name,
            "sku": self.sku, "serial_number": self.serial_number, "status": self.status,
            "quantity_value": self.quantity_value, "quantity_unit": self.quantity_unit,
            "custom_fields": self.custom_fields_dict(),
            "barcode_code": self.barcode_code,
            "checked_out_by_name": self.checked_out_by_name, "current_project": self.current_project,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
            "deleted_at": self.deleted_at.isoformat() if self.deleted_at else None,
        }


class InstanceInventoryItemEvent(db.Model):
    __tablename__ = "instance_inventory_item_events"

    id = db.Column(db.Integer, primary_key=True)
    item_id = db.Column(db.Integer, db.ForeignKey("instance_inventory_items.id"), nullable=False)

    event_type = db.Column(db.String(32), nullable=False)
    actor = db.Column(db.String(255), nullable=True)
    project = db.Column(db.String(255), nullable=True)

    occurred_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    resolved_at = db.Column(db.DateTime, nullable=True)
    outcome = db.Column(db.String(32), nullable=True)
    detail = db.Column(db.Text, nullable=True)

    item = db.relationship("InstanceInventoryItem", back_populates="events")


class InstanceNavEntry(db.Model):
    """Read-only cache of kiosk_app's own NavEntry table, refreshed each
    agent/inventory_sync.py pass via GET /api/sync/sidebar — same
    replace-wholesale-each-refresh pattern InstanceRole already uses, since
    kiosk_app remains the source of truth for nav layout (edited through
    the InstanceCommand channel's sidebar_reorder, not by writing here
    directly from a human-facing route)."""
    __tablename__ = "instance_nav_entries"
    __table_args__ = (
        db.UniqueConstraint("instance_id", "key", name="uq_instance_nav_entry_key"),
    )

    id = db.Column(db.Integer, primary_key=True)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    key = db.Column(db.String(80), nullable=False)
    label = db.Column(db.String(255), nullable=False)
    section = db.Column(db.String(64), nullable=False)
    is_builtin = db.Column(db.Boolean, nullable=False, default=False)
    sort_order = db.Column(db.Integer, nullable=False, default=0)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)

    instance = db.relationship("Instance", back_populates="nav_entries")


class InstanceLocalUserPinHistory(db.Model):
    __tablename__ = "instance_local_user_pin_history"

    id = db.Column(db.Integer, primary_key=True)
    local_user_id = db.Column(db.Integer, db.ForeignKey("instance_local_users.id"), nullable=False)
    pin_hash = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    local_user = db.relationship("InstanceLocalUser", back_populates="pin_history")


# ---------------------------------------------------------------------------
# Part 3: Remote configuration (spec Section 11)
# ---------------------------------------------------------------------------

CONFIG_STATUSES = ["pending", "applied", "failed", "rejected"]


class InstanceConfig(db.Model):
    """One version of an instance's remote configuration. Versioned/append-only
    per spec Section 11 ("Configuration should have versioning/history where
    practical") — editing config never overwrites a row, it creates a new one.
    """
    __tablename__ = "instance_configs"
    __table_args__ = (
        db.UniqueConstraint("instance_id", "version", name="uq_instance_config_version"),
    )

    id = db.Column(db.Integer, primary_key=True)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    version = db.Column(db.Integer, nullable=False)

    config_json = db.Column(db.Text, nullable=False)  # JSON object, validated on write

    pushed_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    pushed_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Lifecycle: pending (sent, not yet acknowledged) -> applied | failed | rejected.
    # "rejected" = agent validated it and refused (spec Section 11 step 2 "Validate it");
    # "failed" = agent accepted validation but couldn't apply/restart successfully.
    status = db.Column(db.String(16), nullable=False, default="pending")
    acknowledged_at = db.Column(db.DateTime, nullable=True)
    agent_message = db.Column(db.Text, nullable=True)  # free-text result/error from the agent

    instance = db.relationship("Instance", back_populates="configs")
    pushed_by = db.relationship("User")

    def __repr__(self):
        return f"<InstanceConfig instance={self.instance_id} v{self.version} {self.status}>"


# ---------------------------------------------------------------------------
# Part 4: Update packages (spec Sections 16-19, 49) — release management.
#
# Uploading/validating a new software release is an OpsLab Systems (platform)
# action, not a customer/company action — distinct from company roles above.
# Gated by User.is_platform_admin rather than any CompanyMembership role.
# Pushing an already-validated release to specific instances/companies is a
# company-level action and belongs to Part 5 (update scheduling).
# ---------------------------------------------------------------------------

PACKAGE_STATUSES = ["uploaded", "validated", "invalid"]


class UpdatePackage(db.Model):
    __tablename__ = "update_packages"
    __table_args__ = (
        # Version only needs to be unique WITHIN a product now, not
        # platform-wide — every pre-existing row is backfilled to the
        # "kiosk" product (see migration), so this composite constraint
        # enforces exactly the same real-world guarantee kiosk releases had
        # under the old plain unique(version), while letting a second
        # product number its own releases independently starting at 1.0.0.
        db.UniqueConstraint("product_id", "version", name="uq_update_packages_product_id_version"),
    )

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    # NOT NULL (unlike EnrollmentToken/Instance's product_id) — every
    # existing row is backfilled to the kiosk Product's id by the migration
    # that added this column, since a nullable product_id here would defeat
    # the uniqueness constraint above (SQLite treats each NULL as distinct).
    product_id = db.Column(db.Integer, db.ForeignKey("products.id"), nullable=False)

    version = db.Column(db.String(32), nullable=False)
    release_notes = db.Column(db.Text, nullable=True)

    # Comma-separated subset of SUPPORTED_OS this package applies to, taken
    # from update.json inside the ZIP (spec Section 18: "Operating system
    # compatibility" check).
    supported_os = db.Column(db.String(128), nullable=False, default="")

    file_path = db.Column(db.String(512), nullable=False)   # on-disk path, never served raw
    file_size = db.Column(db.Integer, nullable=False)
    checksum_sha256 = db.Column(db.String(64), nullable=False)

    status = db.Column(db.String(16), nullable=False, default="uploaded")
    validation_log = db.Column(db.Text, nullable=True)  # newline-joined errors/notes

    # Newline-joined listing of every file this zip actually contained at
    # upload/re-validation time (see update_validation.format_file_listing) —
    # shown as "Package contents" on the detail page, alongside
    # validation_log, so a failed upload can be debugged without downloading
    # and unzipping it by hand to see what was inside.
    file_listing = db.Column(db.Text, nullable=True)

    has_rescue_component = db.Column(db.Boolean, nullable=False, default=False)

    uploaded_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    uploaded_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Soft-disable rather than delete — spec Section 49 wants release history
    # to remain visible ("Deployment status") even for withdrawn packages.
    withdrawn = db.Column(db.Boolean, nullable=False, default=False)

    uploaded_by = db.relationship("User")
    product = db.relationship("Product")

    def supported_os_list(self):
        return [s for s in self.supported_os.split(",") if s]

    def is_usable(self) -> bool:
        return self.status == "validated" and not self.withdrawn

    def delete_blocking_reason(self):
        """None if this package is safe to hard-delete, otherwise a
        human-readable reason it can't be. Deletion is only safe when
        nothing else in the system points at this row: no UpdateDeployment
        history (deleting would orphan those rows / lose the audit trail —
        spec Section 49 wants release history to remain visible) and no
        Instance currently reporting this version as its running or
        last-known-good version. A package that's just sitting there unused
        (e.g. an accidental upload) is always safe to remove; use Withdraw
        instead of Delete for a version that has real deployment history."""
        deployment_count = UpdateDeployment.query.filter_by(package_id=self.id).count()
        if deployment_count:
            return (
                f"This version has been pushed to {deployment_count} instance"
                f"{'s' if deployment_count != 1 else ''} — deleting it would break that "
                f"deployment history. Withdraw it instead to stop it being pushed further."
            )
        live = Instance.query.filter(
            db.or_(
                Instance.app_version == self.version,
                Instance.last_known_good_version == self.version,
            )
        ).all()
        if live:
            names = ", ".join(i.display_name() for i in live[:5])
            more = f" and {len(live) - 5} more" if len(live) > 5 else ""
            return f"Currently reported by instance(s) {names}{more} — can't delete a version that's live."
        return None

    def __repr__(self):
        return f"<UpdatePackage {self.version} {self.status}>"


# ---------------------------------------------------------------------------
# Part 5: Update scheduling (spec Sections 20-27)
# ---------------------------------------------------------------------------

# Kept deliberately small for Part 5 — the full state machine (Downloading,
# Installing, Health Check, Rolled Back, ...) from spec Section 33 lands in
# Part 6. This part only tracks whether a scheduled push is still pending,
# was cancelled, or was superseded by a newer one before it fired.
# Full deployment lifecycle (spec Sections 28-33). scheduled/cancelled/superseded
# were Part 5's set; Part 6 adds the states an Instance Agent actually reports as
# it downloads, validates, installs, restarts, and health-checks a real update,
# plus the automatic-rollback path (spec Section 29).
DEPLOYMENT_STATUSES = [
    "scheduled", "cancelled", "superseded",
    "waiting", "downloading", "validating", "preparing", "installing",
    "restarting", "health_check",
    "successful", "failed", "rolling_back", "rolled_back",
]

# States where the deployment is still doing something — used to find "the"
# active deployment for an instance and to gate package downloads.
# Deliberately does NOT include "failed": every path that reports "failed"
# has already finished everything it's going to do for that agent run (a
# rollback attempt, if any, happens synchronously in the same
# run_update_cycle call before the status is ever reported) - nothing comes
# back later to move a "failed" deployment further on its own. Treating it
# as still in-flight anyway made a permanently-failed rollback (like a
# first-ever install with nothing to roll back to) block every future push
# to that instance forever, with no legal transition ("failed" only allows
# -> "rolling_back") that could ever get it unstuck. A fresh push is
# exactly the correct next step after a failure, not something that should
# be blocked pending a retry that was never going to happen.
IN_FLIGHT_STATUSES = [
    "scheduled", "waiting", "downloading", "validating", "preparing",
    "installing", "restarting", "health_check", "rolling_back",
]
TERMINAL_STATUSES = ["successful", "failed", "rolled_back", "cancelled", "superseded"]

# Forward-only state machine. A status transition not listed here is rejected
# (spec Section 31: "A failed update should never overwrite the Last Known
# Good information before the new version has passed its health checks" —
# enforced structurally by only allowing 'successful' after 'health_check').
ALLOWED_TRANSITIONS = {
    "scheduled": {"waiting", "cancelled", "superseded"},
    "waiting": {"downloading", "cancelled", "superseded"},
    "downloading": {"validating", "failed"},
    "validating": {"preparing", "failed"},
    "preparing": {"installing", "failed"},
    "installing": {"restarting", "failed"},
    "restarting": {"health_check", "failed"},
    # A failed health check triggers the Agent's automatic rollback in the
    # same run (agent/update_manager.py::_attempt_rollback) *before* it ever
    # reports "failed" — so the very next status report after "health_check"
    # is "rolling_back", not "failed". Without this, that report is rejected
    # (409) as an illegal transition, the deployment gets stuck showing
    # "Health Check" forever even after the Agent has already rolled the
    # instance back locally, and every later "rolled_back"/"failed" report
    # for the same deployment is rejected too (the server never left
    # "health_check").
    "health_check": {"successful", "failed", "rolling_back"},
    "failed": {"rolling_back"},
    # A rollback attempt can itself fail or be interrupted (e.g. the Agent
    # restarts mid-restore) — without this, a broken rollback had no legal
    # status left to report and would stay stuck forever, the exact same
    # failure mode this transition table exists to prevent everywhere else.
    "rolling_back": {"rolled_back", "failed"},
}

# How the target_time was decided, per the spec Section 24 priority hierarchy
# (most specific wins): system_default -> company -> kiosk -> individual.
SCHEDULE_SOURCES = ["system_default", "company", "kiosk", "individual", "now"]


class UpdateDeployment(db.Model):
    """One instruction to update a specific instance to a specific package,
    at a specific (UTC) time. Created by 'Push Update' (spec Section 27) —
    one row per targeted instance even for a bulk/company-wide push, so one
    instance failing never blocks the others (spec Section 41).
    """
    __tablename__ = "update_deployments"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    package_id = db.Column(db.Integer, db.ForeignKey("update_packages.id"), nullable=False)

    requested_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    requested_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Always stored in UTC; resolved from the priority hierarchy (or "now",
    # or an explicit custom one-time pick) at the moment the push was made.
    target_time_utc = db.Column(db.DateTime, nullable=False)
    schedule_source = db.Column(db.String(16), nullable=False)

    status = db.Column(db.String(20), nullable=False, default="scheduled")
    cancelled_at = db.Column(db.DateTime, nullable=True)
    cancelled_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)

    # Lifecycle tracking (Part 6, spec Sections 28-34).
    started_at = db.Column(db.DateTime, nullable=True)      # first non-scheduled/waiting transition
    completed_at = db.Column(db.DateTime, nullable=True)    # successful or rolled_back

    health_check_passed = db.Column(db.Boolean, nullable=True)
    health_check_message = db.Column(db.Text, nullable=True)

    # Version the instance was running before this deployment started —
    # snapshotted at push time so a rollback always has somewhere concrete to
    # go back to, independent of whatever Instance.app_version says later
    # (spec Section 19: "should not be stored only inside the files being
    # replaced by the update").
    previous_version = db.Column(db.String(32), nullable=True)
    rollback_reason = db.Column(db.Text, nullable=True)

    status_log = db.Column(db.Text, nullable=True)  # newline-joined "status @ timestamp: message"

    instance = db.relationship("Instance", back_populates="deployments")
    package = db.relationship("UpdatePackage")
    requested_by = db.relationship("User", foreign_keys=[requested_by_id])
    cancelled_by = db.relationship("User", foreign_keys=[cancelled_by_id])

    def append_log(self, status: str, message: str = None):
        line = f"{status} @ {datetime.utcnow().isoformat()}Z"
        if message:
            line += f": {message}"
        self.status_log = (self.status_log + "\n" + line) if self.status_log else line

    def __repr__(self):
        return f"<UpdateDeployment instance={self.instance_id} pkg={self.package_id} {self.status}>"


# ---------------------------------------------------------------------------
# Part 8: Remote access tokens + audit log (spec Sections 14-15)
# ---------------------------------------------------------------------------

class RemoteAccessToken(db.Model):
    """A short-lived token authorizing a staff member to open a specific
    instance's local kiosk UI through the outbound remote tunnel (spec
    Section 14). This only issues/tracks the token — the tunnel server
    itself that actually proxies the connection isn't built yet (noted in
    the progress file), so 'used'/'expires_at' here describe intent that a
    future tunnel component would enforce.
    """
    __tablename__ = "remote_access_tokens"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)
    token = db.Column(db.String(64), unique=True, nullable=False, default=lambda: gen_token(24))

    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    requested_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    expires_at = db.Column(db.DateTime, nullable=False)

    used = db.Column(db.Boolean, nullable=False, default=False)
    used_at = db.Column(db.DateTime, nullable=True)
    revoked = db.Column(db.Boolean, nullable=False, default=False)

    # Set once the Agent's tunnel poll loop (agent/tunnel.py) actually sees
    # and responds to this request — 'pending' until then. The Agent-side
    # tunnel client is a deliberate stub (no broker exists yet), so
    # 'unsupported' is the expected real-world outcome for now; 'connected'
    # is reserved for once a real tunnel broker exists on this side.
    status = db.Column(db.String(16), nullable=False, default="pending")
    status_message = db.Column(db.Text, nullable=True)

    instance = db.relationship("Instance")
    requested_by = db.relationship("User")

    def is_valid(self) -> bool:
        if self.revoked or self.used:
            return False
        return datetime.utcnow() <= self.expires_at


class AgentErrorReport(db.Model):
    """ERROR/CRITICAL-level log events shipped by an Instance Agent's
    error_reporter.py (its own spec Section 2.2 line item). Best-effort and
    fire-and-forget on the Agent side — it never retries or blocks on this,
    so treat rows here as 'what the Agent managed to tell us', not a
    complete log. Kept as its own flat table (mirrors AuditLogEntry's
    pattern) rather than folded into the audit log, since these describe
    Agent-side failures, not admin-initiated actions."""
    __tablename__ = "agent_error_reports"

    id = db.Column(db.Integer, primary_key=True)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)

    level = db.Column(db.String(16), nullable=False)
    logger_name = db.Column(db.String(128), nullable=True)
    message = db.Column(db.Text, nullable=False)
    traceback = db.Column(db.Text, nullable=True)
    suppressed_since_last = db.Column(db.Integer, nullable=False, default=0)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    instance = db.relationship("Instance")

    def __repr__(self):
        return f"<AgentErrorReport instance={self.instance_id} {self.level}>"


class AuditLogEntry(db.Model):
    """Who did what, company-scoped (spec Section 15: 'Audit logging').
    Deliberately a flat action+detail row rather than per-entity tables —
    matches the pattern already used by the kiosk-local Admin Panel's own
    AdminAuditLogEntry, kept simple and queryable.
    """
    __tablename__ = "audit_log_entries"

    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=True)  # null = platform-level
    actor_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)  # null = system/agent

    action = db.Column(db.String(64), nullable=False)
    detail = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    company = db.relationship("Company")
    actor = db.relationship("User")

    def __repr__(self):
        return f"<AuditLogEntry {self.action} by user={self.actor_id}>"


def log_action(company, actor, action: str, detail: str = None):
    """Convenience helper — call from any route that mutates something worth
    auditing. Adds to the session but doesn't commit; caller's existing
    db.session.commit() picks it up, keeping the audit row atomic with the
    change it's describing."""
    entry = AuditLogEntry(
        company_id=company.id if company else None,
        actor_id=actor.id if actor else None,
        action=action,
        detail=detail,
    )
    db.session.add(entry)
    return entry


# ---------------------------------------------------------------------------
# Part 9: Staged rollouts + config rollback (spec Sections 42-43)
# ---------------------------------------------------------------------------

ROLLOUT_STATUSES = ["in_progress", "completed", "halted"]


class StagedRollout(db.Model):
    """A company-scoped, batched rollout of one package across many
    instances (spec Section 42): push to batch 1, let the admin eyeball the
    result, then manually advance to the next batch — rather than pushing to
    every kiosk simultaneously.
    """
    __tablename__ = "staged_rollouts"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    company_id = db.Column(db.Integer, db.ForeignKey("companies.id"), nullable=False)
    package_id = db.Column(db.Integer, db.ForeignKey("update_packages.id"), nullable=False)

    batch_size = db.Column(db.Integer, nullable=False)
    mode = db.Column(db.String(16), nullable=False, default="now")  # 'now' or 'schedule'

    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    status = db.Column(db.String(16), nullable=False, default="in_progress")

    company = db.relationship("Company")
    package = db.relationship("UpdatePackage")
    created_by = db.relationship("User")
    members = db.relationship(
        "StagedRolloutInstance", back_populates="rollout", cascade="all, delete-orphan",
        order_by="StagedRolloutInstance.batch_number, StagedRolloutInstance.id",
    )

    def batches(self):
        """Members grouped by batch_number, in order."""
        out = {}
        for m in self.members:
            out.setdefault(m.batch_number, []).append(m)
        return sorted(out.items())

    def highest_pushed_batch(self):
        pushed = [m.batch_number for m in self.members if m.deployment_id is not None]
        return max(pushed) if pushed else 0

    def total_batches(self):
        if not self.members:
            return 0
        return max(m.batch_number for m in self.members)

    def has_next_batch(self):
        return self.highest_pushed_batch() < self.total_batches()


class StagedRolloutInstance(db.Model):
    """One instance's slot within a staged rollout's ordered batches."""
    __tablename__ = "staged_rollout_instances"

    id = db.Column(db.Integer, primary_key=True)
    rollout_id = db.Column(db.Integer, db.ForeignKey("staged_rollouts.id"), nullable=False)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    batch_number = db.Column(db.Integer, nullable=False)  # 1-indexed

    deployment_id = db.Column(db.Integer, db.ForeignKey("update_deployments.id"), nullable=True)

    rollout = db.relationship("StagedRollout", back_populates="members")
    instance = db.relationship("Instance")
    deployment = db.relationship("UpdateDeployment")



# ---------------------------------------------------------------------------
# Remote process control — turn the kiosk process on/off, and set what
# starts it, from the Admin Panel (previously only settable by hand-editing
# settings.json on the machine itself — a real, reported gap: "why doesn't
# the kiosk turn on... it should be fully controlled from the panel").
# ---------------------------------------------------------------------------

COMMAND_TYPES = ["start", "stop", "restart", "configure", "run_command"]
COMMAND_STATUSES = ["pending", "in_progress", "success", "failed"]


class InstanceCommand(db.Model):
    __tablename__ = "instance_commands"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    command_type = db.Column(db.String(16), nullable=False)
    payload_json = db.Column(db.Text, nullable=True)  # used by 'configure' and 'run_command'

    requested_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    status = db.Column(db.String(16), nullable=False, default="pending")
    result_message = db.Column(db.Text, nullable=True)
    acked_at = db.Column(db.DateTime, nullable=True)
    # Set when the Agent actually picks the command up and starts executing
    # it (see agent_api.py's start_command / agent/commands.py) — distinct
    # from created_at (when the Admin Panel queued it) and acked_at (when
    # it finished). Without this there was no real signal for "the Agent
    # has started working on this", so the Admin Panel UI could only
    # guess how far along a Start/Stop/Restart was from a single click
    # timestamp — including guessing confidently even if the Agent hadn't
    # picked the command up yet at all (offline, mid poll-cycle, etc).
    started_at = db.Column(db.DateTime, nullable=True)

    instance = db.relationship("Instance")
    requested_by = db.relationship("User")

    def payload(self) -> dict:
        import json
        if not self.payload_json:
            return {}
        try:
            return json.loads(self.payload_json)
        except ValueError:
            return {}


SCHEDULER_SERVICE_ACCOUNT_EMAIL = "scheduler@system.internal"


def get_scheduler_service_user():
    """Lazily creates (once) and returns the synthetic User row that stands
    in for `requested_by_id` on an InstanceCommand this Admin Panel queues
    on its own (currently: an auto-triggered scheduled cloud backup — see
    agent_api.py's get_pending_command) rather than because a human clicked
    something. Same rationale as get_client_portal_service_user() above,
    kept as a separate account rather than reused so "requested by" text
    stays honest about there being no human behind THIS one at all, not
    even indirectly through the Client Portal. Never returned to a
    browser, never logged into."""
    user = User.query.filter_by(email=SCHEDULER_SERVICE_ACCOUNT_EMAIL).first()
    if user is not None:
        return user
    user = User(
        email=SCHEDULER_SERVICE_ACCOUNT_EMAIL,
        full_name="Scheduled task",
        email_verified=True,
        is_active=False,
        is_service_account=True,
    )
    user.set_password(gen_token())
    db.session.add(user)
    db.session.flush()
    return user


class InstanceBackup(db.Model):
    """One backup file this Admin Panel actually holds for an instance —
    created either because a scheduled cloud backup came due (see
    app/backup_scheduling.py + agent_api.py's auto-enqueued backup_now) or
    because someone clicked "Back up now" from the Client Portal. Both
    paths converge on the exact same agent_api.py upload endpoint and the
    exact same retention pruning (see prune_instance_backups below) — this
    row (+ the file on disk under UPDATE_PACKAGE_DIR's sibling
    INSTANCE_BACKUP_DIR) is the only thing that distinguishes "kept
    locally on the kiosk only" from "also sent to the cloud"."""
    __tablename__ = "instance_backups"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    filename = db.Column(db.String(255), nullable=False)
    file_path = db.Column(db.String(1000), nullable=False)
    file_size = db.Column(db.Integer, nullable=False)
    source = db.Column(db.String(16), nullable=False, default="scheduled")  # "scheduled" | "manual"
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    # JSON {"items": 834, "tools": 1, ...} — a row count per known kiosk_app
    # table, read directly out of the uploaded sqlite file at upload time
    # (see agent_api.py's upload_backup / inspect_backup_contents) so a
    # company can see AT A GLANCE that a backup actually contains their
    # real data, not just a file size. Null for any backup uploaded before
    # this existed, or if inspection itself failed (a corrupt/foreign file
    # must never block the backup from being stored — see that function's
    # own docstring).
    contents_summary = db.Column(db.Text, nullable=True)

    instance = db.relationship("Instance", back_populates="backups")

    def contents_summary_dict(self):
        if not self.contents_summary:
            return None
        try:
            return json.loads(self.contents_summary)
        except ValueError:
            return None


BACKUP_INSPECTED_TABLES = ("items", "tools", "local_users", "projects", "wire_spools", "inventory_items")


def inspect_backup_contents(file_path: str):
    """Opens a just-uploaded backup file read-only and counts rows in each
    of kiosk_app's main data tables — see InstanceBackup.contents_summary.
    This is what lets a company see at a glance that a backup actually
    holds their real items/tools/etc., not just a file size. Returns a
    JSON string ready to store, or None if the file couldn't be read as a
    sqlite database at all (e.g. a corrupted upload) — inspection failing
    must never block the backup itself from being stored, so this always
    degrades to "no summary available" rather than raising."""
    import sqlite3
    try:
        # uri=True + mode=ro: never risk writing to (or locking) a file
        # that's about to be handed to a company as their own backup.
        conn = sqlite3.connect(f"file:{file_path}?mode=ro", uri=True)
        try:
            cur = conn.cursor()
            existing_tables = {
                row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
            }
            summary = {}
            for table in BACKUP_INSPECTED_TABLES:
                if table not in existing_tables:
                    continue
                # `table` only ever comes from the hardcoded tuple above,
                # never from anything in the uploaded file itself — safe
                # despite the f-string.
                summary[table] = cur.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        finally:
            conn.close()
        return json.dumps(summary)
    except Exception:
        return None


def prune_instance_backups(instance_id: int, retention_months: int = 12, keep_per_month: int = 3):
    """Enforces the retention policy: within the last `retention_months`
    calendar months, keep at most `keep_per_month` backups per month (the
    most recent ones — an older backup in the same month is the first to
    go once a month is over its quota); anything older than
    `retention_months` is deleted outright regardless of count. Deletes
    both the DB row and the file on disk, and is safe to call after every
    single upload (it only ever removes rows that are already over quota,
    never the backup that was just stored unless something even newer in
    the same month already displaced it)."""
    import os as _os
    from collections import defaultdict

    all_backups = InstanceBackup.query.filter_by(instance_id=instance_id).order_by(
        InstanceBackup.created_at.desc()
    ).all()
    if not all_backups:
        return

    cutoff = all_backups[0].created_at - timedelta(days=30 * retention_months)
    by_month = defaultdict(list)
    to_delete = []
    for b in all_backups:
        if b.created_at < cutoff:
            to_delete.append(b)
            continue
        by_month[(b.created_at.year, b.created_at.month)].append(b)

    for rows in by_month.values():
        # Already sorted newest-first (all_backups was) — anything past
        # the per-month quota is the oldest in that month.
        to_delete.extend(rows[keep_per_month:])

    for b in to_delete:
        try:
            if b.file_path and _os.path.isfile(b.file_path):
                _os.remove(b.file_path)
        except OSError:
            pass
        db.session.delete(b)


# ---------------------------------------------------------------------------
# Client Portal: a second, separate account/login system for a customer's own
# end users — deliberately NOT a Company member (no CompanyMembership, no
# role, no company-wide visibility). A ClientUser signs themselves up, then
# has no access to anything until a platform admin assigns them to one or
# more specific instances (possibly across different companies) from
# Platform → Clients. Once assigned, a ClientUser can operate exactly what
# the "operate_kiosk"/"operate_kiosk_updates" company permissions cover for
# an operator (start/stop/restart, push an update, Items & Tools, Local
# Kiosk Users) on those specific instances only — see client_portal.py.
# ---------------------------------------------------------------------------

CLIENT_PORTAL_SERVICE_ACCOUNT_EMAIL = "client-portal@system.internal"


def get_client_portal_service_user():
    """Lazily creates (once) and returns the synthetic User row that stands
    in for `requested_by_id` on an InstanceCommand/UpdateDeployment the
    Client Portal creates — see User.is_service_account above for why this
    exists instead of writing a ClientUser's own id into those columns.
    Never returned to a browser, never logged into."""
    user = User.query.filter_by(email=CLIENT_PORTAL_SERVICE_ACCOUNT_EMAIL).first()
    if user is not None:
        return user
    user = User(
        email=CLIENT_PORTAL_SERVICE_ACCOUNT_EMAIL,
        full_name="Client Portal",
        email_verified=True,
        is_active=False,
        is_service_account=True,
    )
    user.set_password(gen_token(32))  # unusable random value — this account never logs in
    db.session.add(user)
    db.session.flush()  # assigns user.id without committing the caller's own transaction
    return user


class ClientUser(UserMixin, db.Model):
    __tablename__ = "client_users"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    full_name = db.Column(db.String(255), nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)

    is_active = db.Column(db.Boolean, nullable=False, default=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    last_login_at = db.Column(db.DateTime, nullable=True)

    assignments = db.relationship(
        "ClientInstanceAccess", back_populates="client_user", cascade="all, delete-orphan"
    )

    def set_password(self, raw_password: str):
        self.password_hash = _ph.hash(raw_password)

    def check_password(self, raw_password: str) -> bool:
        try:
            ok = _ph.verify(self.password_hash, raw_password)
        except VerifyMismatchError:
            return False
        except Exception:
            return False
        if ok and _ph.check_needs_rehash(self.password_hash):
            self.set_password(raw_password)
            db.session.commit()
        return ok

    def get_id(self):
        # Prefixed (unlike User.get_id(), which stays a bare public_id for
        # backward compatibility with already-logged-in staff sessions) so
        # the shared Flask-Login user_loader (app/__init__.py) can tell
        # which table to query without the two id spaces ever colliding.
        return f"client:{self.public_id}"

    def instances(self):
        return [a.instance for a in self.assignments]

    def has_access(self, instance) -> bool:
        return any(a.instance_id == instance.id for a in self.assignments)

    def __repr__(self):
        return f"<ClientUser {self.email}>"


class ClientInstanceAccess(db.Model):
    """One instance a ClientUser has been assigned to operate."""
    __tablename__ = "client_instance_access"
    __table_args__ = (
        db.UniqueConstraint("client_user_id", "instance_id", name="uq_client_instance_access"),
    )

    id = db.Column(db.Integer, primary_key=True)
    client_user_id = db.Column(db.Integer, db.ForeignKey("client_users.id"), nullable=False)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    granted_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    client_user = db.relationship("ClientUser", back_populates="assignments")
    instance = db.relationship("Instance")
    granted_by = db.relationship("User")


class ClientActionLog(db.Model):
    """A self-contained activity trail for the Client Portal, independent of
    AuditLogEntry (whose actor_id is a NOT NULL foreign key into `users`,
    not `client_users` — see User.is_service_account). Shown on the
    Platform-side client detail page and the client's own instance page."""
    __tablename__ = "client_action_log"

    id = db.Column(db.Integer, primary_key=True)
    client_user_id = db.Column(db.Integer, db.ForeignKey("client_users.id"), nullable=False)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=True)

    action = db.Column(db.String(64), nullable=False)
    detail = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    client_user = db.relationship("ClientUser")
    instance = db.relationship("Instance")


CHANGE_REQUEST_STATUSES = ("open", "in_progress", "completed", "declined")
CHANGE_REQUEST_STATUS_LABELS = {
    "open": "Open", "in_progress": "In progress", "completed": "Completed", "declined": "Declined",
}


class ChangeRequest(db.Model):
    """A client's request for a future update or change to one of their
    instances — deliberately lightweight (no priority/category/SLA
    machinery): just a title, description, and a status staff move along
    manually, plus one optional free-text response. Separate from
    InstanceCommand (an immediate one-shot action the Agent executes) and
    UpdateDeployment (an actual software release) — this is just something
    for a human to read and decide on, on whatever timeline that takes."""
    __tablename__ = "change_requests"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    client_user_id = db.Column(db.Integer, db.ForeignKey("client_users.id"), nullable=False)
    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)

    title = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=False)
    status = db.Column(db.String(16), nullable=False, default="open")

    admin_response = db.Column(db.Text, nullable=True)
    resolved_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    resolved_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow)

    client_user = db.relationship("ClientUser")
    instance = db.relationship("Instance")
    resolved_by = db.relationship("User")

    def status_label(self):
        return CHANGE_REQUEST_STATUS_LABELS.get(self.status, self.status)

    def __repr__(self):
        return f"<ChangeRequest {self.title!r} status={self.status}>"


def log_client_action(client_user, instance, action: str, detail: str = None):
    entry = ClientActionLog(
        client_user_id=client_user.id,
        instance_id=instance.id if instance else None,
        action=action,
        detail=detail,
    )
    db.session.add(entry)
    return entry

