#!/usr/bin/env bash
# Adds a generic "run a command on this kiosk" channel - real remote code
# execution over the same authenticated command queue as start/stop/
# restart/configure, for "add or install things on the kiosk remotely"
# where no real remote-desktop/tunnel exists yet (the "Request remote
# access token" button only ever tracked the request - no tunnel server
# behind it). NOT sandboxed or allow-listed by design: restricting it to a
# safe subset would defeat the actual ask. The trust boundary is the
# existing manage_instances permission check on the way in - an admin with
# that permission can already push arbitrary code to this exact machine
# via an Update package, just with more ceremony and latency.
#
# New command_type "run_command" on the same InstanceCommand queue/table
# as start/stop/restart/configure:
#   - app/models.py: added to COMMAND_TYPES.
#   - app/blueprints/instances.py: new /run-command route, queues it.
#   - app/templates/instances/detail.html: a "Run a command on this kiosk"
#     form, and Recent Commands now renders result_message with
#     white-space:pre-wrap/monospace so multi-line command output is
#     actually readable instead of squashed onto one line.
#   - agent/commands.py: executes via subprocess (shell=True, 120s
#     timeout, output capped at 4000 chars with a truncation notice),
#     reports exit code + output back through the existing
#     ack_command/result_message path - no new UI surface needed to see
#     what happened, it shows up in the same Recent Commands table.
#
# Verified end-to-end this session against a real live server + a real
# agent: queued from a simulated "Run" click, polled and executed over
# real HTTP, real subprocess ran, real output (and a real nonzero exit
# code case, a timeout case, and output truncation) all landed correctly
# in InstanceCommand.result_message.
#
# Run from inside /root/admin_panel.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

for req in agent requirements.txt service_files app/blueprints; do
    if [ ! -e "$req" ]; then
        echo "Error: expected to find '$req' here - run this from the admin_panel repo root."
        exit 1
    fi
done

echo "==> Writing app/models.py"
cat > app/models.py << 'FILEEOF_5222835054950469096'
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

FILEEOF_5222835054950469096

echo "==> Writing app/blueprints/instances.py"
cat > app/blueprints/instances.py << 'FILEEOF_787865334245344412'
import json
from datetime import datetime, timedelta

from flask import Blueprint, render_template, redirect, url_for, request, flash, g, abort

from app.extensions import db
from app.models import (
    Instance, EnrollmentToken, InstanceConfig, UpdatePackage, UpdateDeployment,
    RemoteAccessToken, AgentErrorReport, log_action, InstanceCommand, StagedRolloutInstance,
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


@bp.route("/<instance_id>/delete", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def delete_instance(company_id, instance_id):
    """Permanently removes an instance and everything recorded against it.
    The Agent itself is untouched by this (there's no uninstall call in the
    API - it would just re-register as a brand new instance on its next
    heartbeat if it's still running with valid credentials) - this only
    forgets the Admin Panel's record of it.

    Instance.configs and Instance.deployments already cascade via their
    relationship() definitions, but RemoteAccessToken, AgentErrorReport,
    StagedRolloutInstance, and InstanceCommand only have a plain
    nullable=False foreign key with no ORM-level cascade - deleting the
    Instance row directly would hit an integrity error on whichever of
    those four has rows first. Deleted explicitly here instead of adding
    cascade="all, delete-orphan" to four more relationships for a path this
    rarely used only needs once.
    """
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    display_name = instance.display_name()

    RemoteAccessToken.query.filter_by(instance_id=instance.id).delete()
    AgentErrorReport.query.filter_by(instance_id=instance.id).delete()
    StagedRolloutInstance.query.filter_by(instance_id=instance.id).delete()
    InstanceCommand.query.filter_by(instance_id=instance.id).delete()

    log_action(company, current_user, "instance_deleted", display_name)
    db.session.delete(instance)  # cascades to configs + deployments via their relationships
    db.session.commit()

    flash(f"{display_name} has been deleted.", "success")
    return redirect(url_for("instances.list_instances", company_id=company.public_id))


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


@bp.route("/<instance_id>/run-command", methods=["POST"])
@login_required
@load_company_context
@permission_required("manage_instances")
def run_command(company_id, instance_id):
    """Generic remote execution — real command execution on the kiosk
    machine via the same authenticated command channel as start/stop/
    restart/configure, not a remote-desktop/screen-sharing session (no
    tunnel server exists for that — see the "Request remote access token"
    button elsewhere on this page, which is honest that it only tracks the
    request). This is genuinely capable of "add or install things on the
    kiosk remotely" (run an msiexec, a pip install, a PowerShell one-liner)
    without expanding the system's actual trust boundary: an admin with
    manage_instances permission can already push arbitrary code to this
    exact machine via an Update package, just with more ceremony and
    latency. Output is returned through the same result_message field the
    Recent Commands table already renders - no new UI surface needed to
    see what happened.
    """
    company = g.company
    instance = Instance.query.filter_by(public_id=instance_id, company_id=company.id).first()
    if instance is None:
        abort(404)

    command_text = request.form.get("command", "").strip()
    if not command_text:
        flash("Enter a command to run.", "danger")
        return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

    _queue_command(instance, "run_command", payload={"command": command_text})
    log_action(company, current_user, "run_command_requested", f"{instance.display_name()}: {command_text}")
    db.session.commit()
    flash("Command queued — the Agent will run it (and report output) on its next poll.", "success")
    return redirect(url_for("instances.detail", company_id=company.public_id, instance_id=instance.public_id))

FILEEOF_787865334245344412

echo "==> Writing app/templates/instances/detail.html"
cat > app/templates/instances/detail.html << 'FILEEOF_6663881895340745753'
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

    <details style="margin-top:16px;">
      <summary style="cursor:pointer; color:var(--muted); font-size:13px;">Run a command on this kiosk</summary>
      <form method="post" action="{{ url_for('instances.run_command', company_id=company.public_id, instance_id=instance.public_id) }}" style="margin-top:12px;">
        <label>Command</label>
        <input type="text" name="command" class="mono" placeholder="e.g. msiexec /i C:\Downloads\driver.msi /qn">
        <button type="submit" class="btn btn-sm" style="margin-top:12px;">Run</button>
      </form>
      <p class="muted" style="font-size:12px; margin-top:8px;">
        Runs on the kiosk exactly as typed (its own shell — cmd.exe on Windows, sh on Linux), with no
        restrictions and no sandbox. Output (or the exit code) shows up below in Recent commands once
        the Agent picks it up. There's no live remote-desktop session yet — this is one-shot execution,
        not an interactive shell.
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
            <td class="muted" style="white-space:pre-wrap; font-family:monospace; font-size:11.5px; max-width:420px;">{{ cmd.result_message or '' }}</td>
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

{% if role in ["owner", "administrator"] %}
<div class="panel">
  <h2>Danger zone</h2>
  <p class="muted">Permanently removes this instance and its config, update, and command history from the Admin Panel. Does not uninstall the Agent itself — if it's still running with valid credentials, it will re-register as a new instance on its next heartbeat.</p>
  <form method="post" action="{{ url_for('instances.delete_instance', company_id=company.public_id, instance_id=instance.public_id) }}" onsubmit="return confirm('Permanently delete {{ instance.display_name()|e }}? This cannot be undone.');">
    <button type="submit" class="btn btn-danger">Delete this instance</button>
  </form>
</div>
{% endif %}
{% endblock %}

FILEEOF_6663881895340745753

echo "==> Writing agent/commands.py (via agent tarball extraction, so the served install.ps1 payload and this repo's own ./agent stay identical)"
TMP_EXTRACT="$(mktemp -d)"
base64 -d > "$TMP_EXTRACT/opslab-agent.tar.gz" << 'AGENT_TAR_EOF_MARKER'
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
AGENT_TAR_EOF_MARKER
tar -xzf "$TMP_EXTRACT/opslab-agent.tar.gz" -C "$TMP_EXTRACT"

if ! grep -q "_run_remote_command" "$TMP_EXTRACT/agent/commands.py"; then
    echo "    ERROR: fix not found in the extracted agent payload!"
    rm -rf "$TMP_EXTRACT"
    exit 1
fi

rm -f agent/config.py.bak
cp -f "$TMP_EXTRACT/agent/"*.py agent/
cp -f "$TMP_EXTRACT/service_files/windows/opslab_agent_service.py" service_files/windows/opslab_agent_service.py
echo "    Updated agent/*.py in this repo."

echo "==> Rewriting app/static/installers/opslab-agent.tar.gz (served by /install.ps1's fallback download)"
cp -f "$TMP_EXTRACT/opslab-agent.tar.gz" app/static/installers/opslab-agent.tar.gz
rm -rf "$TMP_EXTRACT"

echo "==> Verifying"
python3 -m py_compile app/blueprints/instances.py app/models.py && echo "    admin_panel python files compile OK"
tar -tzf app/static/installers/opslab-agent.tar.gz > /dev/null && echo "    served agent tarball is readable"

echo ""
echo "Done. This needs a real app restart (Python + template changes):"
echo "    pkill -f 'admin_panel/run.py'; fuser -k 6090/tcp 2>/dev/null"
echo "    cd /root/admin_panel && source venv/bin/activate && nohup python run.py > app.log 2>&1 & disown"
echo ""
echo "Already-enrolled instances (e.g. Ewan) pick this up on their own next self-update"
echo "or reinstall, same as every other agent-side fix in this series - the Admin Panel"
echo "side (the new form, the route) is live immediately after the restart above,"
echo "but an old Agent won't recognize 'run_command' as a command_type until updated."
