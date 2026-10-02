from app.extensions import db
from app.models.base import utcnow


class AuditLog(db.Model):
    __tablename__ = "audit_logs"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    action = db.Column(db.String(100), nullable=False, index=True)
    object_type = db.Column(db.String(100), nullable=False, index=True)
    object_id = db.Column(db.String(50), index=True)
    old_value = db.Column(db.JSON)
    new_value = db.Column(db.JSON)
    reason = db.Column(db.Text)
    ip_address = db.Column(db.String(45))
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    user = db.relationship("User")

    def __repr__(self):
        return f"<AuditLog {self.action} {self.object_type}:{self.object_id}>"
