from datetime import datetime
from app import db


class Team(db.Model):
    __tablename__ = 'teams'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    department = db.Column(db.String(120))
    invite_code = db.Column(db.String(32), unique=True, nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    users = db.relationship('User', backref='team', lazy=True)

    def __repr__(self):
        return f'<Team {self.name}>'
