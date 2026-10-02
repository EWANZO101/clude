#!/usr/bin/env bash
# Just writes the files. No migration, no restart, no checks. Run from
# inside /root/admin_panel.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

cat > app/models.py << 'MODELS_EOF_MARKER'
import secrets
import uuid
from datetime import datetime

from flask_login import UserMixin
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from app.extensions import db

_ph = PasswordHasher()


def gen_uuid():
    return str(uuid.uuid4())


def gen_token(nbytes=32):
    return secrets.token_urlsafe(nbytes)


# Roles available within a company. Order = ascending privilege for convenience only;
# actual permission checks go through ROLE_PERMISSIONS below (Part 3/8 will extend this
# into a fully editable AdminRole table, mirroring the kiosk-local Admin Panel pattern).
COMPANY_ROLES = ["owner", "administrator", "manager", "operator"]

# Coarse-grained permission matrix for Part 1/2. Extended in later parts as instance,
# update, and config management endpoints are added.
ROLE_PERMISSIONS = {
    "owner": {
        "manage_company", "manage_members", "manage_roles",
        "manage_instances", "manage_config", "manage_updates",
        "view_instances", "view_billing", "manage_billing",
    },
    "administrator": {
        "manage_members",
        "manage_instances", "manage_config", "manage_updates",
        "view_instances",
    },
    "manager": {
        "manage_instances", "manage_config",
        "view_instances",
    },
    "operator": {
        "view_instances",
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

    memberships = db.relationship(
        "CompanyMembership", back_populates="user", cascade="all, delete-orphan"
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

    def companies(self):
        return [m.company for m in self.memberships]

    def __repr__(self):
        return f"<User {self.email}>"


class PlatformSetting(db.Model):
    """Singleton row (id is always 1) for platform-wide toggles that don't
    belong to any one company — currently just whether public self-signup
    is open. Kept as its own tiny table rather than a config file so a
    platform admin can flip it from the UI without a redeploy."""
    __tablename__ = "platform_settings"

    id = db.Column(db.Integer, primary_key=True)
    signups_enabled = db.Column(db.Boolean, nullable=False, default=True)

    @classmethod
    def get(cls):
        row = cls.query.get(1)
        if row is None:
            row = cls(id=1, signups_enabled=True)
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
    label = db.Column(db.String(255), nullable=True)  # e.g. "Branch 2 rollout"

    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    expires_at = db.Column(db.DateTime, nullable=True)  # null = no expiry
    max_uses = db.Column(db.Integer, nullable=True)      # null = unlimited
    use_count = db.Column(db.Integer, nullable=False, default=0)
    revoked = db.Column(db.Boolean, nullable=False, default=False)

    company = db.relationship("Company", back_populates="enrollment_tokens")
    created_by = db.relationship("User")

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
    kiosk_process_status = db.Column(db.String(16), nullable=True)  # running|stopped|not_configured|giving_up

    registered_via_token_id = db.Column(db.Integer, db.ForeignKey("enrollment_tokens.id"), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Update scheduling (Part 5): kiosk-specific override, highest priority
    # below a one-time individual schedule. Null = inherit company/system.
    scheduled_update_time = db.Column(db.Time, nullable=True)

    company = db.relationship("Company", back_populates="instances")
    registered_via_token = db.relationship("EnrollmentToken")
    configs = db.relationship(
        "InstanceConfig", back_populates="instance", cascade="all, delete-orphan",
        order_by="InstanceConfig.version.desc()",
    )
    deployments = db.relationship(
        "UpdateDeployment", back_populates="instance", cascade="all, delete-orphan",
        order_by="UpdateDeployment.requested_at.desc()",
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

    def __repr__(self):
        return f"<Instance {self.public_id} company={self.company_id}>"


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

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    version = db.Column(db.String(32), nullable=False, unique=True)
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

    has_rescue_component = db.Column(db.Boolean, nullable=False, default=False)

    uploaded_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    uploaded_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    # Soft-disable rather than delete — spec Section 49 wants release history
    # to remain visible ("Deployment status") even for withdrawn packages.
    withdrawn = db.Column(db.Boolean, nullable=False, default=False)

    uploaded_by = db.relationship("User")

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
IN_FLIGHT_STATUSES = [
    "scheduled", "waiting", "downloading", "validating", "preparing",
    "installing", "restarting", "health_check", "failed", "rolling_back",
]
TERMINAL_STATUSES = ["successful", "rolled_back", "cancelled", "superseded"]

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
    "health_check": {"successful", "failed"},
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

COMMAND_TYPES = ["start", "stop", "restart", "configure"]
COMMAND_STATUSES = ["pending", "success", "failed"]


class InstanceCommand(db.Model):
    __tablename__ = "instance_commands"

    id = db.Column(db.Integer, primary_key=True)
    public_id = db.Column(db.String(36), unique=True, nullable=False, default=gen_uuid)

    instance_id = db.Column(db.Integer, db.ForeignKey("instances.id"), nullable=False)
    command_type = db.Column(db.String(16), nullable=False)
    payload_json = db.Column(db.Text, nullable=True)  # only used by 'configure'

    requested_by_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    status = db.Column(db.String(16), nullable=False, default="pending")
    result_message = db.Column(db.Text, nullable=True)
    acked_at = db.Column(db.DateTime, nullable=True)

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

MODELS_EOF_MARKER

cat > app/blueprints/agent_api.py << 'AGENTAPI_EOF_MARKER'
from datetime import datetime
import json
import os

from flask import Blueprint, request, jsonify, send_file, current_app

from app.extensions import db
from app.models import (
    Instance, EnrollmentToken, InstanceConfig, UpdatePackage, UpdateDeployment,
    SUPPORTED_OS, gen_token, ALLOWED_TRANSITIONS, IN_FLIGHT_STATUSES,
    RemoteAccessToken, AgentErrorReport, InstanceCommand,
)
from app.instance_auth import instance_auth_required

bp = Blueprint("agent_api", __name__, url_prefix="/api/v1")


@bp.route("/instances/register", methods=["POST"])
def register_instance():
    """Called once by a freshly-installed Instance Agent (spec Sections 5/6,
    step "Connect/register with the management service"). Consumes an
    enrollment token and returns a permanent per-instance credential.

    The returned instance_secret is shown exactly once — the agent must
    persist it locally (e.g. settings.json equivalent) alongside instance_id.
    """
    data = request.get_json(silent=True) or {}

    registration_token = (data.get("registration_token") or "").strip()
    os_name = (data.get("os") or "").strip().lower()
    hostname = (data.get("hostname") or "").strip() or None
    os_version = (data.get("os_version") or "").strip() or None
    agent_version = (data.get("agent_version") or "").strip() or None
    app_version = (data.get("app_version") or "").strip() or None

    if not registration_token:
        return jsonify({"error": "registration_token is required"}), 400
    if os_name not in SUPPORTED_OS:
        return jsonify({"error": f"os must be one of {SUPPORTED_OS}"}), 400

    token = EnrollmentToken.query.filter_by(token=registration_token).first()
    if token is None or not token.is_valid():
        # Same message whether the token is unknown, expired, revoked, or
        # exhausted — don't help an attacker distinguish those cases.
        return jsonify({"error": "invalid or expired registration token"}), 401

    instance = Instance(
        company_id=token.company_id,
        hostname=hostname,
        os=os_name,
        os_version=os_version,
        agent_version=agent_version,
        app_version=app_version,
        registered_via_token_id=token.id,
    )
    raw_secret = gen_token(32)
    instance.set_secret(raw_secret)
    instance.mark_seen()

    token.use_count += 1

    db.session.add(instance)
    db.session.commit()

    return jsonify({
        "instance_id": instance.public_id,
        "instance_secret": raw_secret,
        "company_name": token.company.name,
    }), 201


@bp.route("/instances/heartbeat", methods=["POST"])
@instance_auth_required
def heartbeat():
    """Periodic check-in. Reports live version/connection info and marks the
    instance online. Update-state fields (health, scheduled update, etc.) are
    added to this payload in Part 5/6 once those systems exist."""
    from flask import g
    data = request.get_json(silent=True) or {}

    g.instance.mark_seen(
        agent_version=(data.get("agent_version") or "").strip() or None,
        app_version=(data.get("app_version") or "").strip() or None,
        os_version=(data.get("os_version") or "").strip() or None,
        local_ip=(data.get("local_ip") or "").strip() or None,
        public_ip=(data.get("public_ip") or "").strip() or None,
        port=data.get("port") if isinstance(data.get("port"), int) else None,
    )
    if "tunnel_connected" in data:
        g.instance.tunnel_connected = bool(data.get("tunnel_connected"))
    if "kiosk_process_status" in data:
        g.instance.kiosk_process_status = (data.get("kiosk_process_status") or "").strip() or None

    db.session.commit()

    return jsonify({
        "ok": True,
        "instance_name": g.instance.display_name(),
        "company_name": g.instance.company.name,
        "server_time": datetime.utcnow().isoformat() + "Z",
    })


@bp.route("/instances/me", methods=["GET"])
@instance_auth_required
def me():
    """Lets the agent confirm its own registered identity/config at any time
    (e.g. after a restart, before deciding whether re-registration is needed)."""
    from flask import g
    instance = g.instance
    return jsonify({
        "instance_id": instance.public_id,
        "name": instance.display_name(),
        "company_name": instance.company.name,
        "os": instance.os,
        "connection_status": instance.connection_status,
        "last_seen_at": instance.last_seen_at.isoformat() + "Z" if instance.last_seen_at else None,
    })


@bp.route("/instances/config", methods=["GET"])
@instance_auth_required
def get_config():
    """Polled by the agent (spec Section 11: 'Configuration changes should be
    sent securely to the Instance Agent'). Returns the newest unacknowledged
    config push, if any — the agent is expected to receive, validate, apply,
    then ack via /config/ack below. If there's nothing pending, returns the
    last applied config for reference with pending: null."""
    from flask import g
    instance = g.instance

    pending = instance.pending_config()
    current = instance.current_config()

    return jsonify({
        "pending": {
            "version": pending.version,
            "config": json.loads(pending.config_json),
        } if pending else None,
        "current": {
            "version": current.version,
            "config": json.loads(current.config_json),
        } if current else None,
    })


@bp.route("/instances/config/ack", methods=["POST"])
@instance_auth_required
def ack_config():
    """Agent reports the result of applying a pushed config (spec Section 11
    steps 4–6: apply, confirm, report result). Body: {version, status, message}
    where status is 'applied', 'failed', or 'rejected' (agent-side validation
    refused it before ever applying anything)."""
    from flask import g
    data = request.get_json(silent=True) or {}

    version = data.get("version")
    status = (data.get("status") or "").strip().lower()
    message = (data.get("message") or "").strip() or None

    if status not in ("applied", "failed", "rejected"):
        return jsonify({"error": "status must be one of applied, failed, rejected"}), 400
    if not isinstance(version, int):
        return jsonify({"error": "version (integer) is required"}), 400

    config = InstanceConfig.query.filter_by(instance_id=g.instance.id, version=version).first()
    if config is None:
        return jsonify({"error": "unknown config version"}), 404
    if config.status != "pending":
        # Already acknowledged (e.g. superseded by a newer push) — don't let a
        # late/duplicate ack from the agent overwrite that outcome.
        return jsonify({"error": "config version is no longer pending", "current_status": config.status}), 409

    config.status = status
    config.agent_message = message
    config.acknowledged_at = datetime.utcnow()
    db.session.commit()

    return jsonify({"ok": True})


@bp.route("/instances/updates/current", methods=["GET"])
@instance_auth_required
def current_update():
    """Polled by the agent to find out if there's an update to act on (spec
    Section 20: kiosk-side update notification). If the deployment's
    target_time has arrived, it's flipped from 'scheduled' to 'waiting' here
    — 'waiting' is the agent's cue that it's allowed to start."""
    from flask import g
    instance = g.instance

    deployment = instance.active_deployment()
    if deployment is None:
        return jsonify({"deployment": None})

    now = datetime.utcnow()
    if deployment.status == "scheduled" and deployment.target_time_utc <= now:
        deployment.status = "waiting"
        deployment.append_log("waiting", "target time reached")
        db.session.commit()

    due = deployment.status != "scheduled" or deployment.target_time_utc <= now

    return jsonify({
        "deployment": {
            "id": deployment.public_id,
            "status": deployment.status,
            "due": due,
            "target_time_utc": deployment.target_time_utc.isoformat() + "Z",
            "package": {
                "version": deployment.package.version,
                "checksum_sha256": deployment.package.checksum_sha256,
                "file_size": deployment.package.file_size,
                "download_url": f"/api/v1/updates/{deployment.package.public_id}/download",
            },
        }
    })


@bp.route("/updates/<package_id>/download", methods=["GET"])
@instance_auth_required
def download_package(package_id):
    """Streams the ZIP for an in-flight deployment only — an instance can't
    use its credentials to fetch arbitrary packages it wasn't offered (spec
    Section 15: 'never blindly execute an arbitrary file received from an
    unknown source' applies just as much to what it's allowed to fetch)."""
    from flask import g
    instance = g.instance

    package = UpdatePackage.query.filter_by(public_id=package_id).first()
    if package is None:
        return jsonify({"error": "unknown package"}), 404

    deployment = instance.active_deployment()
    if deployment is None or deployment.package_id != package.id or deployment.status not in ("waiting", "downloading"):
        return jsonify({"error": "no authorized in-progress deployment for this package"}), 403

    if not os.path.exists(package.file_path):
        return jsonify({"error": "package file missing on server"}), 500

    if deployment.status == "waiting":
        deployment.status = "downloading"
        deployment.started_at = deployment.started_at or datetime.utcnow()
        deployment.append_log("downloading", "download started")
        db.session.commit()

    return send_file(
        package.file_path, mimetype="application/zip",
        as_attachment=True, download_name=f"stocktool-kiosk-{package.version}.zip",
    )


@bp.route("/instances/updates/<deployment_id>/status", methods=["POST"])
@instance_auth_required
def report_update_status(deployment_id):
    """Agent reports progress through the lifecycle (spec Section 28 steps
    7-14). Forward-only — see ALLOWED_TRANSITIONS — so a confused or replayed
    report can't jump the state machine or resurrect a finished deployment."""
    from flask import g
    instance = g.instance

    deployment = UpdateDeployment.query.filter_by(public_id=deployment_id, instance_id=instance.id).first()
    if deployment is None:
        return jsonify({"error": "unknown deployment"}), 404

    data = request.get_json(silent=True) or {}
    new_status = (data.get("status") or "").strip()
    message = (data.get("message") or "").strip() or None
    health_check_passed = data.get("health_check_passed")

    allowed = ALLOWED_TRANSITIONS.get(deployment.status, set())
    if new_status not in allowed:
        return jsonify({
            "error": f"cannot transition from '{deployment.status}' to '{new_status}'",
            "allowed_next": sorted(allowed),
        }), 409

    if new_status == "successful":
        # Spec Section 32: only a passed health check may confirm success —
        # never inferred from the application merely having started.
        if deployment.health_check_passed is not True:
            return jsonify({
                "error": "cannot mark successful — no passed health check on record for this deployment"
            }), 400

    if new_status == "health_check" and health_check_passed is not None:
        deployment.health_check_passed = bool(health_check_passed)
        deployment.health_check_message = message

    if new_status == "rolling_back":
        deployment.rollback_reason = message

    if deployment.started_at is None and new_status not in ("scheduled", "waiting"):
        deployment.started_at = datetime.utcnow()

    deployment.status = new_status
    deployment.append_log(new_status, message)

    if new_status == "successful":
        deployment.completed_at = datetime.utcnow()
        instance.app_version = deployment.package.version
        instance.last_known_good_version = deployment.package.version
    elif new_status == "rolled_back":
        deployment.completed_at = datetime.utcnow()
        # Instance.app_version was never advanced (only 'successful' does
        # that), so it's already sitting at the previous/Last Known Good
        # version — nothing to revert here, just record the outcome.

    db.session.commit()
    return jsonify({"ok": True, "status": deployment.status})


@bp.route("/instances/errors", methods=["POST"])
@instance_auth_required
def report_error():
    """Receives one ERROR/CRITICAL log event from an Instance Agent's
    error_reporter.py. Best-effort on the Agent's side (it never retries),
    so this stays simple: validate the shape, store it, done. Surfaced on
    the instance's Diagnostics panel."""
    from flask import g
    data = request.get_json(silent=True) or {}

    level = (data.get("level") or "").strip().upper()
    if level not in ("ERROR", "CRITICAL"):
        return jsonify({"error": "level must be ERROR or CRITICAL"}), 400

    message = (data.get("message") or "").strip()
    if not message:
        return jsonify({"error": "message is required"}), 400

    suppressed = data.get("suppressed_since_last", 0)
    if not isinstance(suppressed, int) or suppressed < 0:
        suppressed = 0

    report = AgentErrorReport(
        instance_id=g.instance.id,
        level=level,
        logger_name=(data.get("logger") or "").strip() or None,
        message=message,
        traceback=data.get("traceback") or None,
        suppressed_since_last=suppressed,
    )
    db.session.add(report)
    db.session.commit()
    return jsonify({"ok": True}), 201


@bp.route("/instances/tunnel", methods=["GET"])
@instance_auth_required
def get_tunnel_request():
    """Polled by the Agent's tunnel.py to check whether an operator has
    requested remote access (issued from the instance detail page's
    "Request remote access token" button). Only ever returns a request
    still in 'pending' status — once the Agent reports an outcome via
    /tunnel/<id>/status below, it stops being handed back here, so a
    long-lived poll loop doesn't re-report the same request every cycle."""
    from flask import g
    now = datetime.utcnow()

    req = (
        RemoteAccessToken.query
        .filter_by(instance_id=g.instance.id, status="pending", revoked=False)
        .filter(RemoteAccessToken.expires_at > now)
        .order_by(RemoteAccessToken.created_at.desc())
        .first()
    )
    if req is None:
        return jsonify({"request": None})

    return jsonify({
        "request": {
            "id": req.public_id,
            "requested_at": req.created_at.isoformat() + "Z",
            "expires_at": req.expires_at.isoformat() + "Z",
        }
    })


@bp.route("/instances/tunnel/<tunnel_id>/status", methods=["POST"])
@instance_auth_required
def report_tunnel_status(tunnel_id):
    """Agent reports what happened with a tunnel request it saw via GET
    /tunnel above. 'unsupported' is the expected real-world status right
    now — the Agent's tunnel client is a deliberate stub until a tunnel
    broker exists on this side (spec Section 14); this endpoint just
    records whatever the Agent honestly reports."""
    from flask import g
    req = RemoteAccessToken.query.filter_by(public_id=tunnel_id, instance_id=g.instance.id).first()
    if req is None:
        return jsonify({"error": "unknown tunnel request"}), 404

    data = request.get_json(silent=True) or {}
    status = (data.get("status") or "").strip().lower()
    if status not in ("connected", "unsupported", "failed"):
        return jsonify({"error": "status must be one of connected, unsupported, failed"}), 400

    req.status = status
    req.status_message = (data.get("message") or "").strip() or None
    if status == "connected":
        req.used = True
        req.used_at = datetime.utcnow()

    db.session.commit()
    return jsonify({"ok": True})


@bp.route("/instances/commands", methods=["GET"])
@instance_auth_required
def get_pending_command():
    """Polled by the Agent's commands.py — the remote start/stop/restart/
    configure channel that was missing entirely before: previously the only
    way to change what starts the kiosk process, or turn it on/off, was to
    hand-edit settings.json on the machine itself."""
    from flask import g
    command = InstanceCommand.query.filter_by(
        instance_id=g.instance.id, status="pending"
    ).order_by(InstanceCommand.created_at.asc()).first()

    if command is None:
        return jsonify({"command": None})

    return jsonify({
        "command": {
            "id": command.public_id,
            "command_type": command.command_type,
            "payload": command.payload(),
        }
    })


@bp.route("/instances/commands/<command_id>/ack", methods=["POST"])
@instance_auth_required
def ack_command(command_id):
    from flask import g
    command = InstanceCommand.query.filter_by(public_id=command_id, instance_id=g.instance.id).first()
    if command is None:
        return jsonify({"error": "unknown command"}), 404
    if command.status != "pending":
        return jsonify({"error": "command already acknowledged", "status": command.status}), 409

    data = request.get_json(silent=True) or {}
    status = (data.get("status") or "").strip()
    if status not in ("success", "failed"):
        return jsonify({"error": "status must be 'success' or 'failed'"}), 400

    command.status = status
    command.result_message = (data.get("message") or "").strip() or None
    command.acked_at = datetime.utcnow()
    db.session.commit()

    return jsonify({"ok": True})

AGENTAPI_EOF_MARKER

cat > app/blueprints/instances.py << 'INSTANCES_EOF_MARKER'
import json
from datetime import datetime, timedelta

from flask import Blueprint, render_template, redirect, url_for, request, flash, g, abort

from app.extensions import db
from app.models import (
    Instance, EnrollmentToken, InstanceConfig, UpdatePackage, UpdateDeployment,
    RemoteAccessToken, AgentErrorReport, log_action, InstanceCommand,
)
from app.rbac import load_company_context, permission_required
from app.update_scheduling import resolve_deployment_target
from flask_login import login_required, current_user

bp = Blueprint("instances", __name__, url_prefix="/companies/<company_id>/instances")


@bp.route("/")
@login_required
@load_company_context
def list_instances(company_id):
    company = g.company
    instances = Instance.query.filter_by(company_id=company.id).order_by(Instance.created_at.desc()).all()
    tokens = EnrollmentToken.query.filter_by(company_id=company.id, revoked=False).order_by(
        EnrollmentToken.created_at.desc()
    ).all()

    from datetime import timedelta
    day_ago = datetime.utcnow() - timedelta(hours=24)
    stats = {
        "total": len(instances),
        "online": sum(1 for i in instances if i.connection_status == "online"),
        "offline": sum(1 for i in instances if i.connection_status == "offline"),
        "updating": sum(1 for i in instances if i.active_deployment() is not None),
        "failed_24h": UpdateDeployment.query.join(Instance).filter(
            Instance.company_id == company.id,
            UpdateDeployment.status.in_(["failed", "rolled_back"]),
            UpdateDeployment.completed_at >= day_ago,
        ).count(),
        "successful_24h": UpdateDeployment.query.join(Instance).filter(
            Instance.company_id == company.id,
            UpdateDeployment.status == "successful",
            UpdateDeployment.completed_at >= day_ago,
        ).count(),
    }

    return render_template(
        "instances/list.html", company=company, instances=instances, tokens=tokens,
        role=g.company_role, stats=stats,
    )


@bp.route("/tokens/new", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def new_token(company_id):
    company = g.company
    label = request.form.get("label", "").strip() or None
    expires_in_days = request.form.get("expires_in_days", "").strip()
    max_uses = request.form.get("max_uses", "").strip()

    token = EnrollmentToken(company_id=company.id, label=label, created_by_id=current_user.id)
    if expires_in_days.isdigit() and int(expires_in_days) > 0:
        token.expires_at = datetime.utcnow() + timedelta(days=int(expires_in_days))
    if max_uses.isdigit() and int(max_uses) > 0:
        token.max_uses = int(max_uses)

    db.session.add(token)
    log_action(company, current_user, "enrollment_token_created", label or "(no label)")
    db.session.commit()

    flash("Enrollment token created. Copy the install command before leaving this page.", "success")
    return redirect(url_for("instances.list_instances", company_id=company.public_id))


@bp.route("/tokens/<int:token_id>/revoke", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def revoke_token(company_id, token_id):
    company = g.company
    token = EnrollmentToken.query.filter_by(id=token_id, company_id=company.id).first()
    if token is None:
        abort(404)
    token.revoked = True
    log_action(company, current_user, "enrollment_token_revoked", token.label or token.token[:8])
    db.session.commit()
    flash("Enrollment token revoked.", "info")
    return redirect(url_for("instances.list_instances", company_id=company.public_id))


@bp.route("/<instance_id>")
@login_required
@load_company_context
def detail(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    current_config = instance.current_config()
    pending_config = instance.pending_config()
    current_config_pretty = (
        json.dumps(json.loads(current_config.config_json), indent=2, sort_keys=True)
        if current_config else "{}"
    )

    latest_remote_access = (
        RemoteAccessToken.query
        .filter_by(instance_id=instance.id)
        .order_by(RemoteAccessToken.created_at.desc())
        .first()
    )
    recent_error_reports = (
        AgentErrorReport.query
        .filter_by(instance_id=instance.id)
        .order_by(AgentErrorReport.created_at.desc())
        .limit(20)
        .all()
    )

    pending_kiosk_command = InstanceCommand.query.filter_by(
        instance_id=instance.id, status="pending"
    ).order_by(InstanceCommand.created_at.desc()).first()
    recent_kiosk_commands = InstanceCommand.query.filter_by(instance_id=instance.id).order_by(
        InstanceCommand.created_at.desc()
    ).limit(10).all()

    return render_template(
        "instances/detail.html", company=company, instance=instance, role=g.company_role,
        current_config=current_config, pending_config=pending_config,
        current_config_pretty=current_config_pretty,
        config_history=instance.configs,
        usable_packages=_usable_packages_for(instance),
        active_deployment=instance.active_deployment(),
        deployment_history=instance.deployments,
        latest_remote_access=latest_remote_access,
        recent_error_reports=recent_error_reports,
        pending_kiosk_command=pending_kiosk_command,
        recent_kiosk_commands=recent_kiosk_commands,
    )


@bp.route("/<instance_id>/rename", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def rename(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    name = request.form.get("name", "").strip()
    instance.name = name or None

    time_str = request.form.get("scheduled_update_time", "").strip()
    if request.form.get("clear_update_time"):
        instance.scheduled_update_time = None
    elif time_str:
        try:
            instance.scheduled_update_time = datetime.strptime(time_str, "%H:%M").time()
        except ValueError:
            flash("Update time must be in HH:MM format.", "danger")
            return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    db.session.commit()
    flash("Instance settings updated.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/config/push", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_config")
def push_config(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    raw = request.form.get("config_json", "").strip()
    try:
        parsed = json.loads(raw) if raw else {}
    except ValueError:
        flash("That isn't valid JSON — fix the syntax and try again.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    if not isinstance(parsed, dict):
        flash("Config must be a JSON object (key/value pairs), not a list or scalar.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    # A new push supersedes any still-unacknowledged one — the instance should
    # only ever have one thing to apply at a time.
    existing_pending = instance.pending_config()
    if existing_pending is not None:
        existing_pending.status = "rejected"
        existing_pending.agent_message = "Superseded by a newer push before it was acknowledged."
        existing_pending.acknowledged_at = datetime.utcnow()

    last_version = db.session.query(db.func.max(InstanceConfig.version)).filter_by(
        instance_id=instance.id
    ).scalar() or 0

    config = InstanceConfig(
        instance_id=instance.id,
        version=last_version + 1,
        config_json=json.dumps(parsed, sort_keys=True),
        pushed_by_id=current_user.id,
        status="pending",
    )
    db.session.add(config)
    log_action(company, current_user, "config_pushed", f"{instance.display_name()} v{config.version}")
    db.session.commit()

    flash(f"Configuration v{config.version} queued — it will apply next time the instance checks in.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/config/<int:version>/restore", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_config")
def restore_config(company_id, instance_id, version):
    """Configuration rollback safety (spec Section 43): restoring an older
    version doesn't rewrite history — it pushes a brand-new version whose
    content is a copy of the old one, going through the same
    receive/validate/apply/confirm path as any other push. The version being
    restored FROM stays exactly as it was in history."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    old = InstanceConfig.query.filter_by(instance_id=instance.id, version=version).first()
    if old is None:
        abort(404)

    existing_pending = instance.pending_config()
    if existing_pending is not None:
        existing_pending.status = "rejected"
        existing_pending.agent_message = "Superseded by a config restore before it was acknowledged."
        existing_pending.acknowledged_at = datetime.utcnow()

    last_version = db.session.query(db.func.max(InstanceConfig.version)).filter_by(
        instance_id=instance.id
    ).scalar() or 0

    restored = InstanceConfig(
        instance_id=instance.id,
        version=last_version + 1,
        config_json=old.config_json,
        pushed_by_id=current_user.id,
        status="pending",
    )
    db.session.add(restored)
    log_action(company, current_user, "config_restored", f"{instance.display_name()} restored from v{version} as v{restored.version}")
    db.session.commit()

    flash(f"Restoring v{version}'s content as new version v{restored.version} — it will apply next check-in.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


def _usable_packages_for(instance):
    return UpdatePackage.query.filter_by(status="validated", withdrawn=False).filter(
        UpdatePackage.supported_os.contains(instance.os)
    ).order_by(UpdatePackage.uploaded_at.desc()).all()


def _schedule_update(instance, package, mode, custom_dt_utc, user):
    """Shared by single-instance and bulk push. Returns (deployment, error)."""
    if not package.is_usable():
        return None, f"Package v{package.version} is not usable (invalid or withdrawn)."
    if instance.os not in package.supported_os_list():
        return None, f"Package v{package.version} does not support {instance.os}."

    existing = instance.active_deployment()
    if existing is not None:
        if existing.status in ("scheduled", "waiting"):
            existing.status = "superseded"
            existing.append_log("superseded", "replaced by a newer push before it started")
        else:
            return None, (
                f"Instance already has an update in progress (v{existing.package.version}, "
                f"status: {existing.status}) — wait for it to finish before pushing another."
            )

    try:
        target_time_utc, source = resolve_deployment_target(instance, mode, custom_dt_utc)
    except ValueError as e:
        return None, str(e)

    deployment = UpdateDeployment(
        instance_id=instance.id,
        package_id=package.id,
        requested_by_id=user.id,
        target_time_utc=target_time_utc,
        schedule_source=source,
        previous_version=instance.app_version,
    )
    deployment.append_log("scheduled", f"requested by {user.email}, source={source}")
    db.session.add(deployment)
    return deployment, None


@bp.route("/<instance_id>/updates/schedule", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_updates")
def schedule_update(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    package = UpdatePackage.query.filter_by(public_id=request.form.get("package_id")).first()
    mode = request.form.get("mode", "schedule")
    custom_dt_utc = None
    if mode == "custom":
        raw = request.form.get("custom_datetime", "").strip()
        try:
            custom_dt_utc = datetime.strptime(raw, "%Y-%m-%dT%H:%M")
        except ValueError:
            flash("Enter a valid custom date/time.", "danger")
            return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    if package is None:
        flash("Choose a package to push.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    deployment, error = _schedule_update(instance, package, mode, custom_dt_utc, current_user)
    if error:
        db.session.rollback()
        flash(error, "danger")
    else:
        log_action(company, current_user, "update_pushed", f"{instance.display_name()} -> v{package.version} ({mode})")
        db.session.commit()
        if mode == "now":
            flash(f"Update to v{package.version} pushed immediately.", "success")
        else:
            flash(
                f"Update to v{package.version} scheduled for "
                f"{deployment.target_time_utc.strftime('%Y-%m-%d %H:%M UTC')} "
                f"(source: {deployment.schedule_source}).",
                "success",
            )
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/updates/<deployment_id>/cancel", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_updates")
def cancel_update(company_id, instance_id, deployment_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    deployment = UpdateDeployment.query.filter_by(public_id=deployment_id, instance_id=instance.id).first()
    if deployment is None:
        abort(404)
    if deployment.status not in ("scheduled", "waiting"):
        flash("That update has already started and can no longer be cancelled from here.", "warning")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    deployment.status = "cancelled"
    deployment.cancelled_at = datetime.utcnow()
    deployment.cancelled_by_id = current_user.id
    log_action(company, current_user, "update_cancelled", f"{instance.display_name()} v{deployment.package.version}")
    db.session.commit()
    flash("Scheduled update cancelled.", "info")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/updates/bulk-schedule", methods=["GET", "POST"])
@login_required
@load_company_context
@permission_required("manage_updates")
def bulk_schedule(company_id):
    company = g.company
    instances = Instance.query.filter_by(company_id=company.id).order_by(Instance.created_at.desc()).all()
    packages = UpdatePackage.query.filter_by(status="validated", withdrawn=False).order_by(
        UpdatePackage.uploaded_at.desc()
    ).all()

    if request.method == "POST":
        package = UpdatePackage.query.filter_by(public_id=request.form.get("package_id")).first()
        mode = request.form.get("mode", "schedule")
        instance_ids = request.form.getlist("instance_ids")

        custom_dt_utc = None
        if mode == "custom":
            raw = request.form.get("custom_datetime", "").strip()
            try:
                custom_dt_utc = datetime.strptime(raw, "%Y-%m-%dT%H:%M")
            except ValueError:
                flash("Enter a valid custom date/time.", "danger")
                return redirect(url_for("instances.bulk_schedule", company_id=company.public_id))

        if package is None or not instance_ids:
            flash("Choose a package and at least one instance.", "danger")
            return redirect(url_for("instances.bulk_schedule", company_id=company.public_id))

        succeeded, failed = [], []
        for pub_id in instance_ids:
            instance = Instance.query.filter_by(public_id=pub_id, company_id=company.id).first()
            if instance is None:
                continue
            deployment, error = _schedule_update(instance, package, mode, custom_dt_utc, current_user)
            if error:
                failed.append((instance.display_name(), error))
            else:
                succeeded.append(instance.display_name())
        db.session.commit()

        if succeeded:
            flash(f"Scheduled for {len(succeeded)} instance(s): {', '.join(succeeded)}.", "success")
            log_action(company, current_user, "bulk_update_pushed", f"{package.version} -> {', '.join(succeeded)}")
        for name, error in failed:
            flash(f"{name}: {error}", "danger")

        return redirect(url_for("instances.list_instances", company_id=company.public_id))

    return render_template("instances/bulk_schedule.html", company=company, instances=instances, packages=packages)


@bp.route("/<instance_id>/remote-access/request", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def request_remote_access(company_id, instance_id):
    from datetime import timedelta
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    token = RemoteAccessToken(
        instance_id=instance.id,
        requested_by_id=current_user.id,
        expires_at=datetime.utcnow() + timedelta(minutes=10),
    )
    db.session.add(token)
    log_action(company, current_user, "remote_access_requested", instance.display_name())
    db.session.commit()

    flash(
        f"Remote access token issued (valid 10 minutes). The Instance Agent will "
        f"pick it up on its next poll and report back — the tunnel broker that "
        f"would actually open a session doesn't exist yet, so expect an "
        f"'unsupported' outcome, honestly reported rather than silently ignored.",
        "info",
    )
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/audit-log")
@login_required
@load_company_context
@permission_required("manage_members")
def audit_log(company_id):
    from app.models import AuditLogEntry
    company = g.company
    entries = AuditLogEntry.query.filter_by(company_id=company.id).order_by(
        AuditLogEntry.created_at.desc()
    ).limit(200).all()
    return render_template("instances/audit_log.html", company=company, entries=entries, role=g.company_role)


def _queue_command(instance, command_type, payload=None):
    """Only one pending command per instance at a time — a new one
    supersedes an old still-unacknowledged one, same pattern used for
    config pushes and update pushes elsewhere in this file."""
    import json as _json
    existing = InstanceCommand.query.filter_by(instance_id=instance.id, status="pending").first()
    if existing is not None:
        existing.status = "failed"
        existing.result_message = "Superseded by a newer command before the Agent picked it up."
        existing.acked_at = datetime.utcnow()

    command = InstanceCommand(
        instance_id=instance.id, command_type=command_type,
        payload_json=_json.dumps(payload) if payload else None,
        requested_by_id=current_user.id,
    )
    db.session.add(command)
    return command


@bp.route("/<instance_id>/kiosk/start", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_start(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "start")
    log_action(company, current_user, "kiosk_start_requested", instance.display_name())
    db.session.commit()
    flash("Start requested — the Agent will pick this up on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/stop", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_stop(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "stop")
    log_action(company, current_user, "kiosk_stop_requested", instance.display_name())
    db.session.commit()
    flash("Stop requested — the Agent will pick this up on its next poll.", "warning")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/restart", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_restart(company_id, instance_id):
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)
    _queue_command(instance, "restart")
    log_action(company, current_user, "kiosk_restart_requested", instance.display_name())
    db.session.commit()
    flash("Restart requested — the Agent will pick this up on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))


@bp.route("/<instance_id>/kiosk/configure", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def kiosk_configure(company_id, instance_id):
    """Sets what command the Agent uses to start the kiosk process — the
    piece that was completely missing before: there was no way to tell an
    already-installed Agent what to actually run, short of hand-editing
    settings.json on the machine itself."""
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    start_command = request.form.get("kiosk_start_command", "").strip()
    working_dir = request.form.get("kiosk_working_dir", "").strip()
    health_check_url = request.form.get("kiosk_health_check_url", "").strip()
    health_check_command = request.form.get("kiosk_health_check_command", "").strip()

    _queue_command(instance, "configure", payload={
        "kiosk_start_command": start_command,
        "kiosk_working_dir": working_dir,
        "kiosk_health_check_url": health_check_url,
        "kiosk_health_check_command": health_check_command,
    })
    log_action(company, current_user, "kiosk_configure_requested",
               f"{instance.display_name()}: {start_command or '(cleared)'}")
    db.session.commit()
    flash("Configuration queued — the Agent will apply it (and start the process) on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

INSTANCES_EOF_MARKER

cat > app/templates/instances/detail.html << 'DETAIL_EOF_MARKER'
{% extends "base.html" %}
{% block title %}{{ instance.display_name() }} — {{ company.name }}{% endblock %}
{% block content %}
<div class="page-header">
  <div class="titles">
    <a href="{{ url_for('instances.list_instances', company_id=company.public_id) }}" class="crumb">← Fleet</a>
    <h1>{{ instance.display_name() }}</h1>
    <div class="page-sub">
      {% if instance.connection_status == 'online' %}
        <span class="pill pill-green">Online</span>
      {% else %}
        <span class="pill pill-muted">Offline</span>
      {% endif %}
      <span>{{ instance.os }}{% if instance.os_version %} {{ instance.os_version }}{% endif %}</span>
    </div>
  </div>
</div>

<div class="panel">
  <h2>General</h2>
  <table class="kv-table">
    <tr><th>Instance ID</th><td><code style="font-size:11.5px;">{{ instance.public_id }}</code></td></tr>
    <tr><th>Hostname</th><td>{{ instance.hostname or '—' }}</td></tr>
    <tr><th>Operating system</th><td>{{ instance.os }} {{ instance.os_version or '' }}</td></tr>
    <tr><th>Agent version</th><td class="mono">{{ instance.agent_version or '—' }}</td></tr>
    <tr><th>Application version</th><td class="mono">{{ instance.app_version or '—' }}</td></tr>
    <tr><th>Registered</th><td class="muted">{{ instance.created_at.strftime('%Y-%m-%d %H:%M UTC') }}</td></tr>
  </table>
</div>

<div class="panel">
  <h2>Connection</h2>
  <table class="kv-table">
    <tr><th>Status</th><td>{{ instance.connection_status }}</td></tr>
    <tr><th>Last seen</th><td class="muted">{{ instance.last_seen_at.strftime('%Y-%m-%d %H:%M UTC') if instance.last_seen_at else 'never' }}</td></tr>
    <tr><th>Local IP</th><td class="mono">{{ instance.local_ip or '—' }}</td></tr>
    <tr><th>Public IP</th><td class="mono">{{ instance.public_ip or '—' }}</td></tr>
    <tr><th>Port</th><td class="mono">{{ instance.port or '—' }}</td></tr>
    <tr><th>Remote tunnel</th>
      <td>
        {{ 'Connected' if instance.tunnel_connected else 'Not connected' }}
        {% if latest_remote_access %}
          <br>
          <span class="muted" style="font-size:12.5px;">
            Last request: {{ latest_remote_access.created_at.strftime('%Y-%m-%d %H:%M UTC') }} by {{ latest_remote_access.requested_by.full_name }} —
            {% if latest_remote_access.status == 'pending' %}
              <span class="pill pill-amber">Waiting for agent</span>
            {% elif latest_remote_access.status == 'connected' %}
              <span class="pill pill-green">Connected</span>
            {% elif latest_remote_access.status == 'unsupported' %}
              <span class="pill pill-muted">Unsupported (no tunnel broker yet)</span>
            {% else %}
              <span class="pill pill-red">Failed</span>
            {% endif %}
            {% if latest_remote_access.status_message %}<br>{{ latest_remote_access.status_message }}{% endif %}
          </span>
        {% endif %}
      </td>
    </tr>
  </table>
  {% if role in ["owner", "administrator", "manager"] %}
    <form method="post" action="{{ url_for('instances.request_remote_access', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:14px;">
      <button type="submit" class="btn btn-secondary btn-sm">Request remote access token</button>
    </form>
    <p class="muted" style="font-size:12px; margin-top:8px; margin-bottom:0;">
      Issues a 10-minute token for opening this kiosk's local UI through the
      remote tunnel. The tunnel server itself isn't built yet — this tracks
      the request only.
    </p>
  {% endif %}
</div>

<div class="panel">
  <h2>Kiosk Process</h2>
  <table class="kv-table">
    <tr><th>Status</th>
      <td>
        {% if instance.kiosk_process_status == 'running' %}
          <span class="pill pill-green">Running</span>
        {% elif instance.kiosk_process_status == 'stopped' %}
          <span class="pill pill-amber">Stopped</span>
        {% elif instance.kiosk_process_status == 'giving_up' %}
          <span class="pill pill-red">Crash-looping — Agent gave up restarting it</span>
        {% elif instance.kiosk_process_status == 'not_configured' %}
          <span class="pill pill-muted">Not configured</span>
        {% else %}
          <span class="pill pill-muted">Unknown (no heartbeat yet)</span>
        {% endif %}
      </td>
    </tr>
    <tr><th>Start command</th><td class="mono">{{ instance.kiosk_process_status and '(reported via heartbeat only — set below)' or '—' }}</td></tr>
  </table>

  {% if pending_kiosk_command %}
    <div class="flash flash-warning" style="margin-top:12px;">
      A "{{ pending_kiosk_command.command_type }}" command is queued — waiting for the Agent's next poll.
    </div>
  {% endif %}

  {% if role in ["owner", "administrator", "manager"] %}
    <div style="display:flex; gap:8px; margin-top:14px;">
      <form method="post" action="{{ url_for('instances.kiosk_start', company_id=company.public_id, instance_id=instance.public_id) }}">
        <button type="submit" class="btn btn-secondary btn-sm">Start</button>
      </form>
      <form method="post" action="{{ url_for('instances.kiosk_stop', company_id=company.public_id, instance_id=instance.public_id) }}">
        <button type="submit" class="btn btn-secondary btn-sm">Stop</button>
      </form>
      <form method="post" action="{{ url_for('instances.kiosk_restart', company_id=company.public_id, instance_id=instance.public_id) }}">
        <button type="submit" class="btn btn-secondary btn-sm">Restart</button>
      </form>
    </div>

    <details style="margin-top:16px;">
      <summary style="cursor:pointer; color:var(--muted); font-size:13px;">Configure what starts the kiosk process</summary>
      <form method="post" action="{{ url_for('instances.kiosk_configure', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:12px;">
        <label>Start command</label>
        <input type="text" name="kiosk_start_command" placeholder="e.g. C:\OpsLabAgent\python\python.exe C:\OpsLabKiosk\run.py">
        <label>Working directory (optional)</label>
        <input type="text" name="kiosk_working_dir">
        <label>Health check URL (optional — e.g. http://127.0.0.1:8420/health)</label>
        <input type="text" name="kiosk_health_check_url">
        <label>Health check command (optional, alternative to a URL)</label>
        <input type="text" name="kiosk_health_check_command">
        <button type="submit" class="btn btn-sm" style="margin-top:12px;">Save &amp; apply</button>
      </form>
      <p class="muted" style="font-size:12px; margin-top:8px;">
        Leave the start command blank and save to clear supervision entirely.
        Applying this restarts the kiosk process using the new command.
      </p>
    </details>

    {% if recent_kiosk_commands %}
      <h3 style="font-size:13px; margin-top:20px; color:var(--muted);">Recent commands</h3>
      <table class="kv-table" style="font-size:12.5px;">
        {% for cmd in recent_kiosk_commands %}
          <tr>
            <td class="mono">{{ cmd.command_type }}</td>
            <td>
              {% if cmd.status == 'pending' %}<span class="pill pill-amber">Pending</span>
              {% elif cmd.status == 'success' %}<span class="pill pill-green">Success</span>
              {% else %}<span class="pill pill-red">Failed</span>{% endif %}
            </td>
            <td class="muted">{{ cmd.result_message or '' }}</td>
            <td class="muted">{{ cmd.created_at.strftime('%Y-%m-%d %H:%M UTC') }}</td>
          </tr>
        {% endfor %}
      </table>
    {% endif %}
  {% endif %}
</div>

<div class="panel">
  <h2>Configuration</h2>
  <p class="muted">
    Sent to the instance next time it checks in (<code>GET /api/v1/instances/config</code>);
    it applies and reports back via <code>POST /api/v1/instances/config/ack</code>.
  </p>

  {% if pending_config %}
    <div class="flash flash-warning">
      Version {{ pending_config.version }} is queued, waiting for the instance to acknowledge it.
    </div>
  {% endif %}

  <table class="kv-table" style="margin-bottom:16px;">
    <tr><th>Current applied version</th><td>{{ current_config.version if current_config else '— (none applied yet)' }}</td></tr>
  </table>

  <label>Current config (read-only)</label>
  <textarea readonly rows="6">{{ current_config_pretty }}</textarea>

  {% if role in ["owner", "administrator", "manager"] %}
  <form method="post" action="{{ url_for('instances.push_config', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:16px;">
    <label>Push new configuration (JSON object)</label>
    <textarea name="config_json" rows="6" placeholder='{{ '{' }}"kiosk_name": "Reception", "auto_logout_minutes": 2{{ '}' }}'>{{ current_config_pretty if current_config else '' }}</textarea>
    <button type="submit" style="margin-top:12px;">Push configuration</button>
  </form>
  {% endif %}

  {% if config_history %}
  <h2 style="margin-top:24px;">Configuration history</h2>
  <div class="table-scroll">
  <table>
    <thead><tr><th>Version</th><th>Status</th><th>Pushed by</th><th>Pushed</th><th>Acknowledged</th><th class="wrap-cell">Message</th><th></th></tr></thead>
    <tbody>
      {% for c in config_history %}
        <tr>
          <td class="mono">v{{ c.version }}</td>
          <td>
            {% if c.status == 'applied' %}
              <span class="pill pill-green">Applied</span>
            {% elif c.status == 'pending' %}
              <span class="pill pill-amber">Pending</span>
            {% else %}
              <span class="pill pill-red">{{ c.status|capitalize }}</span>
            {% endif %}
          </td>
          <td>{{ c.pushed_by.full_name }}</td>
          <td class="muted">{{ c.pushed_at.strftime('%Y-%m-%d %H:%M UTC') }}</td>
          <td class="muted">{{ c.acknowledged_at.strftime('%Y-%m-%d %H:%M UTC') if c.acknowledged_at else '—' }}</td>
          <td class="muted wrap-cell">{{ c.agent_message or '—' }}</td>
          <td>
            {% if role in ["owner", "administrator", "manager"] and c.status == 'applied' %}
              <form method="post" action="{{ url_for('instances.restore_config', company_id=company.public_id, instance_id=instance.public_id, version=c.version) }}">
                <button type="submit" class="btn btn-secondary btn-sm">Restore</button>
              </form>
            {% endif %}
          </td>
        </tr>
      {% endfor %}
    </tbody>
  </table>
  </div>
  {% endif %}
</div>

<div class="panel">
  <h2>Updates</h2>

  <table class="kv-table" style="margin-bottom:14px;">
    <tr><th>Current version</th><td class="mono">{{ instance.app_version or '—' }}</td></tr>
    <tr><th>Last Known Good</th><td class="mono">{{ instance.last_known_good_version or '— (no successful update yet)' }}</td></tr>
  </table>

  {% if active_deployment %}
    {% set d = active_deployment %}
    <div class="flash {{ 'flash-danger' if d.status in ['failed','rolling_back'] else 'flash-warning' }}">
      <strong>v{{ d.package.version }}</strong> — status: <strong>{{ d.status.replace('_',' ')|capitalize }}</strong>
      {% if d.status in ['scheduled','waiting'] %}
        (target: {{ d.target_time_utc.strftime('%Y-%m-%d %H:%M UTC') }}, source: {{ d.schedule_source }})
      {% endif %}
      {% if d.health_check_message %}<br><span class="muted">Health check: {{ d.health_check_message }}</span>{% endif %}
      {% if d.rollback_reason %}<br><span class="muted">Rollback reason: {{ d.rollback_reason }}</span>{% endif %}
      {% if role in ["owner", "administrator"] and d.status in ["scheduled", "waiting"] %}
        <form method="post" action="{{ url_for('instances.cancel_update', company_id=company.public_id, instance_id=instance.public_id, deployment_id=d.public_id) }}" style="display:inline; margin-left:10px;">
          <button type="submit" class="btn btn-danger btn-sm">Cancel</button>
        </form>
      {% endif %}
    </div>
  {% endif %}

  {% if role in ["owner", "administrator"] %}
    {% if usable_packages %}
      <form method="post" action="{{ url_for('instances.schedule_update', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:10px;">
        <label>Package</label>
        <select name="package_id">
          {% for p in usable_packages %}
            <option value="{{ p.public_id }}">v{{ p.version }}</option>
          {% endfor %}
        </select>
        <label>When</label>
        <select name="mode" onchange="document.getElementById('custom-dt').style.display = this.value === 'custom' ? 'block' : 'none';">
          <option value="now">Update now</option>
          <option value="schedule" selected>Use configured schedule (kiosk / company / 9PM UK default)</option>
          <option value="custom">Custom date &amp; time</option>
        </select>
        <div id="custom-dt" style="display:none;">
          <label>Custom date &amp; time (UTC)</label>
          <input type="datetime-local" name="custom_datetime">
        </div>
        <button type="submit" style="margin-top:14px;">Push update</button>
      </form>
    {% else %}
      <p class="muted">No validated packages support {{ instance.os }} yet.</p>
    {% endif %}
  {% endif %}

  {% if deployment_history %}
  <h2 style="margin-top:24px;">Update history</h2>
  <div class="table-scroll">
  <table>
    <thead><tr><th>Version</th><th>Status</th><th>Target time</th><th>Started</th><th>Completed</th><th>Health check</th><th>Requested by</th></tr></thead>
    <tbody>
      {% for d in deployment_history %}
        <tr>
          <td class="mono">v{{ d.package.version }}</td>
          <td>
            {% if d.status == 'successful' %}
              <span class="pill pill-green">Successful</span>
            {% elif d.status in ['failed','rolled_back'] %}
              <span class="pill pill-red">{{ d.status.replace('_',' ')|capitalize }}</span>
            {% elif d.status in ['cancelled','superseded'] %}
              <span class="pill pill-muted">{{ d.status|capitalize }}</span>
            {% else %}
              <span class="pill pill-amber">{{ d.status.replace('_',' ')|capitalize }}</span>
            {% endif %}
          </td>
          <td class="muted">{{ d.target_time_utc.strftime('%Y-%m-%d %H:%M UTC') }}</td>
          <td class="muted">{{ d.started_at.strftime('%Y-%m-%d %H:%M UTC') if d.started_at else '—' }}</td>
          <td class="muted">{{ d.completed_at.strftime('%Y-%m-%d %H:%M UTC') if d.completed_at else '—' }}</td>
          <td class="muted">
            {% if d.health_check_passed is none %}—
            {% elif d.health_check_passed %}<span style="color:var(--green);">Passed</span>
            {% else %}<span style="color:var(--red);">Failed</span>
            {% endif %}
          </td>
          <td class="muted">{{ d.requested_by.full_name }}</td>
        </tr>
      {% endfor %}
    </tbody>
  </table>
  </div>
  {% endif %}

  <p class="muted" style="margin-top:16px; margin-bottom:0;">Instance-level history above; fleet-wide stats are on the <a href="{{ url_for('instances.list_instances', company_id=company.public_id) }}">fleet overview</a>.</p>
</div>

<div class="panel">
  <h2>Diagnostics</h2>
  <table class="kv-table" style="margin-bottom:14px;">
    <tr><th>Health status</th>
      <td>
        {% if instance.connection_status == 'online' %}
          <span style="color:var(--green);">Healthy — checking in normally</span>
        {% else %}
          <span class="muted">Offline — no recent heartbeat</span>
        {% endif %}
      </td>
    </tr>
    <tr><th>Remote tunnel</th><td>{{ 'Connected' if instance.tunnel_connected else 'Not connected' }}</td></tr>
  </table>

  {% if active_deployment and active_deployment.status_log %}
    <h3>Current update event log</h3>
    <textarea readonly rows="6">{{ active_deployment.status_log }}</textarea>
  {% elif deployment_history and deployment_history[0].status_log %}
    <h3>Most recent update event log</h3>
    <textarea readonly rows="6">{{ deployment_history[0].status_log }}</textarea>
  {% else %}
    <p class="muted" style="margin:0;">No update events logged yet.</p>
  {% endif %}

  {% if recent_error_reports %}
    <h3 style="margin-top:20px;">Recent agent errors</h3>
    <div class="table-scroll">
    <table>
      <thead><tr><th>When</th><th>Level</th><th>Logger</th><th class="wrap-cell">Message</th></tr></thead>
      <tbody>
        {% for e in recent_error_reports %}
          <tr>
            <td class="muted">{{ e.created_at.strftime('%Y-%m-%d %H:%M UTC') }}</td>
            <td>
              {% if e.level == 'CRITICAL' %}
                <span class="pill pill-red">Critical</span>
              {% else %}
                <span class="pill pill-amber">Error</span>
              {% endif %}
            </td>
            <td class="muted mono" style="font-size:12px;">{{ e.logger_name or '—' }}</td>
            <td class="wrap-cell">
              {{ e.message }}
              {% if e.suppressed_since_last %}<span class="muted"> (+{{ e.suppressed_since_last }} suppressed since last report)</span>{% endif %}
            </td>
          </tr>
        {% endfor %}
      </tbody>
    </table>
    </div>
    <p class="muted" style="margin-top:10px; margin-bottom:0; font-size:12px;">
      Best-effort delivery from the Agent's error reporter — a network blip while reporting isn't retried, so this is what the Agent managed to tell us, not a complete log.
    </p>
  {% endif %}

  <p class="muted" style="margin-top:12px; margin-bottom:0; font-size:12px;">
    Full agent-side log retrieval (spec Section 35) requires more than error-level events — this shows what's been reported through the
    update lifecycle, heartbeat, and error reporter so far.
  </p>
</div>

{% if role in ["owner", "administrator", "manager"] %}
<div class="panel">
  <h2>Instance settings</h2>
  <form method="post" action="{{ url_for('instances.rename', company_id=company.public_id, instance_id=instance.public_id) }}">
    <label>Display name</label>
    <input type="text" name="name" value="{{ instance.name or '' }}" placeholder="{{ instance.hostname or 'e.g. Reception' }}">
    <label>Kiosk-specific update time (UK local, HH:MM) — overrides the company/system default</label>
    <input type="text" name="scheduled_update_time" placeholder="21:00"
           value="{{ instance.scheduled_update_time.strftime('%H:%M') if instance.scheduled_update_time else '' }}">
    <label class="checkline">
      <input type="checkbox" name="clear_update_time">
      Clear override (inherit company/system default)
    </label>
    <button type="submit" style="margin-top:16px;">Save</button>
  </form>
</div>
{% endif %}
{% endblock %}

DETAIL_EOF_MARKER

base64 -d > app/static/installers/opslab-agent.tar.gz << 'TARBALL_EOF_MARKER'
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
TARBALL_EOF_MARKER
