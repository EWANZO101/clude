import enum
import random
import string

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class ShipmentStatus(str, enum.Enum):
    PENDING = "pending"
    LABEL_CREATED = "label_created"
    COLLECTED = "collected"
    IN_TRANSIT = "in_transit"
    OUT_FOR_DELIVERY = "out_for_delivery"
    DELIVERED = "delivered"
    EXCEPTION = "exception"
    RETURNED = "returned"


class InspectionResult(str, enum.Enum):
    PASSED = "passed"
    PASSED_WITH_ISSUES = "passed_with_issues"
    FAILED = "failed"


INSPECTION_CHECKLIST_KEYS = [
    "cpu_verified", "ram_verified", "storage_verified", "serial_verified",
    "raid_verified", "network_verified", "power_tested", "boot_tested",
    "physical_condition", "no_damage", "no_missing_components",
]


def _generate_shipment_number():
    return "SHP-" + "".join(random.choices(string.digits, k=8))


class ShippingAddress(db.Model, TimestampMixin):
    """A customer's reusable 'ship from' address for Bring Your Own
    Equipment requests."""

    __tablename__ = "shipping_addresses"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    label = db.Column(db.String(100))
    contact_name = db.Column(db.String(150))
    phone = db.Column(db.String(30))
    address_line1 = db.Column(db.String(255), nullable=False)
    address_line2 = db.Column(db.String(255))
    city = db.Column(db.String(100), nullable=False)
    region = db.Column(db.String(100))
    postal_code = db.Column(db.String(20))
    country = db.Column(db.String(2), nullable=False)

    user = db.relationship("User")


class Shipment(db.Model, TimestampMixin):
    __tablename__ = "shipments"

    id = db.Column(db.Integer, primary_key=True)
    shipment_number = db.Column(db.String(20), unique=True, default=_generate_shipment_number, nullable=False)
    equipment_request_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_requests.id"), nullable=False)
    shipping_address_id = db.Column(db.Integer, db.ForeignKey("shipping_addresses.id"))

    carrier = db.Column(db.String(100))
    tracking_number = db.Column(db.String(150))
    destination_name = db.Column(db.String(150))
    destination_address = db.Column(db.String(500))

    weight_kg = db.Column(db.Numeric(8, 2))
    dimensions = db.Column(db.String(100))
    declared_value = db.Column(db.Numeric(10, 2))
    insurance_value = db.Column(db.Numeric(10, 2))

    status = db.Column(db.Enum(ShipmentStatus, name="shipment_status"), default=ShipmentStatus.PENDING, nullable=False)

    request = db.relationship("CustomerEquipmentRequest")
    shipping_address = db.relationship("ShippingAddress")
    events = db.relationship(
        "ShipmentEvent", back_populates="shipment", cascade="all, delete-orphan",
        order_by="ShipmentEvent.occurred_at",
    )

    def __repr__(self):
        return f"<Shipment {self.shipment_number}>"

    def add_event(self, status, description=None, location=None):
        self.status = status
        db.session.add(
            ShipmentEvent(shipment_id=self.id, status=status, description=description, location=location)
        )


class ShipmentEvent(db.Model):
    __tablename__ = "shipment_events"

    id = db.Column(db.Integer, primary_key=True)
    shipment_id = db.Column(db.Integer, db.ForeignKey("shipments.id"), nullable=False)
    status = db.Column(db.Enum(ShipmentStatus, name="shipment_event_status"), nullable=False)
    description = db.Column(db.String(255))
    location = db.Column(db.String(150))
    occurred_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    shipment = db.relationship("Shipment", back_populates="events")


class ReceivingRecord(db.Model, TimestampMixin):
    __tablename__ = "receiving_records"

    id = db.Column(db.Integer, primary_key=True)
    shipment_id = db.Column(db.Integer, db.ForeignKey("shipments.id"), nullable=False)
    received_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    received_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    condition = db.Column(db.String(50))
    packaging_condition = db.Column(db.String(50))
    accessories_included = db.Column(db.String(255))
    damage_noted = db.Column(db.Boolean, default=False, nullable=False)
    notes = db.Column(db.Text)

    shipment = db.relationship("Shipment")
    received_by = db.relationship("User")


class InspectionRecord(db.Model, TimestampMixin):
    __tablename__ = "inspection_records"

    id = db.Column(db.Integer, primary_key=True)
    item_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_items.id"), nullable=False)
    inspector_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    inspected_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)
    result = db.Column(db.Enum(InspectionResult, name="inspection_result"))
    notes = db.Column(db.Text)

    item = db.relationship("CustomerEquipmentItem")
    inspector = db.relationship("User")
    checklist_items = db.relationship(
        "InspectionItem", back_populates="inspection", cascade="all, delete-orphan"
    )


class InspectionItem(db.Model):
    __tablename__ = "inspection_items"

    id = db.Column(db.Integer, primary_key=True)
    inspection_record_id = db.Column(db.Integer, db.ForeignKey("inspection_records.id"), nullable=False)
    checklist_key = db.Column(db.String(50), nullable=False)
    passed = db.Column(db.Boolean, default=False, nullable=False)
    notes = db.Column(db.String(255))

    inspection = db.relationship("InspectionRecord", back_populates="checklist_items")
