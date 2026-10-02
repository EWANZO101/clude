from flask_wtf import FlaskForm
from wtforms import (
    StringField,
    IntegerField,
    DecimalField,
    BooleanField,
    SelectField,
    TextAreaField,
    FieldList,
)
from wtforms.validators import DataRequired, Optional, Length

from app.models.hardware import Availability, StorageType, TransceiverType

AVAILABILITY_CHOICES = [(a.value, a.name.replace("_", " ").title()) for a in Availability]


class BaseHardwareForm(FlaskForm):
    brand_id = SelectField("Brand", coerce=int, validators=[DataRequired()])
    model_name = StringField("Model name", validators=[DataRequired(), Length(max=255)])
    sku = StringField("SKU", validators=[Optional(), Length(max=100)])
    price = DecimalField("Price", validators=[Optional()], places=2)
    availability = SelectField("Availability", choices=AVAILABILITY_CHOICES, default=Availability.IN_STOCK.value)
    product_url = StringField("Product URL", validators=[Optional(), Length(max=500)])
    is_active = BooleanField("Active", default=True)
    notes = TextAreaField("Notes", validators=[Optional()])


class CpuForm(BaseHardwareForm):
    family = StringField("Family", validators=[Optional(), Length(max=100)])
    generation = StringField("Generation", validators=[Optional(), Length(max=50)])
    socket = StringField("Socket", validators=[Optional(), Length(max=50)])
    architecture = StringField("Architecture", validators=[Optional(), Length(max=50)])
    cores = IntegerField("Cores", validators=[Optional()])
    threads = IntegerField("Threads", validators=[Optional()])
    base_clock_ghz = DecimalField("Base clock (GHz)", validators=[Optional()], places=2)
    boost_clock_ghz = DecimalField("Boost clock (GHz)", validators=[Optional()], places=2)
    tdp_watts = IntegerField("TDP (W)", validators=[Optional()])
    cache_mb = IntegerField("Cache (MB)", validators=[Optional()])
    pcie_generation = StringField("PCIe generation", validators=[Optional(), Length(max=10)])
    ecc_support = BooleanField("ECC support")
    integrated_graphics = BooleanField("Integrated graphics")


class RamModuleForm(BaseHardwareForm):
    part_number = StringField("Part number", validators=[Optional(), Length(max=100)])
    ddr_generation = StringField("DDR generation", validators=[Optional(), Length(max=20)])
    capacity_gb = IntegerField("Capacity (GB)", validators=[Optional()])
    speed_mhz = IntegerField("Speed (MHz)", validators=[Optional()])
    ecc = BooleanField("ECC")
    registered = BooleanField("Registered")
    buffered = BooleanField("Buffered")
    dimm_type = StringField("DIMM type", validators=[Optional(), Length(max=20)])
    rank = StringField("Rank", validators=[Optional(), Length(max=20)])
    voltage = DecimalField("Voltage", validators=[Optional()], places=2)


class StorageDeviceForm(BaseHardwareForm):
    storage_type = SelectField(
        "Storage type",
        choices=[(s.value, s.name.replace("_", " ").title()) for s in StorageType],
        validators=[DataRequired()],
    )
    capacity_gb = IntegerField("Capacity (GB)", validators=[Optional()])
    interface = StringField("Interface", validators=[Optional(), Length(max=50)])
    form_factor = StringField("Form factor", validators=[Optional(), Length(max=20)])
    rpm = IntegerField("RPM", validators=[Optional()])
    cache_mb = IntegerField("Cache (MB)", validators=[Optional()])
    enterprise_rating = StringField("Enterprise rating", validators=[Optional(), Length(max=50)])
    workload_rating_tb_per_year = IntegerField("Workload rating (TB/year)", validators=[Optional()])
    pcie_generation = StringField("PCIe generation", validators=[Optional(), Length(max=10)])
    lane_count = IntegerField("Lane count", validators=[Optional()])
    read_speed_mbps = IntegerField("Read speed (MB/s)", validators=[Optional()])
    write_speed_mbps = IntegerField("Write speed (MB/s)", validators=[Optional()])
    random_read_iops = IntegerField("Random read IOPS", validators=[Optional()])
    random_write_iops = IntegerField("Random write IOPS", validators=[Optional()])
    endurance_dwpd = DecimalField("Endurance (DWPD)", validators=[Optional()], places=2)
    tbw = IntegerField("TBW", validators=[Optional()])


class GpuForm(BaseHardwareForm):
    architecture = StringField("Architecture", validators=[Optional(), Length(max=50)])
    vram_gb = IntegerField("VRAM (GB)", validators=[Optional()])
    gpu_cores = IntegerField("GPU cores", validators=[Optional()])
    power_watts = IntegerField("Power (W)", validators=[Optional()])
    pcie_generation = StringField("PCIe generation", validators=[Optional(), Length(max=10)])
    length_mm = IntegerField("Length (mm)", validators=[Optional()])
    width_mm = IntegerField("Width (mm)", validators=[Optional()])
    height_mm = IntegerField("Height (mm)", validators=[Optional()])
    cooling_type = StringField("Cooling type", validators=[Optional(), Length(max=50)])


class NetworkCardForm(BaseHardwareForm):
    port_count = IntegerField("Port count", validators=[Optional()])
    port_type = StringField("Port type", validators=[Optional(), Length(max=50)])
    port_speed_gbps = DecimalField("Port speed (Gbps)", validators=[Optional()], places=2)
    interface = StringField("Interface", validators=[Optional(), Length(max=50)])


class RaidControllerForm(BaseHardwareForm):
    cache_mb = IntegerField("Cache (MB)", validators=[Optional()])
    interface = StringField("Interface", validators=[Optional(), Length(max=50)])
    port_count = IntegerField("Port count", validators=[Optional()])


class PowerSupplyForm(BaseHardwareForm):
    wattage = IntegerField("Wattage", validators=[Optional()])
    form_factor = StringField("Form factor", validators=[Optional(), Length(max=20)])
    efficiency_rating = StringField("Efficiency rating", validators=[Optional(), Length(max=20)])
    redundant = BooleanField("Redundant")


class ServerChassisForm(BaseHardwareForm):
    form_factor = StringField("Form factor", validators=[Optional(), Length(max=20)])
    rack_units = DecimalField("Rack units", validators=[Optional()], places=1)
    drive_bays = IntegerField("Drive bays", validators=[Optional()])
    max_gpu_count = IntegerField("Max GPU count", validators=[Optional()])
    max_psu_count = IntegerField("Max PSU count", validators=[Optional()])
    dimensions = StringField("Dimensions", validators=[Optional(), Length(max=100)])
    weight_kg = DecimalField("Weight (kg)", validators=[Optional()], places=2)


class NetworkingDeviceForm(BaseHardwareForm):
    port_count = IntegerField("Port count", validators=[Optional()])
    port_type = StringField("Port type", validators=[Optional(), Length(max=50)])
    port_speed_gbps = DecimalField("Port speed (Gbps)", validators=[Optional()], places=2)
    interface = StringField("Interface", validators=[Optional(), Length(max=50)])
    power_requirements = StringField("Power requirements", validators=[Optional(), Length(max=100)])
    rack_units = DecimalField("Rack units", validators=[Optional()], places=1)
    dimensions = StringField("Dimensions", validators=[Optional(), Length(max=100)])
    weight_kg = DecimalField("Weight (kg)", validators=[Optional()], places=2)
    firmware_version = StringField("Firmware version", validators=[Optional(), Length(max=50)])


class NetworkSwitchForm(NetworkingDeviceForm):
    managed = BooleanField("Managed", default=True)


class RouterForm(NetworkingDeviceForm):
    pass


class FirewallForm(NetworkingDeviceForm):
    throughput_gbps = DecimalField("Throughput (Gbps)", validators=[Optional()], places=2)


class TransceiverForm(BaseHardwareForm):
    transceiver_type = SelectField(
        "Transceiver type",
        choices=[(t.value, t.name.replace("_", " ").upper()) for t in TransceiverType],
        validators=[DataRequired()],
    )
    port_speed_gbps = DecimalField("Port speed (Gbps)", validators=[Optional()], places=2)
    connector_type = StringField("Connector type", validators=[Optional(), Length(max=50)])
    wavelength_nm = IntegerField("Wavelength (nm)", validators=[Optional()])
    max_distance_m = IntegerField("Max distance (m)", validators=[Optional()])


class HardwareBrandForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(max=100)])
    logo_path = StringField("Logo URL", validators=[Optional(), Length(max=500)])
    is_active = BooleanField("Active", default=True)
