import enum

from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class ServerStatus(str, enum.Enum):
    DRAFT = "draft"
    PUBLISHED = "published"
    DISABLED = "disabled"


class InventoryStatus(str, enum.Enum):
    AVAILABLE = "available"
    RESERVED = "reserved"
    SOLD = "sold"
    MAINTENANCE = "maintenance"
    PROVISIONING = "provisioning"
    OFFLINE = "offline"
    UNAVAILABLE = "unavailable"


class ComponentType(str, enum.Enum):
    CPU = "cpus"
    RAM = "ram"
    STORAGE = "storage"
    GPU = "gpus"
    NETWORK_CARD = "network-cards"
    RAID_CONTROLLER = "raid-controllers"
    POWER_SUPPLY = "power-supplies"
    CHASSIS = "chassis"


class Category(db.Model, TimestampMixin):
    __tablename__ = "categories"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), unique=True, nullable=False)
    slug = db.Column(db.String(100), unique=True, nullable=False, index=True)
    description = db.Column(db.Text)
    sort_order = db.Column(db.Integer, default=0, nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def __repr__(self):
        return f"<Category {self.name}>"


class Server(db.Model, TimestampMixin):
    __tablename__ = "servers"

    id = db.Column(db.Integer, primary_key=True)
    seller_id = db.Column(db.Integer, db.ForeignKey("seller_profiles.id"))
    category_id = db.Column(db.Integer, db.ForeignKey("categories.id"))

    manufacturer = db.Column(db.String(100))
    model = db.Column(db.String(100))
    sku = db.Column(db.String(100))
    serial_number = db.Column(db.String(100))
    asset_number = db.Column(db.String(100))

    title = db.Column(db.String(255), nullable=False)
    slug = db.Column(db.String(255), unique=True, nullable=False, index=True)
    description = db.Column(db.Text)

    cpu_summary = db.Column(db.String(255))
    cpu_count = db.Column(db.Integer, default=1)
    cpu_cores = db.Column(db.Integer)
    cpu_threads = db.Column(db.Integer)

    ram_summary = db.Column(db.String(255))
    ram_capacity_gb = db.Column(db.Integer)
    ram_slots = db.Column(db.Integer)

    storage_summary = db.Column(db.String(255))
    storage_type = db.Column(db.String(50))
    storage_capacity_gb = db.Column(db.Integer)
    drive_count = db.Column(db.Integer)

    gpu_summary = db.Column(db.String(255))
    gpu_count = db.Column(db.Integer, default=0)

    network_summary = db.Column(db.String(255))
    network_ports = db.Column(db.Integer)
    bandwidth_mbps = db.Column(db.Integer)
    ip_addresses_included = db.Column(db.Integer, default=1)

    raid_summary = db.Column(db.String(255))

    psu_count = db.Column(db.Integer)
    psu_wattage = db.Column(db.Integer)

    chassis_summary = db.Column(db.String(255))
    rack_units = db.Column(db.Numeric(3, 1))

    operating_system = db.Column(db.String(100))

    monthly_price = db.Column(db.Numeric(10, 2), nullable=False)
    one_time_price = db.Column(db.Numeric(10, 2))
    setup_fee = db.Column(db.Numeric(10, 2))
    currency = db.Column(db.String(3), default="GBP", nullable=False)

    status = db.Column(db.Enum(ServerStatus, name="server_status"), default=ServerStatus.DRAFT, nullable=False)
    inventory_status = db.Column(
        db.Enum(InventoryStatus, name="inventory_status"), default=InventoryStatus.AVAILABLE, nullable=False
    )
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    published_at = db.Column(db.DateTime(timezone=True))

    seller = db.relationship("SellerProfile")
    category = db.relationship("Category")
    location = db.relationship(
        "ServerLocation", back_populates="server", uselist=False, cascade="all, delete-orphan"
    )
    components = db.relationship(
        "ServerComponent", back_populates="server", cascade="all, delete-orphan"
    )
    images = db.relationship(
        "ServerImage", back_populates="server", cascade="all, delete-orphan",
        order_by="ServerImage.sort_order",
    )
    inventory_events = db.relationship(
        "ServerInventoryEvent", back_populates="server", cascade="all, delete-orphan"
    )

    def __repr__(self):
        return f"<Server {self.title}>"

    def set_inventory_status(self, new_status, changed_by_id=None, reason=None):
        old_status = self.inventory_status
        if old_status == new_status:
            return
        self.inventory_status = new_status
        db.session.add(
            ServerInventoryEvent(
                server_id=self.id,
                old_status=old_status,
                new_status=new_status,
                changed_by_id=changed_by_id,
                reason=reason,
            )
        )

    @classmethod
    def try_reserve(cls, server_id):
        """Atomically flips an available server to reserved.

        Returns True if this call won the race, False if another request
        already reserved/sold it first. Uses a conditional UPDATE rather than
        SELECT ... FOR UPDATE + check, so it works correctly under concurrent
        requests without holding a long-lived row lock.
        """
        result = db.session.execute(
            db.update(cls)
            .where(cls.id == server_id, cls.inventory_status == InventoryStatus.AVAILABLE)
            .values(inventory_status=InventoryStatus.RESERVED)
        )
        won = result.rowcount == 1
        if won:
            db.session.add(
                ServerInventoryEvent(
                    server_id=server_id,
                    old_status=InventoryStatus.AVAILABLE,
                    new_status=InventoryStatus.RESERVED,
                    reason="Reserved for checkout",
                )
            )
        return won


class ServerLocation(db.Model, TimestampMixin):
    __tablename__ = "server_locations"

    id = db.Column(db.Integer, primary_key=True)
    server_id = db.Column(db.Integer, db.ForeignKey("servers.id"), unique=True, nullable=False)

    country = db.Column(db.String(2))
    region = db.Column(db.String(100))
    city = db.Column(db.String(100))
    datacenter_name = db.Column(db.String(150))
    datacenter_code = db.Column(db.String(20))
    rack = db.Column(db.String(50))
    row = db.Column(db.String(50))
    rack_unit = db.Column(db.String(20))
    power_feed = db.Column(db.String(50))
    network_provider = db.Column(db.String(100))
    vlan = db.Column(db.String(50))
    switch_name = db.Column(db.String(100))
    switch_port = db.Column(db.String(50))

    server = db.relationship("Server", back_populates="location")


class ServerComponent(db.Model, TimestampMixin):
    __tablename__ = "server_components"

    id = db.Column(db.Integer, primary_key=True)
    server_id = db.Column(db.Integer, db.ForeignKey("servers.id"), nullable=False)
    component_type = db.Column(db.Enum(ComponentType, name="component_type"), nullable=False)
    hardware_id = db.Column(db.Integer, nullable=False)
    label_override = db.Column(db.String(255))
    quantity = db.Column(db.Integer, default=1, nullable=False)

    server = db.relationship("Server", back_populates="components")

    def resolve_hardware(self):
        from app.hardware.registry import HARDWARE_REGISTRY

        entry = HARDWARE_REGISTRY.get(self.component_type.value)
        if not entry:
            return None
        return db.session.get(entry["model"], self.hardware_id)


class ServerImage(db.Model, TimestampMixin):
    __tablename__ = "server_images"

    id = db.Column(db.Integer, primary_key=True)
    server_id = db.Column(db.Integer, db.ForeignKey("servers.id"), nullable=False)
    image_path = db.Column(db.String(500), nullable=False)
    alt_text = db.Column(db.String(255))
    sort_order = db.Column(db.Integer, default=0, nullable=False)
    is_primary = db.Column(db.Boolean, default=False, nullable=False)

    server = db.relationship("Server", back_populates="images")


class ServerInventoryEvent(db.Model):
    __tablename__ = "server_inventory_events"

    id = db.Column(db.Integer, primary_key=True)
    server_id = db.Column(db.Integer, db.ForeignKey("servers.id"), nullable=False)
    old_status = db.Column(db.Enum(InventoryStatus, name="inventory_status_old"))
    new_status = db.Column(db.Enum(InventoryStatus, name="inventory_status_new"), nullable=False)
    changed_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    reason = db.Column(db.String(255))
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    server = db.relationship("Server", back_populates="inventory_events")
    changed_by = db.relationship("User")


class Favourite(db.Model):
    __tablename__ = "favourites"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    server_id = db.Column(db.Integer, db.ForeignKey("servers.id"), nullable=False)
    created_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    user = db.relationship("User")
    server = db.relationship("Server")

    __table_args__ = (db.UniqueConstraint("user_id", "server_id", name="uq_favourite_user_server"),)
