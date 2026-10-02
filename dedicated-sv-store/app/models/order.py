import enum
import random
import string

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class OrderItemType(str, enum.Enum):
    SERVER = "server"
    CONFIGURATION = "configuration"


class OrderStatus(str, enum.Enum):
    PENDING = "pending"
    AWAITING_PAYMENT = "awaiting_payment"
    PAID = "paid"
    PROCESSING = "processing"
    PROVISIONING = "provisioning"
    READY = "ready"
    SHIPPED = "shipped"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    REFUNDED = "refunded"


ORDER_PROGRESS_STEPS = ["Placed", "Paid", "Processing", "Provisioning", "Ready", "Shipped", "Completed"]

ORDER_STATUS_TO_STEP_INDEX = {
    OrderStatus.PENDING: 0,
    OrderStatus.AWAITING_PAYMENT: 0,
    OrderStatus.PAID: 1,
    OrderStatus.PROCESSING: 2,
    OrderStatus.PROVISIONING: 3,
    OrderStatus.READY: 4,
    OrderStatus.SHIPPED: 5,
    OrderStatus.COMPLETED: 6,
    OrderStatus.CANCELLED: 0,
    OrderStatus.REFUNDED: 0,
}


class OrderPaymentStatus(str, enum.Enum):
    UNPAID = "unpaid"
    PAID = "paid"
    PARTIALLY_PAID = "partially_paid"
    REFUNDED = "refunded"


class FulfilmentStatus(str, enum.Enum):
    PENDING = "pending"
    PROCESSING = "processing"
    PROVISIONING = "provisioning"
    READY = "ready"
    SHIPPED = "shipped"
    COMPLETED = "completed"


def _generate_order_number():
    return "ORD-" + "".join(random.choices(string.digits, k=8))


class Order(db.Model, TimestampMixin):
    __tablename__ = "orders"

    id = db.Column(db.Integer, primary_key=True)
    order_number = db.Column(db.String(20), unique=True, default=_generate_order_number, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    seller_id = db.Column(db.Integer, db.ForeignKey("seller_profiles.id"))

    subtotal = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    tax = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    discount = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    shipping = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    setup_total = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    total = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    currency = db.Column(db.String(3), default="GBP", nullable=False)

    status = db.Column(db.Enum(OrderStatus, name="order_status"), default=OrderStatus.PENDING, nullable=False)
    payment_status = db.Column(
        db.Enum(OrderPaymentStatus, name="order_payment_status"), default=OrderPaymentStatus.UNPAID, nullable=False
    )
    fulfilment_status = db.Column(
        db.Enum(FulfilmentStatus, name="order_fulfilment_status"), default=FulfilmentStatus.PENDING, nullable=False
    )

    user = db.relationship("User")
    seller = db.relationship("SellerProfile")
    items = db.relationship("OrderItem", back_populates="order", cascade="all, delete-orphan")
    status_history = db.relationship(
        "OrderStatusHistory", back_populates="order", cascade="all, delete-orphan",
        order_by="OrderStatusHistory.created_at",
    )

    def __repr__(self):
        return f"<Order {self.order_number}>"

    def set_status(self, new_status, changed_by_id=None, note=None):
        old_status = self.status
        if old_status == new_status:
            return
        self.status = new_status
        db.session.add(
            OrderStatusHistory(
                order_id=self.id, old_status=old_status, new_status=new_status,
                changed_by_id=changed_by_id, note=note,
            )
        )

    @property
    def progress_info(self):
        current_index = ORDER_STATUS_TO_STEP_INDEX.get(self.status, 0)
        total_steps = len(ORDER_PROGRESS_STEPS)
        stopped = self.status in (OrderStatus.CANCELLED, OrderStatus.REFUNDED)
        percent = 0 if stopped else round((current_index + 1) / total_steps * 100)
        stopped_label = None
        if self.status == OrderStatus.CANCELLED:
            stopped_label = "This order was cancelled."
        elif self.status == OrderStatus.REFUNDED:
            stopped_label = "This order was refunded."
        return {
            "steps": ORDER_PROGRESS_STEPS,
            "current_index": current_index,
            "percent": percent,
            "stopped": stopped,
            "stopped_label": stopped_label,
        }


class OrderItem(db.Model, TimestampMixin):
    __tablename__ = "order_items"

    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer, db.ForeignKey("orders.id"), nullable=False)
    item_type = db.Column(db.Enum(OrderItemType, name="order_item_type"), nullable=False)
    server_id = db.Column(db.Integer, db.ForeignKey("servers.id"))
    configuration_id = db.Column(db.Integer, db.ForeignKey("server_configurations.id"))

    title_snapshot = db.Column(db.String(255), nullable=False)
    specs_snapshot = db.Column(db.JSON, default=dict)

    unit_monthly_price = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    unit_setup_fee = db.Column(db.Numeric(10, 2), default=0, nullable=False)
    quantity = db.Column(db.Integer, default=1, nullable=False)
    line_total = db.Column(db.Numeric(10, 2), default=0, nullable=False)

    order = db.relationship("Order", back_populates="items")
    server = db.relationship("Server")
    configuration = db.relationship("ServerConfiguration")


class OrderStatusHistory(db.Model):
    __tablename__ = "order_status_history"

    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer, db.ForeignKey("orders.id"), nullable=False)
    old_status = db.Column(db.Enum(OrderStatus, name="order_status_old"))
    new_status = db.Column(db.Enum(OrderStatus, name="order_status_new"), nullable=False)
    changed_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    note = db.Column(db.String(255))
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    order = db.relationship("Order", back_populates="status_history")
    changed_by = db.relationship("User")


class CartItem(db.Model, TimestampMixin):
    __tablename__ = "cart_items"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    item_type = db.Column(db.Enum(OrderItemType, name="cart_item_type"), nullable=False)
    server_id = db.Column(db.Integer, db.ForeignKey("servers.id"))
    configuration_id = db.Column(db.Integer, db.ForeignKey("server_configurations.id"))
    quantity = db.Column(db.Integer, default=1, nullable=False)

    user = db.relationship("User")
    server = db.relationship("Server")
    configuration = db.relationship("ServerConfiguration")

    def resolve_seller_id(self):
        if self.item_type == OrderItemType.SERVER and self.server:
            return self.server.seller_id
        return None

    def resolve_title(self):
        if self.item_type == OrderItemType.SERVER and self.server:
            return self.server.title
        if self.item_type == OrderItemType.CONFIGURATION and self.configuration:
            return self.configuration.name
        return "Unknown item"

    def resolve_monthly_price(self):
        if self.item_type == OrderItemType.SERVER and self.server:
            return self.server.monthly_price
        if self.item_type == OrderItemType.CONFIGURATION and self.configuration:
            return self.configuration.monthly_price
        return 0

    def resolve_setup_fee(self):
        if self.item_type == OrderItemType.SERVER and self.server:
            return self.server.setup_fee or 0
        if self.item_type == OrderItemType.CONFIGURATION and self.configuration:
            return self.configuration.setup_fee or 0
        return 0
