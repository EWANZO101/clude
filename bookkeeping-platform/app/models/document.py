import uuid
from datetime import datetime
from app.extensions import db


def gen_uuid():
    return str(uuid.uuid4())


class Document(db.Model):
    """A stored file (receipt, invoice PDF, bank statement, contract, ...)
    optionally attached to another record. The original upload is always
    retained; nothing here rewrites the source file."""

    __tablename__ = "documents"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)

    original_filename = db.Column(db.String(255), nullable=False)
    stored_path = db.Column(db.String(500), nullable=False)
    content_type = db.Column(db.String(100), nullable=True)
    size_bytes = db.Column(db.Integer, nullable=True)

    related_type = db.Column(db.String(50), nullable=True)  # 'expense' | 'invoice' | 'bill' | ...
    related_id = db.Column(db.String(36), nullable=True)

    uploaded_by_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)
