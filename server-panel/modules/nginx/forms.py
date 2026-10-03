from flask_wtf import FlaskForm
from wtforms import StringField, TextAreaField, BooleanField
from wtforms.validators import DataRequired, Length, Email, Optional


class CreateSiteForm(FlaskForm):
    domain = StringField("Domain", validators=[DataRequired(), Length(max=255)])
    port = StringField("Application Port", validators=[DataRequired(), Length(max=6)])
    extra_directives = TextAreaField("Extra Directives (optional)", validators=[Optional(), Length(max=2000)])


class IssueCertForm(FlaskForm):
    domain = StringField("Domain", validators=[DataRequired(), Length(max=255)])
    email = StringField("Email", validators=[DataRequired(), Email()])
    force_https = BooleanField("Force HTTPS redirect", default=True)
