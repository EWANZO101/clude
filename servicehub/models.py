from datetime import datetime
from flask_sqlalchemy import SQLAlchemy
from werkzeug.security import generate_password_hash, check_password_hash

db = SQLAlchemy()


class AdminUser(db.Model):
    __tablename__ = "admin_user"

    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, server_default=db.func.now())

    def set_password(self, raw):
        self.password_hash = generate_password_hash(raw)

    def check_password(self, raw):
        return check_password_hash(self.password_hash, raw)


class Service(db.Model):
    __tablename__ = "service"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), unique=True, nullable=False)
    slug = db.Column(db.String(80), unique=True, nullable=False)
    description = db.Column(db.Text, nullable=False, server_default="")
    working_dir = db.Column(db.String(255), nullable=False)
    command = db.Column(db.Text, nullable=False)
    port = db.Column(db.Integer, nullable=True)
    run_user = db.Column(db.String(64), nullable=False, server_default="www-data")
    restart_policy = db.Column(db.String(20), nullable=False, server_default="on-failure")
    env_vars = db.Column(db.Text, nullable=False, server_default="")  # one KEY=VALUE per line
    notes = db.Column(db.Text, nullable=False, server_default="")
    created_at = db.Column(db.DateTime, nullable=False, server_default=db.func.now())
    updated_at = db.Column(
        db.DateTime, nullable=False, server_default=db.func.now(), onupdate=datetime.utcnow
    )

    @property
    def unit_name(self):
        return f"opslab-{self.slug}.service"

    def env_lines(self):
        return [ln.strip() for ln in (self.env_vars or "").splitlines() if ln.strip()]
