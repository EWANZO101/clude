from app.extensions import db
from app.models.base import TimestampMixin


class SystemSetting(db.Model, TimestampMixin):
    __tablename__ = "system_settings"

    id = db.Column(db.Integer, primary_key=True)
    key = db.Column(db.String(100), unique=True, nullable=False, index=True)
    value = db.Column(db.JSON)
    description = db.Column(db.String(255))

    @classmethod
    def get(cls, key, default=None):
        row = cls.query.filter_by(key=key).first()
        return row.value if row else default

    @classmethod
    def set(cls, key, value, description=None):
        row = cls.query.filter_by(key=key).first()
        if row is None:
            row = cls(key=key, value=value, description=description)
            db.session.add(row)
        else:
            row.value = value
            if description:
                row.description = description
        return row


class EmailTemplate(db.Model, TimestampMixin):
    __tablename__ = "email_templates"

    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(100), unique=True, nullable=False, index=True)
    name = db.Column(db.String(255), nullable=False)
    subject = db.Column(db.String(255), nullable=False)
    body_html = db.Column(db.Text, nullable=False)
    body_text = db.Column(db.Text)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
