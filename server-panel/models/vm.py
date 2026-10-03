"""VM fleet models.

Each VM is claimed and logged into independently via its own IP (or a
friendly name alias) + username + password - this is deliberately NOT a
single customer account with multiple VMs attached. See models/user.py
for the admin-side auth pattern this mirrors (argon2 hashing, same
overall shape).

Claim flow: the agent script registers a VM row on first boot with a
pairing_code (printed to the VM's own console/terminal by the install
step, never sent anywhere over the network) and no username/password
yet. A customer can only set up login credentials for that VM by proving
they can read that console output - i.e. they already have real access
to the box - which is what stops someone from squatting on an IP they
don't control.
"""
import secrets
from datetime import datetime

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHash

from database import db

_hasher = PasswordHasher()

# No 0/O/1/I - avoids transcription mistakes when someone reads this off
# a console and types it into the claim form.
_PAIRING_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

VM_ACTIONS = ("power_off", "disable_ssh", "enable_ssh")
VM_COMMAND_STATUSES = ("pending", "delivered", "acked", "failed")


def _generate_pairing_code():
    return "-".join("".join(secrets.choice(_PAIRING_ALPHABET) for _ in range(4)) for _ in range(2))


def _generate_agent_token():
    return secrets.token_hex(32)


class VM(db.Model):
    """A single managed VM."""
    __tablename__ = "vms"

    id = db.Column(db.Integer, primary_key=True)

    ip_address = db.Column(db.String(45), unique=True, nullable=False, index=True)  # 45 = max IPv6 literal
    name = db.Column(db.String(64), unique=True, nullable=True, index=True)  # null until claimed

    # Customer-facing login credentials, set once at claim time.
    # Independent of models.user.User - this is not an admin account and
    # should never be checked against the admin permission system.
    username = db.Column(db.String(64), nullable=True)
    password_hash = db.Column(db.String(255), nullable=True)

    # Agent <-> panel channel auth. Generated at registration, never shown
    # to the customer, rotated only by an admin if a VM is compromised.
    agent_token = db.Column(db.String(64), unique=True, nullable=False, default=_generate_agent_token)

    # A non-null pairing_code means "registered but unclaimed." Cleared on
    # successful claim.
    pairing_code = db.Column(db.String(20), nullable=True, default=_generate_pairing_code)
    claimed_at = db.Column(db.DateTime, nullable=True)

    locked = db.Column(db.Boolean, nullable=False, server_default="0", default=False)
    locked_at = db.Column(db.DateTime, nullable=True)
    locked_reason = db.Column(db.String(255), nullable=True)
    locked_by_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    locked_by_user = db.relationship("User")

    ssh_disabled = db.Column(db.Boolean, nullable=False, server_default="0", default=False)

    last_seen_at = db.Column(db.DateTime, nullable=True)
    last_status = db.Column(db.String(32), nullable=True)  # "online" | "offline" | ...
    agent_version = db.Column(db.String(32), nullable=True)
    hostname = db.Column(db.String(255), nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    commands = db.relationship(
        "VMCommand", back_populates="vm", cascade="all, delete-orphan",
        order_by="VMCommand.created_at.desc()",
    )

    # A missed heartbeat window before we call it offline. The agent
    # heartbeats roughly every 20s, so 90s allows a couple of dropped
    # beats without flapping the status on every hiccup.
    ONLINE_WINDOW_SECONDS = 90

    @property
    def is_claimed(self):
        return self.claimed_at is not None

    @property
    def is_online(self):
        if not self.last_seen_at:
            return False
        return (datetime.utcnow() - self.last_seen_at).total_seconds() < self.ONLINE_WINDOW_SECONDS

    def set_password(self, raw_password):
        self.password_hash = _hasher.hash(raw_password)

    def check_password(self, raw_password):
        if not self.password_hash:
            return False
        try:
            return _hasher.verify(self.password_hash, raw_password)
        except (VerifyMismatchError, InvalidHash):
            return False

    def check_pairing_code(self, submitted_code):
        if not self.pairing_code:
            return False
        return secrets.compare_digest(self.pairing_code.upper(), (submitted_code or "").strip().upper())

    def admin_reopen_for_claim(self):
        """Admin override: force a VM back into an unclaimed state - e.g.
        the owner lost access, or the panel entry needs to be handed to a
        different customer. Existing credentials are wiped; a fresh
        pairing code is generated (the admin relays it to whoever has
        console/shell access to the box, same as first-time setup)."""
        self.pairing_code = _generate_pairing_code()
        self.claimed_at = None
        self.username = None
        self.password_hash = None
        self.name = None

    def __repr__(self):
        return f"<VM {self.name or self.ip_address}>"


class VMCommand(db.Model):
    """Audit log + delivery queue for admin-issued remote actions. The
    agent picks up any pending commands on its next heartbeat, so an
    action issued while a VM is briefly offline is delivered once it
    reconnects rather than silently lost. Every destructive action
    (power_off in particular) keeps a permanent record of who issued it
    and when."""
    __tablename__ = "vm_commands"

    id = db.Column(db.Integer, primary_key=True)
    vm_id = db.Column(db.Integer, db.ForeignKey("vms.id"), nullable=False, index=True)
    vm = db.relationship("VM", back_populates="commands")

    issued_by_user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=True)
    issued_by_user = db.relationship("User", foreign_keys=[issued_by_user_id])

    action = db.Column(db.String(32), nullable=False)  # one of VM_ACTIONS
    status = db.Column(db.String(16), nullable=False, default="pending")  # one of VM_COMMAND_STATUSES
    detail = db.Column(db.Text, nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    delivered_at = db.Column(db.DateTime, nullable=True)
    acked_at = db.Column(db.DateTime, nullable=True)

    def __repr__(self):
        return f"<VMCommand {self.action} vm={self.vm_id} status={self.status}>"
