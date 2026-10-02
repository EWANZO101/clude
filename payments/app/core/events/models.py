from datetime import datetime
from app.extensions import db


class EventLog(db.Model):
    __tablename__ = "event_log"
    id = db.Column(db.Integer, primary_key=True)
    event_name = db.Column(db.String(120), nullable=False, index=True)
    payload_json = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
