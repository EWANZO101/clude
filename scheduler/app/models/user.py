from datetime import datetime, timezone as dt_timezone

from flask_login import UserMixin
from werkzeug.security import check_password_hash, generate_password_hash

from app import db


class User(UserMixin, db.Model):
    """The account holder / calendar owner.

    This application is designed around a single admin user managing one
    schedule. The model still lives in its own table (rather than being a
    config singleton) so multi-user support is a straightforward extension
    later, per the FUTURE FEATURES list.
    """

    __tablename__ = "users"

    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    name = db.Column(db.String(120), nullable=False)
    timezone = db.Column(db.String(64), nullable=False, default="UTC")
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))
    updated_at = db.Column(
        db.DateTime,
        default=lambda: datetime.now(dt_timezone.utc),
        onupdate=lambda: datetime.now(dt_timezone.utc),
    )

    def set_password(self, raw_password: str) -> None:
        self.password_hash = generate_password_hash(raw_password)

    def check_password(self, raw_password: str) -> bool:
        return check_password_hash(self.password_hash, raw_password)

    @classmethod
    def get_primary(cls):
        """The single account this scheduler belongs to.

        Public pages (booking, status) don't take a username in the URL —
        this app is built around one calendar owner. Multi-user support
        (see FUTURE FEATURES) would replace this with a per-slug lookup.
        """
        return cls.query.order_by(cls.id.asc()).first()

    def __repr__(self):  # pragma: no cover - debugging helper
        return f"<User {self.email}>"
