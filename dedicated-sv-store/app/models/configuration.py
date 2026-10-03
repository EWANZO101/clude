import enum

from app.extensions import db
from app.models.base import TimestampMixin
from app.models.server import ComponentType  # re-exported for convenience


class ConfigurationStatus(str, enum.Enum):
    DRAFT = "draft"
    SAVED = "saved"
    ORDERED = "ordered"


class RuleType(str, enum.Enum):
    SOCKET_MATCH = "socket_match"
    MEMORY_GENERATION_MATCH = "memory_generation_match"
    MAX_DRIVE_BAYS = "max_drive_bays"
    MAX_GPU_COUNT = "max_gpu_count"
    MAX_PSU_COUNT = "max_psu_count"
    PSU_WATTAGE_SUFFICIENT = "psu_wattage_sufficient"
    DRIVE_INTERFACE_MATCH = "drive_interface_match"


class PricingMethod(str, enum.Enum):
    PASS_THROUGH = "pass_through"
    MARKUP_PERCENT = "markup_percent"
    MARKUP_AMOUNT = "markup_amount"


class CompatibilityRule(db.Model, TimestampMixin):
    __tablename__ = "compatibility_rules"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(150), nullable=False)
    description = db.Column(db.Text)
    rule_type = db.Column(db.Enum(RuleType, name="compat_rule_type"), nullable=False)
    params = db.Column(db.JSON, default=dict)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def __repr__(self):
        return f"<CompatibilityRule {self.name}>"


class PricingRule(db.Model, TimestampMixin):
    __tablename__ = "pricing_rules"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(150), nullable=False)
    component_type = db.Column(db.Enum(ComponentType, name="pricing_component_type"))
    method = db.Column(db.Enum(PricingMethod, name="pricing_method"), nullable=False)
    value = db.Column(db.Numeric(10, 4), default=0)
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def __repr__(self):
        return f"<PricingRule {self.name}>"

    def apply(self, base_price):
        """base_price must be a Decimal; returns a Decimal. Money math stays
        in Decimal throughout to avoid binary floating-point rounding drift."""
        from decimal import Decimal

        value = Decimal(str(self.value or 0))
        if self.method == PricingMethod.PASS_THROUGH:
            return base_price
        if self.method == PricingMethod.MARKUP_PERCENT:
            return base_price * (1 + (value / 100))
        if self.method == PricingMethod.MARKUP_AMOUNT:
            return base_price + value
        return base_price


class ServerConfiguration(db.Model, TimestampMixin):
    __tablename__ = "server_configurations"

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)

    name = db.Column(db.String(255), default="Custom Build")
    operating_system = db.Column(db.String(100))
    country = db.Column(db.String(2))
    datacenter_name = db.Column(db.String(150))
    additional_services = db.Column(db.JSON, default=list)
    bandwidth_mbps = db.Column(db.Integer)
    ip_addresses = db.Column(db.Integer, default=1)

    status = db.Column(
        db.Enum(ConfigurationStatus, name="configuration_status"),
        default=ConfigurationStatus.DRAFT,
        nullable=False,
    )

    monthly_price = db.Column(db.Numeric(10, 2))
    setup_fee = db.Column(db.Numeric(10, 2))
    currency = db.Column(db.String(3), default="GBP")

    user = db.relationship("User")
    components = db.relationship(
        "ConfigurationComponent", back_populates="configuration", cascade="all, delete-orphan"
    )

    def __repr__(self):
        return f"<ServerConfiguration {self.id} user={self.user_id}>"


class ConfigurationComponent(db.Model, TimestampMixin):
    __tablename__ = "configuration_components"

    id = db.Column(db.Integer, primary_key=True)
    configuration_id = db.Column(db.Integer, db.ForeignKey("server_configurations.id"), nullable=False)
    component_type = db.Column(db.Enum(ComponentType, name="config_component_type"), nullable=False)
    hardware_id = db.Column(db.Integer, nullable=False)
    quantity = db.Column(db.Integer, default=1, nullable=False)

    configuration = db.relationship("ServerConfiguration", back_populates="components")

    def resolve_hardware(self):
        from app.hardware.registry import HARDWARE_REGISTRY

        entry = HARDWARE_REGISTRY.get(self.component_type.value)
        if not entry:
            return None
        return db.session.get(entry["model"], self.hardware_id)
