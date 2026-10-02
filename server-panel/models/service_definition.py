from datetime import datetime

from database import db


class ServiceDefinition(db.Model):
    __tablename__ = "service_definitions"

    id = db.Column(db.Integer, primary_key=True)
    unit_name = db.Column(db.String(128), unique=True, nullable=False)

    app_name = db.Column(db.String(64), nullable=False)
    working_dir = db.Column(db.String(255), nullable=False)
    runtime = db.Column(db.String(32), nullable=True)
    port = db.Column(db.String(10), nullable=True)
    exec_start = db.Column(db.String(255), nullable=False)
    run_user = db.Column(db.String(64), nullable=False, default="root")
    description = db.Column(db.String(255), nullable=True)

    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
