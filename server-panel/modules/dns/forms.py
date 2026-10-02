from flask_wtf import FlaskForm
from wtforms import StringField, SelectField, IntegerField, BooleanField
from wtforms.validators import DataRequired, Length, Optional, NumberRange, IPAddress

from services.cloudflare_service import RECORD_TYPES


class TokenForm(FlaskForm):
    token = StringField("Cloudflare API Token", validators=[DataRequired(), Length(max=200)])


class NamecheapCredentialsForm(FlaskForm):
    api_user = StringField("API User", validators=[DataRequired(), Length(max=100)])
    api_key = StringField("API Key", validators=[DataRequired(), Length(max=200)])
    username = StringField("Account Username (usually same as API User)", validators=[Optional(), Length(max=100)])
    client_ip = StringField(
        "Whitelisted Client IP",
        validators=[DataRequired(), IPAddress(message="Enter a valid IPv4 address.")],
    )


class GoDaddyCredentialsForm(FlaskForm):
    token = StringField("GoDaddy API Token", validators=[DataRequired(), Length(max=200)])
    domain = StringField("Domain", validators=[DataRequired(), Length(max=255)])


class DnsRecordForm(FlaskForm):
    # Default choices are Cloudflare's; routes.py overrides form.type.choices
    # with the active provider's record_types before validate_on_submit()
    # so the form always validates against whichever provider is active.
    type = SelectField("Type", choices=[(t, t) for t in RECORD_TYPES], validators=[DataRequired()])
    name = StringField("Name", validators=[DataRequired(), Length(max=255)])
    content = StringField("Content", validators=[DataRequired(), Length(max=500)])
    ttl = IntegerField("TTL (seconds, 1 = Auto)", default=1, validators=[Optional(), NumberRange(min=1, max=86400)])
    proxied = BooleanField("Proxied (orange cloud)")
    priority = IntegerField("Priority (MX only)", validators=[Optional(), NumberRange(min=0, max=65535)])

