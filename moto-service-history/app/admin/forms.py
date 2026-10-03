from flask_wtf import FlaskForm
from wtforms import StringField, PasswordField, BooleanField
from wtforms.validators import DataRequired, Optional, Length


class AdminCreateUserForm(FlaskForm):
    username = StringField("Username", validators=[DataRequired(), Length(3, 64)])
    password = PasswordField("Temporary password", validators=[DataRequired(), Length(8, 128)])
    is_admin = BooleanField("Grant admin access")


class AdminResetPasswordForm(FlaskForm):
    new_password = PasswordField("New password", validators=[DataRequired(), Length(8, 128)])


class MOTSettingsForm(FlaskForm):
    dvsa_api_key = StringField("DVSA API key", validators=[Optional()])
    dvsa_client_id = StringField("DVSA client ID", validators=[Optional()])
    dvsa_client_secret = StringField("DVSA client secret", validators=[Optional()])
    dvsa_token_url = StringField("OAuth token URL", validators=[Optional()])
    dvsa_scope_url = StringField("OAuth scope URL", validators=[Optional()])
    dvsa_api_base = StringField(
        "API base URL",
        validators=[Optional()],
        default="https://history.mot.api.gov.uk/v1/trade/vehicles/registration",
    )


class AppSettingsForm(FlaskForm):
    site_name = StringField("Site name", validators=[Optional(), Length(max=120)])
    support_email = StringField("Support contact email", validators=[Optional(), Length(max=160)])
