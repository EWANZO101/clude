import uuid
from datetime import datetime, timedelta

from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

from app.extensions import db


def gen_uuid():
    return str(uuid.uuid4())


class Role:
    USER = "user"
    ADMIN = "admin"
    SUPPORT = "support"


class User(UserMixin, db.Model):
    __tablename__ = "users"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(20), default=Role.USER, server_default=Role.USER, nullable=False)

    is_temporary = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)
    email_verified = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)

    totp_secret = db.Column(db.String(64), nullable=True)
    totp_enabled = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)

    is_active_flag = db.Column("is_active", db.Boolean, default=True, server_default=db.text("1"), nullable=False)
    is_suspended = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)
    force_logout_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)
    expires_at = db.Column(db.DateTime, nullable=True)  # only for temp accounts
    last_login_at = db.Column(db.DateTime, nullable=True)
    last_login_ip = db.Column(db.String(64), nullable=True)

    exports = db.relationship("Export", backref="owner", lazy="dynamic",
                               cascade="all, delete-orphan")

    def set_password(self, raw_password):
        self.password_hash = generate_password_hash(raw_password)

    def check_password(self, raw_password):
        return check_password_hash(self.password_hash, raw_password)

    def mark_temporary(self, lifetime: timedelta):
        self.is_temporary = True
        self.expires_at = datetime.utcnow() + lifetime

    @property
    def is_expired(self):
        return bool(self.is_temporary and self.expires_at and datetime.utcnow() > self.expires_at)

    @property
    def is_active(self):
        return self.is_active_flag and not self.is_suspended and not self.is_expired

    def is_admin(self):
        return self.role == Role.ADMIN

    def __repr__(self):
        return f"<User {self.email}>"


class ExportStatus:
    PENDING = "pending"
    RUNNING = "running"
    COMPLETE = "complete"
    FAILED = "failed"
    EXPIRED = "expired"


class Export(db.Model):
    __tablename__ = "exports"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)

    source_os = db.Column(db.String(20), nullable=True)   # windows / linux
    status = db.Column(db.String(20), default=ExportStatus.PENDING, server_default=ExportStatus.PENDING, nullable=False)

    file_path = db.Column(db.String(512), nullable=True)
    file_size_bytes = db.Column(db.BigInteger, nullable=True)
    sha256 = db.Column(db.String(64), nullable=True)

    manifest_json = db.Column(db.Text, nullable=True)

    error_message = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)
    completed_at = db.Column(db.DateTime, nullable=True)
    expires_at = db.Column(db.DateTime, nullable=True)
    retention_override_days = db.Column(db.Integer, nullable=True)  # set directly by an admin, bypasses the request flow

    def __repr__(self):
        return f"<Export {self.id} {self.status}>"

    def effective_retention_days(self, standard_days: int) -> int:
        """
        The number of days this export should be kept before the cleanup
        job expires it — the platform standard, unless this export has an
        approved extension request or an admin-set override for longer.
        Whichever source grants the most time wins.
        """
        from app.models import RetentionExtensionRequest, ExtensionRequestStatus  # local import, avoids cycle at class-body eval time
        candidates = [standard_days]

        if self.retention_override_days:
            candidates.append(self.retention_override_days)

        approved = (
            RetentionExtensionRequest.query
            .filter_by(export_id=self.id, status=ExtensionRequestStatus.APPROVED)
            .order_by(RetentionExtensionRequest.requested_days.desc())
            .first()
        )
        if approved:
            candidates.append(approved.requested_days)

        return max(candidates)


class AuditLog(db.Model):
    __tablename__ = "audit_logs"

    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    action = db.Column(db.String(120), nullable=False)
    detail = db.Column(db.Text, nullable=True)
    ip_address = db.Column(db.String(64), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)


class ImportStatus:
    PENDING = "pending"
    RUNNING = "running"
    COMPLETE = "complete"
    FAILED = "failed"


class ImportJob(db.Model):
    __tablename__ = "import_jobs"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)

    source_filename = db.Column(db.String(255), nullable=True)
    target_path = db.Column(db.String(512), nullable=True)
    target_os = db.Column(db.String(20), nullable=True)

    status = db.Column(db.String(20), default=ImportStatus.PENDING, server_default=ImportStatus.PENDING, nullable=False)
    log_text = db.Column(db.Text, nullable=True)
    error_message = db.Column(db.Text, nullable=True)
    warnings_json = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)
    completed_at = db.Column(db.DateTime, nullable=True)

    user = db.relationship("User")

    def __repr__(self):
        return f"<ImportJob {self.id} {self.status}>"


class Setting(db.Model):
    __tablename__ = "settings"

    key = db.Column(db.String(120), primary_key=True)
    value = db.Column(db.Text, nullable=True)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    DEFAULTS = {
        "export_retention_days": "7",
        "temp_account_lifetime_hours": "12",
        "cleanup_enabled": "true",
        "mail_server": "",
        "mail_from": "",
    }

    @classmethod
    def get(cls, key, default=None):
        row = db.session.get(cls, key)
        if row is not None:
            return row.value
        return cls.DEFAULTS.get(key, default)

    @classmethod
    def set(cls, key, value):
        row = db.session.get(cls, key)
        if row is None:
            row = cls(key=key, value=value)
            db.session.add(row)
        else:
            row.value = value
        db.session.commit()


class AgentJobKind:
    EXPORT = "export"
    IMPORT = "import"


class AgentJobStatus:
    WAITING = "waiting"            # token issued, agent hasn't checked in yet
    AWAITING_ADMIN = "awaiting_admin"  # agent connected, but waiting on an admin to fill in the config
    CONNECTED = "connected"        # agent has checked in, working
    FINALIZING = "finalizing"      # transfer done, server is verifying/packaging
    COMPLETE = "complete"
    FAILED = "failed"


class AgentJob(db.Model):
    """
    An export or import job carried out by a downloadable agent that the
    target machine runs, rather than this app connecting out over SSH.
    The agent always initiates the connection (outbound HTTPS to this
    server), so nothing needs to be reachable/port-forwarded on the
    target's side — it works the same whether the target is behind NAT,
    a firewall, on a different network entirely, etc.
    """
    __tablename__ = "agent_jobs"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)
    kind = db.Column(db.String(20), nullable=False)
    status = db.Column(db.String(20), default=AgentJobStatus.WAITING, server_default=AgentJobStatus.WAITING, nullable=False)

    token = db.Column(db.String(64), unique=True, nullable=False, index=True)
    config_json = db.Column(db.Text, nullable=False)          # install/target path, db config, etc.
    collected_items_json = db.Column(db.Text, nullable=True)  # running list, export direction

    agent_hostname = db.Column(db.String(255), nullable=True)
    agent_os = db.Column(db.String(20), nullable=True)

    export_id = db.Column(db.String(36), db.ForeignKey("exports.id"), nullable=True)
    import_job_id = db.Column(db.String(36), db.ForeignKey("import_jobs.id"), nullable=True)

    # Admin-assist: the user grants access without knowing any technical
    # details, and an admin fills in the real config remotely within this
    # window while the user's already-running agent waits/polls for it.
    awaiting_admin_config = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)
    admin_access_expires_at = db.Column(db.DateTime, nullable=True)
    configured_by = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    assist_note = db.Column(db.Text, nullable=True)  # optional context the user leaves for the admin

    error_message = db.Column(db.Text, nullable=True)
    log_text = db.Column(db.Text, nullable=True)
    progress_percent = db.Column(db.Integer, nullable=True)  # 0-100, null = indeterminate/not started

    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)
    connected_at = db.Column(db.DateTime, nullable=True)
    completed_at = db.Column(db.DateTime, nullable=True)

    user = db.relationship("User", foreign_keys=[user_id])
    configurer = db.relationship("User", foreign_keys=[configured_by])

    TOKEN_LIFETIME_WAITING = timedelta(hours=2)     # how long an unclaimed token stays valid
    ADMIN_ASSIST_WINDOW = timedelta(hours=12)        # how long an admin has to configure an assisted session

    @property
    def is_token_expired(self):
        if self.status != AgentJobStatus.WAITING:
            return False
        return datetime.utcnow() - self.created_at > self.TOKEN_LIFETIME_WAITING

    @property
    def is_admin_access_expired(self):
        if not self.awaiting_admin_config:
            return False
        if not self.admin_access_expires_at:
            return False
        return datetime.utcnow() > self.admin_access_expires_at

    def __repr__(self):
        return f"<AgentJob {self.id} {self.kind} {self.status}>"


class ExportShareLink(db.Model):
    """
    A PIN-protected, time-limited public link to a single export, for
    handing off to a hosting provider or someone helping with the
    migration without giving them a platform account. The URL alone
    isn't enough — the PIN is required too. Links longer than 168h (7
    days) need admin approval before they're usable.
    """
    __tablename__ = "export_share_links"

    MAX_HOURS_WITHOUT_APPROVAL = 168  # 7 days

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    export_id = db.Column(db.String(36), db.ForeignKey("exports.id"), nullable=False)
    created_by = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)

    token = db.Column(db.String(64), unique=True, nullable=False, index=True)  # in the URL
    pin_hash = db.Column(db.String(255), nullable=False)  # never store the PIN itself

    requested_hours = db.Column(db.Integer, nullable=False)
    expires_at = db.Column(db.DateTime, nullable=False)

    needs_approval = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)
    approved = db.Column(db.Boolean, default=True, server_default=db.text("1"), nullable=False)  # auto-true when <=168h
    approved_by = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    approved_at = db.Column(db.DateTime, nullable=True)

    revoked = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)
    download_count = db.Column(db.Integer, default=0, server_default=db.text("0"), nullable=False)
    failed_pin_attempts = db.Column(db.Integer, default=0, server_default=db.text("0"), nullable=False)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)
    last_accessed_at = db.Column(db.DateTime, nullable=True)

    export = db.relationship("Export")
    creator = db.relationship("User", foreign_keys=[created_by])
    approver = db.relationship("User", foreign_keys=[approved_by])

    MAX_FAILED_PIN_ATTEMPTS = 10  # lock the link after this many wrong PINs

    def set_pin(self, raw_pin):
        self.pin_hash = generate_password_hash(raw_pin)

    def check_pin(self, raw_pin):
        return check_password_hash(self.pin_hash, raw_pin)

    @property
    def is_expired(self):
        return datetime.utcnow() > self.expires_at

    @property
    def is_locked(self):
        return self.failed_pin_attempts >= self.MAX_FAILED_PIN_ATTEMPTS

    @property
    def is_usable(self):
        return (
            self.approved
            and not self.revoked
            and not self.is_expired
            and not self.is_locked
        )

    def __repr__(self):
        return f"<ExportShareLink {self.id} export={self.export_id}>"


class ExtensionRequestStatus:
    PENDING = "pending"
    APPROVED = "approved"
    DECLINED = "declined"


class RetentionExtensionRequest(db.Model):
    """
    A user's request to keep a specific export around longer than the
    platform's standard retention window (7 days by default). Anything
    beyond standard always needs admin approval — there's no auto-approve
    path here, unlike share links, since this is about how long user
    data sits on the server rather than a time-boxed access grant.
    """
    __tablename__ = "retention_extension_requests"

    STANDARD_RETENTION_DAYS = 7

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    export_id = db.Column(db.String(36), db.ForeignKey("exports.id"), nullable=False)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)

    reason = db.Column(db.Text, nullable=False)
    requested_days = db.Column(db.Integer, nullable=False)
    terms_accepted = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)

    status = db.Column(db.String(20), default=ExtensionRequestStatus.PENDING, server_default=ExtensionRequestStatus.PENDING, nullable=False)
    admin_notes = db.Column(db.Text, nullable=True)
    reviewed_by = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    reviewed_at = db.Column(db.DateTime, nullable=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)

    export = db.relationship("Export")
    user = db.relationship("User", foreign_keys=[user_id])
    reviewer = db.relationship("User", foreign_keys=[reviewed_by])

    def __repr__(self):
        return f"<RetentionExtensionRequest {self.id} export={self.export_id} {self.status}>"


class TicketStatus:
    OPEN = "open"
    PENDING_USER = "pending_user"        # waiting on the user to respond
    PENDING_SUPPORT = "pending_support"  # waiting on staff to respond
    RESOLVED = "resolved"
    CLOSED = "closed"


class TicketPriority:
    LOW = "low"
    NORMAL = "normal"
    HIGH = "high"
    URGENT = "urgent"


class SupportTicket(db.Model):
    __tablename__ = "support_tickets"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)  # the ticket owner

    subject = db.Column(db.String(255), nullable=False)
    status = db.Column(db.String(20), default=TicketStatus.OPEN, server_default=TicketStatus.OPEN, nullable=False)
    priority = db.Column(db.String(20), default=TicketPriority.NORMAL, server_default=TicketPriority.NORMAL, nullable=False)

    assigned_to = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    created_by_admin = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)  # set if opened on the user's behalf

    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, server_default=db.func.now(), nullable=False)
    closed_at = db.Column(db.DateTime, nullable=True)

    user = db.relationship("User", foreign_keys=[user_id])
    assignee = db.relationship("User", foreign_keys=[assigned_to])
    opener = db.relationship("User", foreign_keys=[created_by_admin])
    messages = db.relationship(
        "TicketMessage", backref="ticket", order_by="TicketMessage.created_at",
        cascade="all, delete-orphan",
    )

    def __repr__(self):
        return f"<SupportTicket {self.id} {self.subject!r} {self.status}>"


class TicketMessage(db.Model):
    __tablename__ = "ticket_messages"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    ticket_id = db.Column(db.String(36), db.ForeignKey("support_tickets.id"), nullable=False)
    sender_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)
    is_staff_reply = db.Column(db.Boolean, default=False, server_default=db.text("0"), nullable=False)
    body = db.Column(db.Text, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, server_default=db.func.now(), nullable=False)

    sender = db.relationship("User")

    def __repr__(self):
        return f"<TicketMessage {self.id} ticket={self.ticket_id}>"
