from flask_wtf import FlaskForm
from flask_wtf.file import FileField, FileRequired, FileAllowed
from wtforms import StringField, IntegerField, DecimalField, TextAreaField, SelectField, BooleanField
from wtforms.validators import DataRequired, Optional, Length, NumberRange

from app.models.server import ServerStatus, ComponentType
from app.models.configuration import RuleType, PricingMethod
from app.hardware.registry import HARDWARE_REGISTRY

HARDWARE_LABELS = {slug: entry["label"] for slug, entry in HARDWARE_REGISTRY.items()}

STORAGE_TYPE_CHOICES = [
    ("nvme", "NVMe"),
    ("sata_ssd", "SATA SSD"),
    ("hdd", "HDD"),
    ("mixed", "Mixed"),
]

STATUS_CHOICES = [(ServerStatus.DRAFT.value, "Draft"), (ServerStatus.PUBLISHED.value, "Published")]


class ServerForm(FlaskForm):
    category_id = SelectField("Category", coerce=int, validators=[Optional()])
    title = StringField("Title", validators=[DataRequired(), Length(max=255)])
    description = TextAreaField("Description", validators=[Optional()])

    manufacturer = StringField("Manufacturer", validators=[Optional(), Length(max=100)])
    model = StringField("Model", validators=[Optional(), Length(max=100)])
    sku = StringField("SKU", validators=[Optional(), Length(max=100)])
    serial_number = StringField("Serial number", validators=[Optional(), Length(max=100)])
    asset_number = StringField("Asset number", validators=[Optional(), Length(max=100)])

    cpu_summary = StringField("CPU", validators=[DataRequired(), Length(max=255)])
    cpu_count = IntegerField("CPU count", default=1, validators=[Optional(), NumberRange(min=1)])
    cpu_cores = IntegerField("Total cores", validators=[Optional()])
    cpu_threads = IntegerField("Total threads", validators=[Optional()])

    ram_summary = StringField("RAM", validators=[DataRequired(), Length(max=255)])
    ram_capacity_gb = IntegerField("RAM capacity (GB)", validators=[Optional()])
    ram_slots = IntegerField("RAM slots", validators=[Optional()])

    storage_summary = StringField("Storage", validators=[DataRequired(), Length(max=255)])
    storage_type = SelectField("Storage type", choices=STORAGE_TYPE_CHOICES, validators=[Optional()])
    storage_capacity_gb = IntegerField("Storage capacity (GB)", validators=[Optional()])
    drive_count = IntegerField("Drive count", validators=[Optional()])

    gpu_summary = StringField("GPU", validators=[Optional(), Length(max=255)])
    gpu_count = IntegerField("GPU count", default=0, validators=[Optional()])

    network_summary = StringField("Network", validators=[DataRequired(), Length(max=255)])
    network_ports = IntegerField("Network ports", validators=[Optional()])
    bandwidth_mbps = IntegerField("Bandwidth (Mbps)", validators=[Optional()])
    ip_addresses_included = IntegerField("IP addresses included", default=1, validators=[Optional()])

    raid_summary = StringField("RAID", validators=[Optional(), Length(max=255)])

    psu_count = IntegerField("PSU count", validators=[Optional()])
    psu_wattage = IntegerField("PSU wattage", validators=[Optional()])

    chassis_summary = StringField("Chassis", validators=[Optional(), Length(max=255)])
    rack_units = DecimalField("Rack units", validators=[Optional()], places=1)
    operating_system = StringField("Operating system", validators=[Optional(), Length(max=100)])

    monthly_price = DecimalField("Monthly price", validators=[DataRequired()], places=2)
    one_time_price = DecimalField("One-time price", validators=[Optional()], places=2)
    setup_fee = DecimalField("Setup fee", validators=[Optional()], places=2)

    status = SelectField("Status", choices=STATUS_CHOICES, default=ServerStatus.DRAFT.value)

    country = StringField("Country code", validators=[Optional(), Length(max=2)])
    region = StringField("Region", validators=[Optional(), Length(max=100)])
    city = StringField("City", validators=[Optional(), Length(max=100)])
    datacenter_name = StringField("Datacenter", validators=[Optional(), Length(max=150)])
    datacenter_code = StringField("Datacenter code", validators=[Optional(), Length(max=20)])


ADMIN_STATUS_CHOICES = STATUS_CHOICES + [(ServerStatus.DISABLED.value, "Disabled")]


class AdminServerForm(ServerForm):
    """Same fields as the seller-facing ServerForm, plus seller assignment
    and the ability to disable a listing directly (sellers can only choose
    draft/published; admins can also disable)."""

    seller_id = SelectField("Seller", coerce=int, validators=[Optional()])
    status = SelectField("Status", choices=ADMIN_STATUS_CHOICES, default=ServerStatus.DRAFT.value)


class ServerComponentForm(FlaskForm):
    component_type = SelectField("Component type", validators=[DataRequired()])
    hardware_id = SelectField("Hardware item", coerce=int, validators=[DataRequired()])
    quantity = IntegerField("Quantity", default=1, validators=[DataRequired(), NumberRange(min=1)])
    label_override = StringField("Label override", validators=[Optional(), Length(max=255)])


class CompatibilityRuleForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(max=150)])
    description = TextAreaField("Description", validators=[Optional()])
    rule_type = SelectField(
        "Rule type",
        choices=[(r.value, r.name.replace("_", " ").title()) for r in RuleType],
        validators=[DataRequired()],
    )
    is_active = BooleanField("Active", default=True)


class PricingRuleForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(max=150)])
    component_type = SelectField(
        "Component type (blank = applies to all)",
        choices=[("", "— All components —")] + [(ct.value, HARDWARE_LABELS.get(ct.value, ct.value)) for ct in ComponentType],
        validators=[Optional()],
    )
    method = SelectField(
        "Method",
        choices=[(m.value, m.name.replace("_", " ").title()) for m in PricingMethod],
        validators=[DataRequired()],
    )
    value = DecimalField("Value (% or amount)", default=0, validators=[Optional()])
    is_active = BooleanField("Active", default=True)


class CategoryForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(max=100)])
    description = TextAreaField("Description", validators=[Optional()])
    sort_order = IntegerField("Sort order", default=0, validators=[Optional()])


class ServerImageForm(FlaskForm):
    image = FileField(
        "Image",
        validators=[FileRequired(), FileAllowed(["png", "jpg", "jpeg", "gif", "webp"], "Images only.")],
    )
    alt_text = StringField("Alt text", validators=[Optional(), Length(max=255)])
