from flask_wtf import FlaskForm
from wtforms import SelectField, IntegerField, StringField, SubmitField
from wtforms.validators import DataRequired, Optional as OptionalValidator, NumberRange, Length


class CreateShareLinkForm(FlaskForm):
    duration = SelectField(
        "Link valid for",
        choices=[
            ("0.5", "30 minutes"),
            ("1", "1 hour"),
            ("12", "12 hours"),
            ("custom", "Custom"),
        ],
        default="1",
    )
    custom_hours = IntegerField(
        "Custom duration (hours)",
        description="Up to 168 hours (7 days) activates immediately. Longer needs admin approval.",
    )
    submit = SubmitField("Create share link")

    def validate_custom_hours(self, field):
        if self.duration.data != "custom":
            return
        from wtforms import ValidationError
        if not field.data:
            raise ValidationError("Enter how many hours the link should stay active.")
        if field.data < 1 or field.data > 8760:
            raise ValidationError("Enter a number of hours between 1 and 8760 (1 year).")

    def get_hours(self):
        if self.duration.data == "custom":
            return float(self.custom_hours.data or 0)
        return float(self.duration.data)


class PinEntryForm(FlaskForm):
    pin = StringField("PIN", validators=[DataRequired(), Length(min=4, max=10)])
    submit = SubmitField("Access file")
