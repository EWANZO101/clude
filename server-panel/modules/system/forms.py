from flask_wtf import FlaskForm
from wtforms import StringField, PasswordField, BooleanField, SelectField, TextAreaField
from wtforms.validators import DataRequired, Length, EqualTo, Regexp, Optional


class RootPasswordForm(FlaskForm):
    password = PasswordField("New root password", validators=[DataRequired(), Length(min=8)])
    confirm_password = PasswordField(
        "Confirm password",
        validators=[DataRequired(), EqualTo("password", message="Passwords must match")],
    )


class CreateSystemUserForm(FlaskForm):
    username = StringField(
        "Username",
        validators=[DataRequired(), Length(max=32), Regexp(r"^[a-z_][a-z0-9_-]*$", message="Lowercase letters, numbers, - or _ only, starting with a letter or _")],
    )
    password = PasswordField("Password", validators=[DataRequired(), Length(min=8)])
    shell = SelectField("Shell", choices=[
        ("/bin/bash", "/bin/bash"),
        ("/bin/sh", "/bin/sh"),
        ("/usr/sbin/nologin", "/usr/sbin/nologin (no shell login)"),
    ])
    sudo = BooleanField("Grant sudo access")
    ssh_public_key = TextAreaField("SSH public key (optional)", validators=[Optional(), Length(max=4000)])


class ResetUserPasswordForm(FlaskForm):
    password = PasswordField("New password", validators=[DataRequired(), Length(min=8)])
