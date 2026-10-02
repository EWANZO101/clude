from flask_wtf import FlaskForm
from wtforms import StringField, BooleanField
from wtforms.validators import DataRequired, Optional, Length


class AccountSettingsForm(FlaskForm):
    first_name = StringField("First name", validators=[DataRequired(), Length(max=100)])
    last_name = StringField("Last name", validators=[DataRequired(), Length(max=100)])
    phone = StringField("Phone", validators=[Optional(), Length(max=30)])

    company_name = StringField("Company name", validators=[Optional(), Length(max=255)])
    vat_number = StringField("VAT number", validators=[Optional(), Length(max=50)])

    billing_address_line1 = StringField("Address line 1", validators=[Optional(), Length(max=255)])
    billing_address_line2 = StringField("Address line 2", validators=[Optional(), Length(max=255)])
    billing_city = StringField("City", validators=[Optional(), Length(max=100)])
    billing_region = StringField("Region", validators=[Optional(), Length(max=100)])
    billing_postal_code = StringField("Postal code", validators=[Optional(), Length(max=20)])
    billing_country = StringField("Country code", validators=[Optional(), Length(max=2)])

    marketing_opt_in = BooleanField("Send me product updates and offers")
