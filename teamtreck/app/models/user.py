from datetime import datetime
from werkzeug.security import generate_password_hash, check_password_hash
from flask_login import UserMixin
from app import db

ROLES = ('admin', 'manager', 'employee')


class User(UserMixin, db.Model):
    __tablename__ = 'users'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(20), nullable=False, default='employee')
    team_id = db.Column(db.Integer, db.ForeignKey('teams.id'), nullable=True)
    is_active_flag = db.Column(db.Boolean, default=True)
    last_seen = db.Column(db.DateTime, nullable=True)
    theme_pref = db.Column(db.String(10), default='dark')
    api_token = db.Column(db.String(64), unique=True, nullable=True)  # used by the desktop agent to authenticate
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    @property
    def is_admin(self):
        return self.role == 'admin'

    @property
    def is_manager(self):
        return self.role in ('admin', 'manager')

    def touch(self):
        self.last_seen = datetime.utcnow()

    @property
    def is_online(self):
        if not self.last_seen:
            return False
        return (datetime.utcnow() - self.last_seen).total_seconds() < 300

    def __repr__(self):
        return f'<User {self.email}>'
