from datetime import datetime
from flask_sqlalchemy import SQLAlchemy
from flask_login import UserMixin

db = SQLAlchemy()


class Account(db.Model):
    """A Claude account/team linked to a project."""
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    team_label = db.Column(db.String(120))            # e.g. org/team name
    project_path = db.Column(db.String(500))           # working dir for claude
    config_dir = db.Column(db.String(500))              # isolated CLAUDE_CONFIG_DIR
    api_key = db.Column(db.String(255))                 # optional ANTHROPIC_API_KEY
    model = db.Column(db.String(120))                   # optional model override
    notes = db.Column(db.Text)
    os_user = db.Column(db.String(80))                  # run session as this Linux user (sudo-scoped), or None for the service user
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def screen_name(self):
        return f"claude_acct_{self.id}"

    def log_path(self, log_dir):
        return f"{log_dir}/account_{self.id}.log"


class SessionEvent(db.Model):
    """Audit trail of start/stop actions per account."""
    id = db.Column(db.Integer, primary_key=True)
    account_id = db.Column(db.Integer, db.ForeignKey("account.id"), nullable=False)
    action = db.Column(db.String(20))       # start / stop / configure
    detail = db.Column(db.String(500))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    account = db.relationship("Account", backref="events")


class AdminUser(UserMixin):
    """Single admin user backed by env credentials, not the DB."""
    def __init__(self, username):
        self.id = username
