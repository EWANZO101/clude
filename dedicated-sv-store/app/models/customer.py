from app.extensions import db
from app.models.base import TimestampMixin


class CustomerProfile(db.Model, TimestampMixin):
    __tablename__ = "customer_profiles"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(
        db.Integer, db.ForeignKey("users.id"), unique=True, nullable=False
    )

    company_name = db.Column(db.String(255))
    vat_number = db.Column(db.String(50))
    billing_address_line1 = db.Column(db.String(255))
    billing_address_line2 = db.Column(db.String(255))
    billing_city = db.Column(db.String(100))
    billing_region = db.Column(db.String(100))
    billing_postal_code = db.Column(db.String(20))
    billing_country = db.Column(db.String(2))

    default_currency = db.Column(db.String(3), default="GBP")
    marketing_opt_in = db.Column(db.Boolean, default=False, nullable=False)

    user = db.relationship("User", back_populates="customer_profile")

    def __repr__(self):
        return f"<CustomerProfile user_id={self.user_id}>"
