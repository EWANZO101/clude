import enum
import random
import string

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class RequestStatus(str, enum.Enum):
    DRAFT = "draft"
    SUBMITTED = "submitted"
    UNDER_REVIEW = "under_review"
    TECHNICAL_REVIEW = "technical_review"
    INFORMATION_REQUIRED = "information_required"
    APPROVED = "approved"
    REJECTED = "rejected"
    INVOICE_ISSUED = "invoice_issued"
    SHIPPING_ARRANGED = "shipping_arranged"
    LOCKED_FOR_SHIPMENT = "locked_for_shipment"
    IN_TRANSIT = "in_transit"
    RECEIVED = "received"
    INSPECTION = "inspection"
    DEPLOYMENT = "deployment"
    COMPLETED = "completed"

EDITABLE_STATUSES = {RequestStatus.DRAFT, RequestStatus.SUBMITTED, RequestStatus.INFORMATION_REQUIRED}

LOCKED_STATUSES = {
    RequestStatus.LOCKED_FOR_SHIPMENT, RequestStatus.IN_TRANSIT, RequestStatus.RECEIVED,
    RequestStatus.INSPECTION, RequestStatus.DEPLOYMENT, RequestStatus.COMPLETED,
}

# Milestone stepper shown to customers/admins — collapses the full status
# machine (which includes side-states like technical_review/information_required
# that don't belong on a linear progress bar) down to the steps a customer
# actually cares about tracking through to shipment/deployment.
REQUEST_PROGRESS_STEPS = [
    "Submitted", "Review", "Approved", "Invoice & Shipping",
    "In Transit", "Received", "Deployed", "Completed",
]

REQUEST_STATUS_TO_STEP_INDEX = {
    RequestStatus.DRAFT: -1,
    RequestStatus.SUBMITTED: 0,
    RequestStatus.UNDER_REVIEW: 1,
    RequestStatus.TECHNICAL_REVIEW: 1,
    RequestStatus.INFORMATION_REQUIRED: 1,
    RequestStatus.APPROVED: 2,
    RequestStatus.REJECTED: 2,
    RequestStatus.INVOICE_ISSUED: 3,
    RequestStatus.SHIPPING_ARRANGED: 3,
    RequestStatus.LOCKED_FOR_SHIPMENT: 3,
    RequestStatus.IN_TRANSIT: 4,
    RequestStatus.RECEIVED: 5,
    RequestStatus.INSPECTION: 5,
    RequestStatus.DEPLOYMENT: 6,
    RequestStatus.COMPLETED: 7,
}


class AttachmentType(str, enum.Enum):
    PHOTO_FRONT = "photo_front"
    PHOTO_REAR = "photo_rear"
    PHOTO_SERIAL = "photo_serial"
    SPECIFICATION_SHEET = "specification_sheet"
    PURCHASE_DOCUMENTATION = "purchase_documentation"
    TECHNICAL_DOCUMENTATION = "technical_documentation"
    OTHER = "other"


class ChangeRequestStatus(str, enum.Enum):
    PENDING = "pending"
    APPROVED = "approved"
    REJECTED = "rejected"


def _generate_request_number():
    return "REQ-" + "".join(random.choices(string.digits, k=8))


class EquipmentType(db.Model, TimestampMixin):
    """Admin-configurable equipment categories (Server, Switch, Router,
    Firewall, Transceiver, ...) — not a fixed enum, per spec section 21."""

    __tablename__ = "equipment_types"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), unique=True, nullable=False)
    slug = db.Column(db.String(100), unique=True, nullable=False, index=True)
    is_networking = db.Column(db.Boolean, default=False, nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def __repr__(self):
        return f"<EquipmentType {self.name}>"


class CustomerEquipmentRequest(db.Model, TimestampMixin):
    __tablename__ = "customer_equipment_requests"

    id = db.Column(db.Integer, primary_key=True)
    request_number = db.Column(db.String(20), unique=True, default=_generate_request_number, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    assigned_staff_id = db.Column(db.Integer, db.ForeignKey("users.id"))

    status = db.Column(db.Enum(RequestStatus, name="request_status"), default=RequestStatus.DRAFT, nullable=False)
    rejection_reason = db.Column(db.Text)
    information_requested = db.Column(db.Text)

    submitted_at = db.Column(db.DateTime(timezone=True))
    approved_at = db.Column(db.DateTime(timezone=True))
    locked_at = db.Column(db.DateTime(timezone=True))

    customer_confirmed_at = db.Column(db.DateTime(timezone=True))

    user = db.relationship("User", foreign_keys=[user_id])
    assigned_staff = db.relationship("User", foreign_keys=[assigned_staff_id])
    items = db.relationship(
        "CustomerEquipmentItem", back_populates="request", cascade="all, delete-orphan"
    )
    history = db.relationship(
        "CustomerEquipmentHistory", back_populates="request", cascade="all, delete-orphan",
        order_by="CustomerEquipmentHistory.created_at",
    )
    change_requests = db.relationship(
        "EquipmentChangeRequest", back_populates="request", cascade="all, delete-orphan",
        order_by="EquipmentChangeRequest.created_at",
    )

    def __repr__(self):
        return f"<CustomerEquipmentRequest {self.request_number}>"

    @property
    def is_editable(self):
        return self.status in EDITABLE_STATUSES

    @property
    def is_locked(self):
        return self.status in LOCKED_STATUSES

    @property
    def declared_value_total(self):
        return sum((item.declared_value or 0) * item.quantity for item in self.items)

    @property
    def replacement_value_total(self):
        return sum((item.replacement_value or 0) * item.quantity for item in self.items)

    @property
    def total_item_count(self):
        return sum(item.quantity for item in self.items)

    @property
    def progress_info(self):
        current_index = REQUEST_STATUS_TO_STEP_INDEX.get(self.status, -1)
        total_steps = len(REQUEST_PROGRESS_STEPS)
        percent = 0 if current_index < 0 else round((current_index + 1) / total_steps * 100)
        stopped = self.status == RequestStatus.REJECTED
        return {
            "steps": REQUEST_PROGRESS_STEPS,
            "current_index": current_index,
            "percent": percent,
            "stopped": stopped,
            "stopped_label": "This request was rejected." if stopped else None,
        }

    def set_status(self, new_status, changed_by_id=None, reason=None):
        old_status = self.status
        if old_status == new_status:
            return
        self.status = new_status
        db.session.add(
            CustomerEquipmentHistory(
                request_id=self.id, field_name="status",
                old_value=old_status.value, new_value=new_status.value,
                changed_by_id=changed_by_id, reason=reason,
            )
        )


class CustomerEquipmentItem(db.Model, TimestampMixin):
    __tablename__ = "customer_equipment_items"

    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_requests.id"), nullable=False)
    equipment_type_id = db.Column(db.Integer, db.ForeignKey("equipment_types.id"), nullable=False)

    manufacturer = db.Column(db.String(100))
    model = db.Column(db.String(100))
    serial_number = db.Column(db.String(100))
    asset_number = db.Column(db.String(100))
    quantity = db.Column(db.Integer, default=1, nullable=False)

    # Server-oriented specs
    cpu_summary = db.Column(db.String(255))
    ram_summary = db.Column(db.String(255))
    storage_summary = db.Column(db.String(255))
    gpu_summary = db.Column(db.String(255))
    raid_summary = db.Column(db.String(255))
    psu_summary = db.Column(db.String(255))
    chassis_summary = db.Column(db.String(255))

    # Networking-oriented specs
    port_count = db.Column(db.Integer)
    port_types = db.Column(db.String(255))
    port_speeds = db.Column(db.String(255))
    mac_address = db.Column(db.String(50))
    firmware_version = db.Column(db.String(50))

    # Common physical attributes
    network_summary = db.Column(db.String(255))
    rack_mount = db.Column(db.Boolean, default=True)
    u_height = db.Column(db.Numeric(4, 1))
    dimensions = db.Column(db.String(100))
    weight_kg = db.Column(db.Numeric(6, 2))
    power_requirements = db.Column(db.String(100))

    declared_value = db.Column(db.Numeric(10, 2))
    replacement_value = db.Column(db.Numeric(10, 2))
    insurance_value = db.Column(db.Numeric(10, 2))

    notes = db.Column(db.Text)

    request = db.relationship("CustomerEquipmentRequest", back_populates="items")
    equipment_type = db.relationship("EquipmentType")
    attachments = db.relationship(
        "EquipmentAttachment", back_populates="item", cascade="all, delete-orphan"
    )

    def __repr__(self):
        return f"<CustomerEquipmentItem {self.manufacturer} {self.model}>"


class EquipmentAttachment(db.Model, TimestampMixin):
    __tablename__ = "equipment_attachments"

    id = db.Column(db.Integer, primary_key=True)
    item_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_items.id"), nullable=False)
    file_path = db.Column(db.String(500), nullable=False)
    attachment_type = db.Column(db.Enum(AttachmentType, name="attachment_type"), nullable=False)
    original_filename = db.Column(db.String(255))
    uploaded_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))

    item = db.relationship("CustomerEquipmentItem", back_populates="attachments")
    uploaded_by = db.relationship("User")


class CustomerEquipmentHistory(db.Model):
    __tablename__ = "customer_equipment_history"

    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_requests.id"), nullable=False)
    item_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_items.id"))
    field_name = db.Column(db.String(100), nullable=False)
    old_value = db.Column(db.String(500))
    new_value = db.Column(db.String(500))
    changed_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    reason = db.Column(db.String(255))
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    request = db.relationship("CustomerEquipmentRequest", back_populates="history")
    item = db.relationship("CustomerEquipmentItem")
    changed_by = db.relationship("User")


class EquipmentChangeRequest(db.Model, TimestampMixin):
    """Lets a customer ask for a change once their request is locked
    (section 27) without unlocking normal editing."""

    __tablename__ = "equipment_change_requests"

    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_requests.id"), nullable=False)
    message = db.Column(db.Text, nullable=False)
    status = db.Column(
        db.Enum(ChangeRequestStatus, name="change_request_status"), default=ChangeRequestStatus.PENDING, nullable=False
    )
    admin_response = db.Column(db.Text)
    created_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    resolved_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    resolved_at = db.Column(db.DateTime(timezone=True))

    request = db.relationship("CustomerEquipmentRequest", back_populates="change_requests")
    created_by = db.relationship("User", foreign_keys=[created_by_id])
    resolved_by = db.relationship("User", foreign_keys=[resolved_by_id])
