from flask_wtf import FlaskForm
from wtforms import StringField, DecimalField, SelectField, TextAreaField, BooleanField
from wtforms.validators import DataRequired, Optional, Length

from app.models.shipping import ShipmentStatus, InspectionResult


class ShipmentForm(FlaskForm):
    carrier = StringField("Carrier", validators=[DataRequired(), Length(max=100)])
    tracking_number = StringField("Tracking number", validators=[Optional(), Length(max=150)])
    destination_name = StringField("Destination", validators=[Optional(), Length(max=150)])
    destination_address = StringField("Destination address", validators=[Optional(), Length(max=500)])
    weight_kg = DecimalField("Weight (kg)", validators=[Optional()], places=2)
    dimensions = StringField("Dimensions", validators=[Optional(), Length(max=100)])
    declared_value = DecimalField("Declared value", validators=[Optional()], places=2)
    insurance_value = DecimalField("Insurance value", validators=[Optional()], places=2)


class ShipmentEventForm(FlaskForm):
    status = SelectField("Status", choices=[(s.value, s.name.replace("_", " ").title()) for s in ShipmentStatus], validators=[DataRequired()])
    description = StringField("Description", validators=[Optional(), Length(max=255)])
    location = StringField("Location", validators=[Optional(), Length(max=150)])


class ReceivingRecordForm(FlaskForm):
    condition = SelectField(
        "Condition", choices=[("good", "Good"), ("fair", "Fair"), ("damaged", "Damaged")], validators=[DataRequired()]
    )
    packaging_condition = SelectField(
        "Packaging condition", choices=[("good", "Good"), ("fair", "Fair"), ("damaged", "Damaged")], validators=[DataRequired()]
    )
    accessories_included = StringField("Accessories included", validators=[Optional(), Length(max=255)])
    damage_noted = BooleanField("Damage noted")
    notes = TextAreaField("Notes", validators=[Optional()])


class InspectionRecordForm(FlaskForm):
    result = SelectField(
        "Result", choices=[(r.value, r.name.replace("_", " ").title()) for r in InspectionResult],
        validators=[DataRequired()],
    )
    notes = TextAreaField("Notes", validators=[Optional()])
