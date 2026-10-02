import uuid
from datetime import datetime
from app.extensions import db

SEVERITY_LOW = "low"
SEVERITY_MEDIUM = "medium"
SEVERITY_HIGH = "high"


def gen_uuid():
    return str(uuid.uuid4())


class IntegrityCheckRun(db.Model):
    __tablename__ = "integrity_check_runs"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=True)  # null = platform-wide
    started_at = db.Column(db.DateTime, default=datetime.utcnow)
    finished_at = db.Column(db.DateTime, nullable=True)
    issue_count = db.Column(db.Integer, default=0)

    issues = db.relationship("IntegrityIssue", back_populates="run", cascade="all, delete-orphan")


class IntegrityIssue(db.Model):
    __tablename__ = "integrity_issues"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    run_id = db.Column(db.String(36), db.ForeignKey("integrity_check_runs.id"), nullable=False)

    check_name = db.Column(db.String(100), nullable=False)     # e.g. "unbalanced_journal_entry"
    severity = db.Column(db.String(10), nullable=False, default=SEVERITY_MEDIUM)
    entity_type = db.Column(db.String(50), nullable=True)
    entity_id = db.Column(db.String(36), nullable=True)
    what_happened = db.Column(db.Text, nullable=False)
    why_it_matters = db.Column(db.Text, nullable=False)
    recommended_action = db.Column(db.Text, nullable=False)

    run = db.relationship("IntegrityCheckRun", back_populates="issues")
