from datetime import datetime

from database import db


class SecurityEvent(db.Model):
    """Persisted log of security-relevant events: DDoS state changes,
    flagged/blocked IPs, and auto-mitigation config changes. The DDoS
    detection loop keeps a faster in-memory copy for live updates
    (services/ddos_service.py:_events) — this table is what survives a
    restart and backs the "recent events" list on the Security page."""

    __tablename__ = "security_events"

    id = db.Column(db.Integer, primary_key=True)
    event_type = db.Column(db.String(32), nullable=False)      # state_change, ip_flagged, ip_blocked, config_change, ...
    severity = db.Column(db.String(16), nullable=False, default="info")  # info / warning / critical
    ip = db.Column(db.String(64), nullable=True)
    message = db.Column(db.Text, nullable=False)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "event_type": self.event_type,
            "severity": self.severity,
            "ip": self.ip,
            "message": self.message,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }

    @staticmethod
    def prune(keep=500):
        """Called occasionally so this table doesn't grow forever on a
        long-running panel — keeps the most recent `keep` rows."""
        total = SecurityEvent.query.count()
        if total <= keep:
            return
        cutoff_id = (
            db.session.query(SecurityEvent.id)
            .order_by(SecurityEvent.id.desc())
            .offset(keep)
            .limit(1)
            .scalar()
        )
        if cutoff_id:
            SecurityEvent.query.filter(SecurityEvent.id < cutoff_id).delete()
            db.session.commit()
