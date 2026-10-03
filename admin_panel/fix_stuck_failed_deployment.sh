#!/usr/bin/env bash
# Fixes a real bug hit on the actual Ewan deployment just now: once a
# deployment reaches "failed" (including a failed-rollback case - the
# first-ever install has no previous_version to restore to, so its
# automatic rollback attempt fails too), it stays in IN_FLIGHT_STATUSES
# forever. Instance.active_deployment() keeps returning it, so
# instances.py::_schedule_update's "Instance already has an update in
# progress ... wait for it to finish" guard fires PERMANENTLY - there is
# no legal next transition ("failed" only allows -> "rolling_back", which
# can only lead back to "rolled_back" or "failed" again) that could ever
# clear it. A push over Ewan's failed v1.0.0 hit exactly this: "Instance
# already has an update in progress (v1.0.0, status: failed) — wait for it
# to finish before pushing another" - forever, since it already finished.
#
# Fixed by removing "failed" from IN_FLIGHT_STATUSES (added to
# TERMINAL_STATUSES instead, for accuracy - that list is currently unused
# elsewhere but documents intent). Every path that reports "failed" has
# already done everything it's going to do for that agent run - a rollback
# attempt, if any, already happened synchronously within the same
# run_update_cycle call before "failed" was ever reported - so nothing
# comes back later to move it further. A fresh push is exactly the correct
# next step after a failure, not something that should be blocked pending
# a retry that was never going to happen.
#
# Verified: reproduced Ewan's exact stuck state (a deployment with
# status="failed", previous_version=None) against a real DB -
# active_deployment() incorrectly returned it before the fix, correctly
# returns None after; _schedule_update() then successfully schedules a new
# push over it. Also verified every GENUINELY in-flight status
# (downloading/installing/health_check/rolling_back) still correctly
# blocks a second push - this fix is scoped to "failed" only.
#
# Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -e app/models.py ]; then
    echo "Error: expected to find 'app/models.py' here - run this from the admin_panel repo root."
    exit 1
fi

echo "==> Writing app/models.py"
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

COMMAND_TYPES = ["start", "stop", "restart", "configure", "run_command"]
COMMAND_STATUSES = ["pending", "success", "failed"]


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

echo "==> Verifying"
python3 -m py_compile app/models.py && echo "    compiles OK"
if grep -q '"health_check", "failed", "rolling_back"' app/models.py; then
    echo "    ERROR: old buggy IN_FLIGHT_STATUSES list still present!"
    exit 1
fi
grep -q '"health_check", "rolling_back"' app/models.py && echo "    IN_FLIGHT_STATUSES no longer includes 'failed' — confirmed"

echo ""
echo "==> Restarting the admin panel app"
pkill -f "admin_panel/run.py" 2>/dev/null || true
fuser -k 6090/tcp 2>/dev/null || true
sleep 1
source venv/bin/activate
nohup python run.py > app.log 2>&1 &
disown
sleep 2
tail -n 10 app.log

echo ""
echo "Done. Pushing v1.0.1 to Ewan (or any instance stuck on a failed deployment)"
echo "will now work immediately - no waiting, nothing else to clear first."
