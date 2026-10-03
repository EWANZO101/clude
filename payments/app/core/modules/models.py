from datetime import datetime
from app.extensions import db


class ModuleRecord(db.Model):
    __tablename__ = "modules"
    id = db.Column(db.String(80), primary_key=True)  # module id, matches manifest
    name = db.Column(db.String(120), nullable=False)
    description = db.Column(db.Text)
    version = db.Column(db.String(20), nullable=False)
    author = db.Column(db.String(120))
    status = db.Column(db.String(20), default="disabled")  # installed, enabled, disabled, failed
    core_compatibility = db.Column(db.String(20))
    installed_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    migration_status = db.Column(db.String(20), default="pending")
    health_status = db.Column(db.String(20), default="unknown")
    manifest_json = db.Column(db.Text)


class ModuleVersion(db.Model):
    __tablename__ = "module_versions"
    id = db.Column(db.Integer, primary_key=True)
    module_id = db.Column(db.String(80), db.ForeignKey("modules.id"), nullable=False, index=True)
    version = db.Column(db.String(20), nullable=False)
    installed_at = db.Column(db.DateTime, default=datetime.utcnow)
    notes = db.Column(db.Text)


class ModuleLogEntry(db.Model):
    __tablename__ = "module_logs"
    id = db.Column(db.Integer, primary_key=True)
    module_id = db.Column(db.String(80), nullable=False, index=True)
    level = db.Column(db.String(10), default="info")
    message = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
