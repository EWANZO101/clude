from flask_wtf import FlaskForm
from flask_wtf.file import FileField, FileAllowed, MultipleFileField
from wtforms import (
    StringField, IntegerField, DecimalField, DateField, TextAreaField,
    SelectField, BooleanField
)
from wtforms.validators import DataRequired, Optional, Length

ALLOWED_IMAGES = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
ALLOWED_DOCS = ["pdf", "doc", "docx", "jpg", "jpeg", "png", "webp"]


class MotorcycleForm(FlaskForm):
    registration = StringField("Registration number", validators=[Optional(), Length(max=20)])
    make = StringField("Make", validators=[Optional(), Length(max=80)])
    model = StringField("Model", validators=[Optional(), Length(max=80)])
    year = IntegerField("Year", validators=[Optional()])
    engine_info = StringField("Engine information", validators=[Optional(), Length(max=255)])
    vin = StringField("VIN / chassis number", validators=[Optional(), Length(max=64)])
    mileage = IntegerField("Current mileage", validators=[Optional()])
    colour = StringField("Colour", validators=[Optional(), Length(max=60)])
    purchase_date = DateField("Purchase date", validators=[Optional()])
    purchase_price = DecimalField("Purchase price (£)", validators=[Optional()], places=2)
    previous_owners = TextAreaField("Previous owners", validators=[Optional()])
    notes = TextAreaField("General notes", validators=[Optional()])
    photos = MultipleFileField("Photos", validators=[Optional(), FileAllowed(ALLOWED_IMAGES, "Images only")])


class ServiceRecordForm(FlaskForm):
    date = DateField("Date", validators=[DataRequired()])
    mileage = IntegerField("Mileage", validators=[Optional()])
    work_type = StringField("Type of work", validators=[Optional(), Length(max=120)])
    description = TextAreaField("Description of work completed", validators=[Optional()])
    garage = StringField("Garage / mechanic", validators=[Optional(), Length(max=160)])
    parts_used = TextAreaField("Parts used", validators=[Optional()])
    labour_cost = DecimalField("Labour cost (£)", validators=[Optional()], places=2)
    parts_cost = DecimalField("Parts cost (£)", validators=[Optional()], places=2)
    total_cost = DecimalField("Total cost (£)", validators=[Optional()], places=2)
    notes = TextAreaField("Notes", validators=[Optional()])
    documents = MultipleFileField("Photos / receipts / invoices", validators=[Optional(), FileAllowed(ALLOWED_DOCS, "Images or documents only")])


class ModificationForm(FlaskForm):
    name = StringField("Modification / upgrade name", validators=[DataRequired(), Length(max=160)])
    description = TextAreaField("Description", validators=[Optional()])
    date_fitted = DateField("Date fitted", validators=[Optional()])
    mileage_fitted = IntegerField("Mileage when fitted", validators=[Optional()])
    manufacturer = StringField("Manufacturer", validators=[Optional(), Length(max=120)])
    part_number = StringField("Part number", validators=[Optional(), Length(max=120)])
    cost = DecimalField("Cost (£)", validators=[Optional()], places=2)
    installation_cost = DecimalField("Installation cost (£)", validators=[Optional()], places=2)
    fitted_by = StringField("Who fitted it", validators=[Optional(), Length(max=160)])
    notes = TextAreaField("Notes", validators=[Optional()])
    documents = MultipleFileField("Photos / receipts", validators=[Optional(), FileAllowed(ALLOWED_DOCS, "Images or documents only")])


class PartNotFittedForm(FlaskForm):
    part_name = StringField("Part name", validators=[DataRequired(), Length(max=160)])
    manufacturer = StringField("Manufacturer", validators=[Optional(), Length(max=120)])
    part_number = StringField("Part number", validators=[Optional(), Length(max=120)])
    purchase_date = DateField("Purchase date", validators=[Optional()])
    purchase_price = DecimalField("Purchase price (£)", validators=[Optional()], places=2)
    supplier = StringField("Supplier", validators=[Optional(), Length(max=160)])
    quantity = IntegerField("Quantity", default=1, validators=[Optional()])
    notes = TextAreaField("Notes", validators=[Optional()])
    documents = MultipleFileField("Photos / receipts", validators=[Optional(), FileAllowed(ALLOWED_DOCS, "Images or documents only")])


class FitPartForm(FlaskForm):
    date_fitted = DateField("Date fitted", validators=[Optional()])
    mileage_fitted = IntegerField("Mileage when fitted", validators=[Optional()])
    installation_cost = DecimalField("Installation cost (£)", validators=[Optional()], places=2)
    fitted_by = StringField("Who fitted it", validators=[Optional(), Length(max=160)])


class AccidentForm(FlaskForm):
    date = DateField("Accident date", validators=[DataRequired()])
    mileage = IntegerField("Mileage", validators=[Optional()])
    description = TextAreaField("Description of what happened", validators=[Optional()])
    damage_caused = TextAreaField("Damage caused", validators=[Optional()])
    repairs_carried_out = TextAreaField("Repairs carried out", validators=[Optional()])
    repair_cost = DecimalField("Repair costs (£)", validators=[Optional()], places=2)
    insurance_info = TextAreaField("Insurance information", validators=[Optional()])
    notes = TextAreaField("Notes", validators=[Optional()])
    documents = MultipleFileField("Photos (before/after) / documents", validators=[Optional(), FileAllowed(ALLOWED_DOCS, "Images or documents only")])


class MOTLookupForm(FlaskForm):
    registration = StringField("Registration number", validators=[DataRequired(), Length(max=20)])


class ManualMOTForm(FlaskForm):
    test_date = DateField("Test date", validators=[DataRequired()])
    expiry_date = DateField("Expiry date", validators=[Optional()])
    result = SelectField("Result", choices=[("PASSED", "Passed"), ("FAILED", "Failed")])
    mileage = IntegerField("Mileage recorded", validators=[Optional()])
    advisories = TextAreaField("Advisories", validators=[Optional()])
    failures = TextAreaField("Failures / reasons for failure", validators=[Optional()])


class ShareSettingsForm(FlaskForm):
    share_enabled = BooleanField("Enable public share link")
    share_show_service = BooleanField("Service & maintenance history", default=True)
    share_show_mods = BooleanField("Modifications & upgrades", default=True)
    share_show_parts = BooleanField("Parts purchased / in stock")
    share_show_accidents = BooleanField("Accident history")
    share_show_mot = BooleanField("MOT history", default=True)
    share_show_purchase_info = BooleanField("Purchase date & price")
    share_show_documents = BooleanField("Public documents & receipts")
