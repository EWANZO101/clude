from datetime import datetime
from app import db


class TimeEntry(db.Model):
    __tablename__ = 'time_entries'

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    project_id = db.Column(db.Integer, db.ForeignKey('projects.id'), nullable=True)
    task_id = db.Column(db.Integer, db.ForeignKey('tasks.id'), nullable=True)

    started_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    ended_at = db.Column(db.DateTime, nullable=True)

    # running total of paused seconds, so duration = (ended_at or now) - started_at - paused_seconds
    paused_seconds = db.Column(db.Integer, default=0)
    paused_at = db.Column(db.DateTime, nullable=True)  # set while paused

    status = db.Column(db.String(20), default='running')  # running, paused, stopped
    is_billable = db.Column(db.Boolean, default=True)

    note = db.Column(db.String(500))

    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    user = db.relationship('User', backref='time_entries')

    def duration_seconds(self):
        end = self.ended_at or datetime.utcnow()
        total = (end - self.started_at).total_seconds()
        paused = self.paused_seconds or 0
        if self.status == 'paused' and self.paused_at:
            paused += (datetime.utcnow() - self.paused_at).total_seconds()
        return max(0, int(total - paused))

    def duration_hms(self):
        secs = self.duration_seconds()
        h, rem = divmod(secs, 3600)
        m, s = divmod(rem, 60)
        return f'{h:02d}:{m:02d}:{s:02d}'

    def __repr__(self):
        return f'<TimeEntry {self.id} user={self.user_id} status={self.status}>'


class TimeEntryAudit(db.Model):
    __tablename__ = 'time_entry_audits'

    id = db.Column(db.Integer, primary_key=True)
    time_entry_id = db.Column(db.Integer, db.ForeignKey('time_entries.id'), nullable=False)
    changed_by_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    action = db.Column(db.String(20), nullable=False)  # created, edited, deleted, started, paused, resumed, stopped
    field_changed = db.Column(db.String(50), nullable=True)
    old_value = db.Column(db.String(255), nullable=True)
    new_value = db.Column(db.String(255), nullable=True)
    timestamp = db.Column(db.DateTime, default=datetime.utcnow)

    time_entry = db.relationship('TimeEntry', backref='audits')
    changed_by = db.relationship('User')
