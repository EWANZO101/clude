from app.extensions import db
from app.models.base import TimestampMixin, utcnow


class Datacenter(db.Model, TimestampMixin):
    __tablename__ = "datacenters"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(150), nullable=False)
    code = db.Column(db.String(20), unique=True, nullable=False)
    country = db.Column(db.String(2))
    city = db.Column(db.String(100))
    address = db.Column(db.String(255))
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    racks = db.relationship("Rack", back_populates="datacenter", cascade="all, delete-orphan")

    def __repr__(self):
        return f"<Datacenter {self.code}>"


class Rack(db.Model, TimestampMixin):
    __tablename__ = "racks"

    id = db.Column(db.Integer, primary_key=True)
    datacenter_id = db.Column(db.Integer, db.ForeignKey("datacenters.id"), nullable=False)
    name = db.Column(db.String(50), nullable=False)
    row = db.Column(db.String(50))
    total_u = db.Column(db.Integer, default=42, nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    datacenter = db.relationship("Datacenter", back_populates="racks")
    rack_assignments = db.relationship("RackAssignment", back_populates="rack")

    def __repr__(self):
        return f"<Rack {self.datacenter.code if self.datacenter else '?'}/{self.name}>"

    @property
    def used_u(self):
        return sum(a.u_height or 0 for a in self.rack_assignments)


class RackAssignment(db.Model, TimestampMixin):
    __tablename__ = "rack_assignments"

    id = db.Column(db.Integer, primary_key=True)
    equipment_item_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_items.id"), nullable=False)
    rack_id = db.Column(db.Integer, db.ForeignKey("racks.id"), nullable=False)
    start_u = db.Column(db.Integer, nullable=False)
    u_height = db.Column(db.Numeric(4, 1), default=1)
    assigned_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    assigned_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    equipment_item = db.relationship("CustomerEquipmentItem")
    rack = db.relationship("Rack", back_populates="rack_assignments")
    assigned_by = db.relationship("User")

    __table_args__ = (db.UniqueConstraint("equipment_item_id", name="uq_rack_assignment_item"),)


class PowerAssignment(db.Model, TimestampMixin):
    __tablename__ = "power_assignments"

    id = db.Column(db.Integer, primary_key=True)
    equipment_item_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_items.id"), nullable=False)
    power_feed_a = db.Column(db.String(50))
    power_feed_b = db.Column(db.String(50))
    pdu_outlet_a = db.Column(db.String(50))
    pdu_outlet_b = db.Column(db.String(50))
    amperage = db.Column(db.Numeric(5, 2))
    assigned_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    assigned_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    equipment_item = db.relationship("CustomerEquipmentItem")
    assigned_by = db.relationship("User")

    __table_args__ = (db.UniqueConstraint("equipment_item_id", name="uq_power_assignment_item"),)


class NetworkAssignment(db.Model, TimestampMixin):
    __tablename__ = "network_assignments"

    id = db.Column(db.Integer, primary_key=True)
    equipment_item_id = db.Column(db.Integer, db.ForeignKey("customer_equipment_items.id"), nullable=False)
    switch_name = db.Column(db.String(100))
    switch_port = db.Column(db.String(50))
    vlan = db.Column(db.String(50))
    management_ip = db.Column(db.String(45))
    public_ipv4 = db.Column(db.String(45))
    public_ipv6 = db.Column(db.String(100))
    bandwidth_mbps = db.Column(db.Integer)
    assigned_by_id = db.Column(db.Integer, db.ForeignKey("users.id"))
    assigned_at = db.Column(db.DateTime(timezone=True), default=utcnow, nullable=False)

    equipment_item = db.relationship("CustomerEquipmentItem")
    assigned_by = db.relationship("User")

    __table_args__ = (db.UniqueConstraint("equipment_item_id", name="uq_network_assignment_item"),)
