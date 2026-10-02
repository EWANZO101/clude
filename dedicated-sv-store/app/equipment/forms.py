from flask_wtf import FlaskForm
from flask_wtf.file import FileField, FileRequired, FileAllowed
from wtforms import StringField, IntegerField, DecimalField, TextAreaField, SelectField, BooleanField
from wtforms.validators import DataRequired, Optional, Length

from app.models.equipment import AttachmentType


class EquipmentItemForm(FlaskForm):
    equipment_type_id = SelectField("Equipment type", coerce=int, validators=[DataRequired()])
    manufacturer = StringField("Manufacturer", validators=[Optional(), Length(max=100)])
    model = StringField("Model", validators=[Optional(), Length(max=100)])
    serial_number = StringField("Serial number", validators=[Optional(), Length(max=100)])
    asset_number = StringField("Asset number", validators=[Optional(), Length(max=100)])
    quantity = IntegerField("Quantity", default=1, validators=[DataRequired()])

    cpu_summary = StringField("CPU", validators=[Optional(), Length(max=255)])
    ram_summary = StringField("RAM", validators=[Optional(), Length(max=255)])
    storage_summary = StringField("Storage", validators=[Optional(), Length(max=255)])
    gpu_summary = StringField("GPU", validators=[Optional(), Length(max=255)])
    raid_summary = StringField("RAID", validators=[Optional(), Length(max=255)])
    psu_summary = StringField("PSU", validators=[Optional(), Length(max=255)])
    chassis_summary = StringField("Chassis", validators=[Optional(), Length(max=255)])

    port_count = IntegerField("Port count", validators=[Optional()])
    port_types = StringField("Port types", validators=[Optional(), Length(max=255)])
    port_speeds = StringField("Port speeds", validators=[Optional(), Length(max=255)])
    mac_address = StringField("MAC address", validators=[Optional(), Length(max=50)])
    firmware_version = StringField("Firmware version", validators=[Optional(), Length(max=50)])

    network_summary = StringField("Network", validators=[Optional(), Length(max=255)])
    rack_mount = BooleanField("Rack mounted", default=True)
    u_height = DecimalField("U height", validators=[Optional()], places=1)
    dimensions = StringField("Dimensions", validators=[Optional(), Length(max=100)])
    weight_kg = DecimalField("Weight (kg)", validators=[Optional()], places=2)
    power_requirements = StringField("Power requirements", validators=[Optional(), Length(max=100)])

    declared_value = DecimalField("Declared value", validators=[Optional()], places=2)
    replacement_value = DecimalField("Replacement value", validators=[Optional()], places=2)
    insurance_value = DecimalField("Insurance value", validators=[Optional()], places=2)

    notes = TextAreaField("Notes", validators=[Optional()])


class EquipmentAttachmentForm(FlaskForm):
    file = FileField(
        "File",
        validators=[FileRequired(), FileAllowed(
            ["png", "jpg", "jpeg", "gif", "webp", "pdf", "doc", "docx", "xls", "xlsx", "csv", "txt"],
            "Unsupported file type.",
        )],
    )
    attachment_type = SelectField(
        "Type", choices=[(t.value, t.name.replace("_", " ").title()) for t in AttachmentType],
        validators=[DataRequired()],
    )


class ChangeRequestForm(FlaskForm):
    message = TextAreaField("What would you like to change?", validators=[DataRequired()])


class EquipmentTypeForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(max=100)])
    is_networking = BooleanField("Networking equipment")
    is_active = BooleanField("Active", default=True)
