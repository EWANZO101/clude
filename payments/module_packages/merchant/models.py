"""Merchant module models: Company -> Brand -> Merchant -> Location, plus
aliases and per-user correction mappings used by the matching pipeline.
"""
from datetime import datetime
from app.extensions import db
from app.core.database.models import gen_uuid


class MerchantCompany(db.Model):
    """UK company data, Companies-House-shaped. Populated by seed data /
    sync_companies job — see companies_house.py for the sync interface."""
    __tablename__ = "merchant_companies"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    company_name = db.Column(db.String(300), nullable=False, index=True)
    company_number = db.Column(db.String(20), unique=True, nullable=True, index=True)
    company_type = db.Column(db.String(80))
    company_status = db.Column(db.String(40))
    registered_address = db.Column(db.String(400))
    postcode = db.Column(db.String(20))
    sic_codes = db.Column(db.String(200))  # comma-separated
    previous_names = db.Column(db.Text)  # comma-separated
    data_source = db.Column(db.String(40), default="seed")  # seed, companies_house
    last_updated = db.Column(db.DateTime, default=datetime.utcnow)


class MerchantBrand(db.Model):
    __tablename__ = "merchant_brands"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    company_id = db.Column(db.String(36), db.ForeignKey("merchant_companies.id"), nullable=True)
    name = db.Column(db.String(200), nullable=False)
    website = db.Column(db.String(300))

    company = db.relationship("MerchantCompany")


class MerchantCategory(db.Model):
    __tablename__ = "merchant_categories"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(80), unique=True, nullable=False)


class Merchant(db.Model):
    __tablename__ = "merchant_merchants"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    display_name = db.Column(db.String(200), nullable=False, index=True)
    company_id = db.Column(db.String(36), db.ForeignKey("merchant_companies.id"), nullable=True)
    brand_id = db.Column(db.String(36), db.ForeignKey("merchant_brands.id"), nullable=True)
    category_id = db.Column(db.Integer, db.ForeignKey("merchant_categories.id"), nullable=True)
    subcategory = db.Column(db.String(80))
    merchant_type = db.Column(db.String(40))  # retailer, restaurant, utility, subscription, ...
    website = db.Column(db.String(300))
    logo_initials = db.Column(db.String(4))  # fallback logo — see logos.py
    country = db.Column(db.String(80), default="United Kingdom")
    online_only = db.Column(db.Boolean, default=False)
    active = db.Column(db.Boolean, default=True)
    data_source = db.Column(db.String(40), default="seed")
    last_verified = db.Column(db.DateTime, default=datetime.utcnow)

    company = db.relationship("MerchantCompany")
    brand = db.relationship("MerchantBrand")
    category = db.relationship("MerchantCategory")
    aliases = db.relationship("MerchantAlias", backref="merchant", cascade="all, delete-orphan")
    locations = db.relationship("MerchantLocation", backref="merchant", cascade="all, delete-orphan")


class MerchantAlias(db.Model):
    __tablename__ = "merchant_aliases"
    id = db.Column(db.Integer, primary_key=True)
    merchant_id = db.Column(db.String(36), db.ForeignKey("merchant_merchants.id"), nullable=False, index=True)
    alias_text = db.Column(db.String(200), nullable=False, index=True)  # stored normalised (upper, trimmed)


class MerchantLocation(db.Model):
    __tablename__ = "merchant_locations"
    id = db.Column(db.Integer, primary_key=True)
    merchant_id = db.Column(db.String(36), db.ForeignKey("merchant_merchants.id"), nullable=False, index=True)
    store_name = db.Column(db.String(200))
    address = db.Column(db.String(400))
    postcode = db.Column(db.String(20))
    latitude = db.Column(db.Float)
    longitude = db.Column(db.Float)
    store_type = db.Column(db.String(40), default="physical")  # physical, online


class MerchantUserMapping(db.Model):
    """A user's own correction: 'always map this description to merchant'."""
    __tablename__ = "merchant_user_mappings"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    description_text = db.Column(db.String(200), nullable=False)  # normalised
    merchant_id = db.Column(db.String(36), db.ForeignKey("merchant_merchants.id"), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    __table_args__ = (db.UniqueConstraint("user_id", "description_text", name="uq_merchant_mapping_user_desc"),)


class MerchantTransactionLink(db.Model):
    """Links a finance transaction (owned by the finance module, referenced
    loosely by id since it's a separate module) to a matched merchant, plus
    which pipeline stage matched it — used for stats without re-running
    matching every time and for showing 'how was this matched'."""
    __tablename__ = "merchant_transaction_links"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    transaction_id = db.Column(db.String(36), nullable=False, index=True)
    merchant_id = db.Column(db.String(36), db.ForeignKey("merchant_merchants.id"), nullable=False, index=True)
    match_stage = db.Column(db.String(40))  # exact, alias, normalised, fuzzy, user_mapping
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    __table_args__ = (db.UniqueConstraint("transaction_id", name="uq_merchant_link_transaction"),)
