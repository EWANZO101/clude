import uuid
import secrets
from datetime import datetime, date

from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

from app.extensions import db


def gen_uuid():
    return str(uuid.uuid4())


def gen_share_token():
    return secrets.token_urlsafe(24)


class User(UserMixin, db.Model):
    __tablename__ = "users"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    username = db.Column(db.String(64), unique=True, nullable=False, index=True)
    email = db.Column(db.String(120), unique=True, nullable=True)
    password_hash = db.Column(db.String(255), nullable=False)
    is_admin = db.Column(db.Boolean, default=False, nullable=False)
    is_disabled = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login_at = db.Column(db.DateTime, nullable=True)

    motorcycles = db.relationship(
        "Motorcycle", backref="owner", lazy="dynamic", cascade="all, delete-orphan"
    )

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    def __repr__(self):
        return f"<User {self.username}>"


class Motorcycle(db.Model):
    __tablename__ = "motorcycles"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)

    registration = db.Column(db.String(20))
    make = db.Column(db.String(80))
    model = db.Column(db.String(80))
    year = db.Column(db.Integer)
    engine_info = db.Column(db.String(255))
    vin = db.Column(db.String(64))
    mileage = db.Column(db.Integer)
    colour = db.Column(db.String(60))
    purchase_date = db.Column(db.Date)
    purchase_price = db.Column(db.Numeric(10, 2))
    previous_owners = db.Column(db.Text)
    notes = db.Column(db.Text)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    # Public sharing
    share_enabled = db.Column(db.Boolean, default=False, nullable=False)
    share_token = db.Column(db.String(64), unique=True, default=gen_share_token)
    share_show_service = db.Column(db.Boolean, default=True)
    share_show_mods = db.Column(db.Boolean, default=True)
    share_show_parts = db.Column(db.Boolean, default=False)
    share_show_accidents = db.Column(db.Boolean, default=False)
    share_show_mot = db.Column(db.Boolean, default=True)
    share_show_purchase_info = db.Column(db.Boolean, default=False)
    share_show_documents = db.Column(db.Boolean, default=False)

    photos = db.relationship(
        "MotorcyclePhoto", backref="motorcycle", lazy="dynamic",
        cascade="all, delete-orphan"
    )
    service_records = db.relationship(
        "ServiceRecord", backref="motorcycle", lazy="dynamic",
        cascade="all, delete-orphan", order_by="desc(ServiceRecord.date)"
    )
    modifications = db.relationship(
        "Modification", backref="motorcycle", lazy="dynamic",
        cascade="all, delete-orphan", order_by="desc(Modification.date_fitted)"
    )
    parts_stock = db.relationship(
        "PartNotFitted", backref="motorcycle", lazy="dynamic",
        cascade="all, delete-orphan", order_by="desc(PartNotFitted.purchase_date)"
    )
    accidents = db.relationship(
        "Accident", backref="motorcycle", lazy="dynamic",
        cascade="all, delete-orphan", order_by="desc(Accident.date)"
    )
    mot_records = db.relationship(
        "MOTRecord", backref="motorcycle", lazy="dynamic",
        cascade="all, delete-orphan", order_by="desc(MOTRecord.test_date)"
    )
    documents = db.relationship(
        "Document", backref="motorcycle", lazy="dynamic",
        cascade="all, delete-orphan"
    )

    @property
    def display_name(self):
        parts = [str(self.year) if self.year else None, self.make, self.model]
        name = " ".join(p for p in parts if p)
        return name or self.registration or "Unnamed motorcycle"

    def regenerate_share_token(self):
        self.share_token = gen_share_token()

    def timeline_events(self):
        """Combine all record types into one chronologically sorted list."""
        events = []
        if self.purchase_date:
            events.append({
                "date": self.purchase_date,
                "kind": "purchase",
                "title": "Motorcycle purchased",
                "detail": f"Purchased for £{self.purchase_price}" if self.purchase_price else "Purchase recorded",
                "cost": self.purchase_price,
                "record": None,
            })
        for r in self.service_records:
            events.append({
                "date": r.date, "kind": "service", "title": r.work_type or "Service",
                "detail": r.description, "cost": r.total_cost, "record": r,
            })
        for m in self.modifications:
            events.append({
                "date": m.date_fitted, "kind": "modification", "title": m.name,
                "detail": m.description, "cost": (m.cost or 0) + (m.installation_cost or 0), "record": m,
            })
        for a in self.accidents:
            events.append({
                "date": a.date, "kind": "accident", "title": "Accident / damage",
                "detail": a.description, "cost": a.repair_cost, "record": a,
            })
        for mot in self.mot_records:
            events.append({
                "date": mot.test_date, "kind": "mot",
                "title": f"MOT {mot.result or ''}".strip(),
                "detail": f"Mileage: {mot.mileage}" if mot.mileage else "", "cost": None, "record": mot,
            })
        events = [e for e in events if e["date"]]
        events.sort(key=lambda e: e["date"], reverse=True)
        return events

    def __repr__(self):
        return f"<Motorcycle {self.display_name}>"


class MotorcyclePhoto(db.Model):
    __tablename__ = "motorcycle_photos"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    motorcycle_id = db.Column(db.String(36), db.ForeignKey("motorcycles.id"), nullable=False)
    filename = db.Column(db.String(255), nullable=False)
    caption = db.Column(db.String(255))
    is_public = db.Column(db.Boolean, default=True)
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)


class Document(db.Model):
    __tablename__ = "documents"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    motorcycle_id = db.Column(db.String(36), db.ForeignKey("motorcycles.id"), nullable=False)
    # Optional links to a specific record so docs can live "under" a service/mod/accident/part
    service_record_id = db.Column(db.String(36), db.ForeignKey("service_records.id"), nullable=True)
    modification_id = db.Column(db.String(36), db.ForeignKey("modifications.id"), nullable=True)
    accident_id = db.Column(db.String(36), db.ForeignKey("accidents.id"), nullable=True)
    part_id = db.Column(db.String(36), db.ForeignKey("parts_not_fitted.id"), nullable=True)

    filename = db.Column(db.String(255), nullable=False)
    original_name = db.Column(db.String(255))
    doc_type = db.Column(db.String(60))  # receipt, invoice, service_sheet, mot, insurance, purchase, other
    is_public = db.Column(db.Boolean, default=False)
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)


class ServiceRecord(db.Model):
    __tablename__ = "service_records"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    motorcycle_id = db.Column(db.String(36), db.ForeignKey("motorcycles.id"), nullable=False)

    date = db.Column(db.Date, nullable=False, default=date.today)
    mileage = db.Column(db.Integer)
    work_type = db.Column(db.String(120))
    description = db.Column(db.Text)
    garage = db.Column(db.String(160))
    parts_used = db.Column(db.Text)
    labour_cost = db.Column(db.Numeric(10, 2))
    parts_cost = db.Column(db.Numeric(10, 2))
    total_cost = db.Column(db.Numeric(10, 2))
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    documents = db.relationship("Document", backref="service_record", lazy="dynamic")


class Modification(db.Model):
    __tablename__ = "modifications"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    motorcycle_id = db.Column(db.String(36), db.ForeignKey("motorcycles.id"), nullable=False)

    name = db.Column(db.String(160), nullable=False)
    description = db.Column(db.Text)
    date_fitted = db.Column(db.Date, default=date.today)
    mileage_fitted = db.Column(db.Integer)
    manufacturer = db.Column(db.String(120))
    part_number = db.Column(db.String(120))
    cost = db.Column(db.Numeric(10, 2))
    installation_cost = db.Column(db.Numeric(10, 2))
    fitted_by = db.Column(db.String(160))
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    documents = db.relationship("Document", backref="modification", lazy="dynamic")


class PartNotFitted(db.Model):
    __tablename__ = "parts_not_fitted"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    motorcycle_id = db.Column(db.String(36), db.ForeignKey("motorcycles.id"), nullable=False)

    part_name = db.Column(db.String(160), nullable=False)
    manufacturer = db.Column(db.String(120))
    part_number = db.Column(db.String(120))
    purchase_date = db.Column(db.Date, default=date.today)
    purchase_price = db.Column(db.Numeric(10, 2))
    supplier = db.Column(db.String(160))
    quantity = db.Column(db.Integer, default=1)
    notes = db.Column(db.Text)
    status = db.Column(db.String(30), default="in_stock")  # in_stock, fitted
    fitted_as_modification_id = db.Column(db.String(36), db.ForeignKey("modifications.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    documents = db.relationship("Document", backref="part", lazy="dynamic")


class Accident(db.Model):
    __tablename__ = "accidents"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    motorcycle_id = db.Column(db.String(36), db.ForeignKey("motorcycles.id"), nullable=False)

    date = db.Column(db.Date, nullable=False, default=date.today)
    mileage = db.Column(db.Integer)
    description = db.Column(db.Text)
    damage_caused = db.Column(db.Text)
    repairs_carried_out = db.Column(db.Text)
    repair_cost = db.Column(db.Numeric(10, 2))
    insurance_info = db.Column(db.Text)
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    documents = db.relationship("Document", backref="accident", lazy="dynamic")


class MOTRecord(db.Model):
    __tablename__ = "mot_records"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    motorcycle_id = db.Column(db.String(36), db.ForeignKey("motorcycles.id"), nullable=False)

    test_date = db.Column(db.Date)
    expiry_date = db.Column(db.Date)
    result = db.Column(db.String(20))  # PASSED / FAILED
    mileage = db.Column(db.Integer)
    mileage_unit = db.Column(db.String(10))
    test_number = db.Column(db.String(40))
    advisories = db.Column(db.Text)   # JSON-encoded list
    failures = db.Column(db.Text)     # JSON-encoded list
    raw_source = db.Column(db.String(30), default="dvsa_api")  # dvsa_api or manual
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class AppSetting(db.Model):
    """Key/value store for admin-configurable settings (MOT API creds etc)."""
    __tablename__ = "app_settings"
    key = db.Column(db.String(120), primary_key=True)
    value = db.Column(db.Text)
    is_secret = db.Column(db.Boolean, default=False)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    @staticmethod
    def get(key, default=None):
        row = db.session.get(AppSetting, key)
        return row.value if row else default

    @staticmethod
    def set(key, value, is_secret=False):
        row = db.session.get(AppSetting, key)
        if row is None:
            row = AppSetting(key=key, value=value, is_secret=is_secret)
            db.session.add(row)
        else:
            row.value = value
        db.session.commit()
        return row


class ApiLog(db.Model):
    """Simple log of outbound MOT API calls / errors for the admin area."""
    __tablename__ = "api_logs"
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    source = db.Column(db.String(60))  # e.g. dvsa_mot
    status = db.Column(db.String(20))  # success, error
    registration = db.Column(db.String(20))
    message = db.Column(db.Text)
