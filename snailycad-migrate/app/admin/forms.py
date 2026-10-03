from flask_wtf import FlaskForm
from wtforms import SelectField, BooleanField, SubmitField, IntegerField, StringField
from wtforms.validators import Optional as OptionalValidator, NumberRange


class EditUserForm(FlaskForm):
    role = SelectField("Role", choices=[("user", "User"), ("support", "Support"), ("admin", "Admin")])
    is_suspended = BooleanField("Suspended")
    submit = SubmitField("Save changes")


class SystemSettingsForm(FlaskForm):
    export_retention_days = IntegerField(
        "Export retention (days)", validators=[OptionalValidator(), NumberRange(min=1, max=365)]
    )
    temp_account_lifetime_hours = IntegerField(
        "Temporary account lifetime (hours)", validators=[OptionalValidator(), NumberRange(min=1, max=168)]
    )
    cleanup_enabled = BooleanField("Enable automatic cleanup jobs")
    mail_server = StringField("Mail server", validators=[OptionalValidator()])
    mail_from = StringField("Mail from address", validators=[OptionalValidator()])
    submit = SubmitField("Save settings")
