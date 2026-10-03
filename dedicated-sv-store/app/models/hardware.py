import enum

from app.extensions import db
from app.models.base import TimestampMixin


class Availability(str, enum.Enum):
    IN_STOCK = "in_stock"
    LIMITED = "limited"
    OUT_OF_STOCK = "out_of_stock"
    DISCONTINUED = "discontinued"


class StorageType(str, enum.Enum):
    HDD = "hdd"
    SATA_SSD = "sata_ssd"
    NVME_SSD = "nvme_ssd"


class TransceiverType(str, enum.Enum):
    SFP = "sfp"
    SFP_PLUS = "sfp_plus"
    SFP28 = "sfp28"
    QSFP = "qsfp"
    QSFP28 = "qsfp28"


class HardwareBrand(db.Model, TimestampMixin):
    __tablename__ = "hardware_brands"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), unique=True, nullable=False)
    slug = db.Column(db.String(100), unique=True, nullable=False, index=True)
    logo_path = db.Column(db.String(500))
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def __repr__(self):
        return f"<HardwareBrand {self.name}>"


class HardwareBaseMixin:
    """Common columns shared by every hardware catalog table."""

    id = db.Column(db.Integer, primary_key=True)
    model_name = db.Column(db.String(255), nullable=False)
    sku = db.Column(db.String(100))
    price = db.Column(db.Numeric(10, 2))
    availability = db.Column(
        db.Enum(Availability, name="hw_availability"), default=Availability.IN_STOCK, nullable=False
    )
    release_date = db.Column(db.Date)
    product_url = db.Column(db.String(500))
    image_path = db.Column(db.String(500))
    external_provider_id = db.Column(db.String(100), index=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    merged_into_id = db.Column(db.Integer)
    notes = db.Column(db.Text)


class Cpu(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "cpus"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    family = db.Column(db.String(100))
    generation = db.Column(db.String(50))
    socket = db.Column(db.String(50))
    architecture = db.Column(db.String(50))
    cores = db.Column(db.Integer)
    threads = db.Column(db.Integer)
    base_clock_ghz = db.Column(db.Numeric(4, 2))
    boost_clock_ghz = db.Column(db.Numeric(4, 2))
    tdp_watts = db.Column(db.Integer)
    cache_mb = db.Column(db.Integer)
    pcie_generation = db.Column(db.String(10))
    memory_support = db.Column(db.JSON, default=list)
    ecc_support = db.Column(db.Boolean, default=False)
    integrated_graphics = db.Column(db.Boolean, default=False)

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<Cpu {self.model_name}>"


class RamModule(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "ram_modules"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    part_number = db.Column(db.String(100))
    ddr_generation = db.Column(db.String(20))
    capacity_gb = db.Column(db.Integer)
    speed_mhz = db.Column(db.Integer)
    ecc = db.Column(db.Boolean, default=False)
    registered = db.Column(db.Boolean, default=False)
    buffered = db.Column(db.Boolean, default=False)
    dimm_type = db.Column(db.String(20))
    rank = db.Column(db.String(20))
    voltage = db.Column(db.Numeric(3, 2))

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<RamModule {self.model_name}>"


class StorageDevice(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "storage_devices"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    storage_type = db.Column(db.Enum(StorageType, name="storage_type"), nullable=False)
    capacity_gb = db.Column(db.Integer)
    interface = db.Column(db.String(50))
    form_factor = db.Column(db.String(20))

    # HDD-specific
    rpm = db.Column(db.Integer)
    cache_mb = db.Column(db.Integer)
    enterprise_rating = db.Column(db.String(50))
    workload_rating_tb_per_year = db.Column(db.Integer)

    # SSD/NVMe-specific
    pcie_generation = db.Column(db.String(10))
    lane_count = db.Column(db.Integer)
    read_speed_mbps = db.Column(db.Integer)
    write_speed_mbps = db.Column(db.Integer)
    random_read_iops = db.Column(db.Integer)
    random_write_iops = db.Column(db.Integer)
    endurance_dwpd = db.Column(db.Numeric(5, 2))
    tbw = db.Column(db.Integer)

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<StorageDevice {self.model_name}>"


class Gpu(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "gpus"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    architecture = db.Column(db.String(50))
    vram_gb = db.Column(db.Integer)
    gpu_cores = db.Column(db.Integer)
    power_watts = db.Column(db.Integer)
    pcie_generation = db.Column(db.String(10))
    length_mm = db.Column(db.Integer)
    width_mm = db.Column(db.Integer)
    height_mm = db.Column(db.Integer)
    cooling_type = db.Column(db.String(50))
    server_compatibility = db.Column(db.JSON, default=list)

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<Gpu {self.model_name}>"


class NetworkCard(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "network_cards"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    port_count = db.Column(db.Integer)
    port_type = db.Column(db.String(50))
    port_speed_gbps = db.Column(db.Numeric(6, 2))
    interface = db.Column(db.String(50))

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<NetworkCard {self.model_name}>"


class RaidController(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "raid_controllers"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    supported_raid_levels = db.Column(db.JSON, default=list)
    cache_mb = db.Column(db.Integer)
    interface = db.Column(db.String(50))
    port_count = db.Column(db.Integer)

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<RaidController {self.model_name}>"


class PowerSupply(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "power_supplies"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    wattage = db.Column(db.Integer)
    form_factor = db.Column(db.String(20))
    efficiency_rating = db.Column(db.String(20))
    redundant = db.Column(db.Boolean, default=False)

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<PowerSupply {self.model_name}>"


class ServerChassis(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "server_chassis"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    form_factor = db.Column(db.String(20))
    rack_units = db.Column(db.Numeric(3, 1))
    drive_bays = db.Column(db.Integer)
    max_gpu_count = db.Column(db.Integer)
    max_psu_count = db.Column(db.Integer)
    dimensions = db.Column(db.String(100))
    weight_kg = db.Column(db.Numeric(6, 2))

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<ServerChassis {self.model_name}>"


class NetworkingDeviceMixin(HardwareBaseMixin):
    port_count = db.Column(db.Integer)
    port_type = db.Column(db.String(50))
    port_speed_gbps = db.Column(db.Numeric(6, 2))
    interface = db.Column(db.String(50))
    power_requirements = db.Column(db.String(100))
    rack_units = db.Column(db.Numeric(3, 1))
    dimensions = db.Column(db.String(100))
    weight_kg = db.Column(db.Numeric(6, 2))
    firmware_version = db.Column(db.String(50))


class NetworkSwitch(db.Model, NetworkingDeviceMixin, TimestampMixin):
    __tablename__ = "network_switches"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    managed = db.Column(db.Boolean, default=True)

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<NetworkSwitch {self.model_name}>"


class Router(db.Model, NetworkingDeviceMixin, TimestampMixin):
    __tablename__ = "routers"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    routing_protocols = db.Column(db.JSON, default=list)

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<Router {self.model_name}>"


class Firewall(db.Model, NetworkingDeviceMixin, TimestampMixin):
    __tablename__ = "firewalls"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    throughput_gbps = db.Column(db.Numeric(6, 2))

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<Firewall {self.model_name}>"


class Transceiver(db.Model, HardwareBaseMixin, TimestampMixin):
    __tablename__ = "transceivers"

    brand_id = db.Column(db.Integer, db.ForeignKey("hardware_brands.id"), nullable=False)
    transceiver_type = db.Column(db.Enum(TransceiverType, name="transceiver_type"), nullable=False)
    port_speed_gbps = db.Column(db.Numeric(6, 2))
    connector_type = db.Column(db.String(50))
    wavelength_nm = db.Column(db.Integer)
    max_distance_m = db.Column(db.Integer)

    brand = db.relationship("HardwareBrand", foreign_keys=[brand_id])

    def __repr__(self):
        return f"<Transceiver {self.model_name}>"
