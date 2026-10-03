import uuid
from datetime import datetime
from flask_login import UserMixin, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from app.extensions import db, login_manager


def gen_uuid():
    return str(uuid.uuid4())


class User(UserMixin, db.Model):
    __tablename__ = "users"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    full_name = db.Column(db.String(255), nullable=False)
    is_active_flag = db.Column("is_active", db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    current_business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=True)
    is_platform_admin = db.Column(db.Boolean, default=False, nullable=False)

    memberships = db.relationship(
        "Membership", back_populates="user", cascade="all, delete-orphan"
    )

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    # Flask-Login expects `is_active` as a property/attribute
    @property
    def is_active(self):
        return self.is_active_flag

    def businesses(self):
        from app.models.business import Business
        return [m.business for m in self.memberships if m.business is not None]

    def current_business(self):
        from app.models.business import Business
        if self.current_business_id:
            biz = Business.query.get(self.current_business_id)
            if biz and self.role_in(biz) is not None:
                return biz
        bs = self.businesses()
        return bs[0] if bs else None

    def role_in(self, business):
        for m in self.memberships:
            if m.business_id == business.id:
                return m.role
        return None

    def __repr__(self):
        return f"<User {self.email}>"


@login_manager.user_loader
def load_user(user_id):
    return User.query.get(user_id)
