from datetime import datetime
from app.extensions import db
from app.core.database.models import gen_uuid


class StoredFile(db.Model):
    __tablename__ = "files"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True, index=True)
    module_id = db.Column(db.String(80))
    original_filename = db.Column(db.String(255), nullable=False)
    stored_filename = db.Column(db.String(255), nullable=False)
    content_type = db.Column(db.String(120))
    size_bytes = db.Column(db.Integer)
    purpose = db.Column(db.String(60))  # bank_statement, module_zip, backup, checklist_doc, other
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
