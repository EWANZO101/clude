from datetime import datetime

from database import db


class TxPortRequest(db.Model):
    """A request to open a txAdmin server's ports in the firewall, made by a
    user who can create servers but can't manage the firewall. Admins with
    firewall.manage approve (ports get opened) or deny it from /tx."""

    __tablename__ = "tx_port_requests"

    id = db.Column(db.Integer, primary_key=True)
    instance_id = db.Column(db.Integer, db.ForeignKey("tx_instances.id", ondelete="CASCADE"), nullable=False)
    tx_port = db.Column(db.Integer, nullable=False)
    game_port = db.Column(db.Integer, nullable=False)
    reason = db.Column(db.Text, nullable=True)
    status = db.Column(db.String(16), nullable=False, default="pending")   # pending/approved/denied/cancelled
    requested_by = db.Column(db.String(64), nullable=True)
    decided_by = db.Column(db.String(64), nullable=True)
    decision_note = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    decided_at = db.Column(db.DateTime, nullable=True)

    def to_dict(self):
        return {
            "id": self.id, "instance_id": self.instance_id, "tx_port": self.tx_port, "game_port": self.game_port,
            "reason": self.reason, "status": self.status, "requested_by": self.requested_by,
            "decided_by": self.decided_by, "decision_note": self.decision_note,
            "created_at": self.created_at.isoformat() + "Z" if self.created_at else None,
            "decided_at": self.decided_at.isoformat() + "Z" if self.decided_at else None,
        }


class TxDomain(db.Model):
    """A hostname players can use to join a txAdmin server.

    managed: <label>.<join zone> — an A record the panel creates in the
             panel's DNS provider (Cloudflare, DNS-only so UDP game traffic works).
    custom:  the user's own hostname, pointed at us with a CNAME (or A
             record); the panel only verifies it resolves to this server."""

    __tablename__ = "tx_domains"

    id = db.Column(db.Integer, primary_key=True)
    instance_id = db.Column(db.Integer, db.ForeignKey("tx_instances.id", ondelete="CASCADE"), nullable=False)
    hostname = db.Column(db.String(253), unique=True, nullable=False)
    kind = db.Column(db.String(16), nullable=False)                       # managed / custom
    zone_id = db.Column(db.String(64), nullable=True)
    record_id = db.Column(db.String(64), nullable=True)
    target = db.Column(db.String(253), nullable=True)                    # what a custom domain should CNAME to
    status = db.Column(db.String(16), nullable=False, default="pending")  # active / pending / error
    detail = db.Column(db.Text, nullable=True)
    created_by = db.Column(db.String(64), nullable=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    checked_at = db.Column(db.DateTime, nullable=True)

    def to_dict(self, game_port=None):
        connect = self.hostname if not game_port or game_port == 30120 else f"{self.hostname}:{game_port}"
        return {
            "id": self.id, "instance_id": self.instance_id, "hostname": self.hostname, "kind": self.kind,
            "target": self.target, "status": self.status, "detail": self.detail, "connect": connect,
            "created_by": self.created_by,
            "created_at": self.created_at.isoformat() + "Z" if self.created_at else None,
            "checked_at": self.checked_at.isoformat() + "Z" if self.checked_at else None,
        }
