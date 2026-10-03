import enum

from app.extensions import db
from app.models.base import TimestampMixin


class SellerStatus(str, enum.Enum):
    APPLICATION = "application"
    UNDER_REVIEW = "under_review"
    INFORMATION_REQUIRED = "information_required"
    APPROVED = "approved"
    ACTIVE = "active"
    SUSPENDED = "suspended"
    REJECTED = "rejected"


class SellerProfile(db.Model, TimestampMixin):
    __tablename__ = "seller_profiles"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(
        db.Integer, db.ForeignKey("users.id"), unique=True, nullable=False
    )

    business_name = db.Column(db.String(255), nullable=False)
    slug = db.Column(db.String(255), unique=True, nullable=False, index=True)
    description = db.Column(db.Text)
    support_email = db.Column(db.String(255))
    support_phone = db.Column(db.String(30))
    website_url = db.Column(db.String(255))
    logo_path = db.Column(db.String(500))

    status = db.Column(
        db.Enum(SellerStatus, name="seller_status"),
        default=SellerStatus.APPLICATION,
        nullable=False,
    )
    rejection_reason = db.Column(db.Text)
    information_requested = db.Column(db.Text)

    commission_percent_override = db.Column(db.Numeric(5, 2))

    verified_at = db.Column(db.DateTime(timezone=True))

    user = db.relationship("User", back_populates="seller_profile")
    staff = db.relationship(
        "SellerStaff", back_populates="seller", cascade="all, delete-orphan"
    )

    def __repr__(self):
        return f"<SellerProfile {self.business_name}>"


class SellerStaff(db.Model, TimestampMixin):
    __tablename__ = "seller_staff"

    id = db.Column(db.Integer, primary_key=True)
    seller_id = db.Column(
        db.Integer, db.ForeignKey("seller_profiles.id"), nullable=False
    )
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    staff_role = db.Column(db.String(50), default="staff", nullable=False)

    seller = db.relationship("SellerProfile", back_populates="staff")
    user = db.relationship("User")

    __table_args__ = (
        db.UniqueConstraint("seller_id", "user_id", name="uq_seller_staff_user"),
    )
