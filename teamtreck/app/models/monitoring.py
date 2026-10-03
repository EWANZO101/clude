from datetime import datetime
from app import db


class Screenshot(db.Model):
    __tablename__ = 'screenshots'

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    time_entry_id = db.Column(db.Integer, db.ForeignKey('time_entries.id'), nullable=True)
    filename = db.Column(db.String(255), nullable=False)  # stored under static/uploads/screenshots/
    captured_at = db.Column(db.DateTime, default=datetime.utcnow)
    session_id = db.Column(db.String(64))  # arbitrary agent-generated session identifier

    user = db.relationship('User', backref='screenshots')
    time_entry = db.relationship('TimeEntry', backref='screenshots')

    def __repr__(self):
        return f'<Screenshot {self.id} user={self.user_id}>'


class ActivitySample(db.Model):
    """A short interval of keyboard/mouse activity, reported periodically by the agent."""
    __tablename__ = 'activity_samples'

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    time_entry_id = db.Column(db.Integer, db.ForeignKey('time_entries.id'), nullable=True)

    window_start = db.Column(db.DateTime, nullable=False)
    window_end = db.Column(db.DateTime, nullable=False)

    keyboard_events = db.Column(db.Integer, default=0)
    mouse_events = db.Column(db.Integer, default=0)
    active_seconds = db.Column(db.Integer, default=0)   # time within window counted as "active"
    idle_seconds = db.Column(db.Integer, default=0)      # time within window counted as "idle"

    activity_level = db.Column(db.Integer, default=0)    # 0-100 score derived by the agent or computed here

    user = db.relationship('User', backref='activity_samples')
    time_entry = db.relationship('TimeEntry', backref='activity_samples')

    def window_seconds(self):
        return int((self.window_end - self.window_start).total_seconds())

    def __repr__(self):
        return f'<ActivitySample {self.id} user={self.user_id} level={self.activity_level}>'
