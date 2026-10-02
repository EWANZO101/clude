from flask_wtf import FlaskForm
from wtforms import StringField, SelectField, IntegerField, BooleanField
from wtforms.validators import DataRequired, Optional, Length, URL, NumberRange

from app.integrations.adapters import PROVIDER_ADAPTERS

PROVIDER_CHOICES = [(key, key.replace("_", " ").title()) for key in PROVIDER_ADAPTERS]


class HardwareApiConnectionForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(max=150)])
    provider_type = SelectField("Provider type", choices=PROVIDER_CHOICES, default="generic_rest")
    base_url = StringField("Base URL", validators=[DataRequired(), URL(), Length(max=500)])
    api_key = StringField("API key", validators=[Optional(), Length(max=255)])
    sync_frequency_hours = IntegerField("Sync frequency (hours)", default=24, validators=[DataRequired(), NumberRange(min=1)])
    is_active = BooleanField("Active", default=True)


class SellerApiConnectionForm(FlaskForm):
    seller_id = SelectField("Seller", coerce=int, validators=[DataRequired()])
    name = StringField("Name", validators=[DataRequired(), Length(max=150)])
    provider_type = SelectField("Provider type", choices=PROVIDER_CHOICES, default="generic_rest")
    base_url = StringField("Base URL", validators=[DataRequired(), URL(), Length(max=500)])
    api_key = StringField("API key", validators=[Optional(), Length(max=255)])
    is_active = BooleanField("Active", default=True)
