from datetime import datetime
from app import db


class Project(db.Model):
    __tablename__ = 'projects'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(150), nullable=False)
    description = db.Column(db.Text)
    team_id = db.Column(db.Integer, db.ForeignKey('teams.id'), nullable=False)
    client_id = db.Column(db.Integer, db.ForeignKey('clients.id'), nullable=True)
    status = db.Column(db.String(20), default='active')  # active, archived
    hourly_rate = db.Column(db.Float, nullable=True)  # overrides client rate if set
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    tasks = db.relationship('Task', backref='project', lazy=True)
    time_entries = db.relationship('TimeEntry', backref='project', lazy=True)

    def effective_rate(self):
        if self.hourly_rate is not None:
            return self.hourly_rate
        if self.client and self.client.hourly_rate is not None:
            return self.client.hourly_rate
        return None

    def __repr__(self):
        return f'<Project {self.name}>'


class Client(db.Model):
    __tablename__ = 'clients'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(150), nullable=False)
    team_id = db.Column(db.Integer, db.ForeignKey('teams.id'), nullable=False)
    contact_email = db.Column(db.String(255))
    hourly_rate = db.Column(db.Float, nullable=True)
    currency = db.Column(db.String(10), default='GBP')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    projects = db.relationship('Project', backref='client', lazy=True)

    def __repr__(self):
        return f'<Client {self.name}>'


class Task(db.Model):
    __tablename__ = 'tasks'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    project_id = db.Column(db.Integer, db.ForeignKey('projects.id'), nullable=True)
    assigned_to_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=True)
    status = db.Column(db.String(20), default='open')  # open, in_progress, done
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    time_entries = db.relationship('TimeEntry', backref='task', lazy=True)
    assigned_to = db.relationship('User', foreign_keys=[assigned_to_id])

    def __repr__(self):
        return f'<Task {self.name}>'
