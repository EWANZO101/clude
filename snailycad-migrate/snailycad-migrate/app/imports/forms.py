from flask_wtf import FlaskForm
from flask_wtf.file import FileField, FileRequired, FileAllowed
from wtforms import StringField, SelectField, IntegerField, PasswordField, SubmitField
from wtforms.validators import DataRequired, Optional as OptionalValidator, NumberRange

from app.path_utils import clean_path


class NewImportForm(FlaskForm):
    package_file = FileField(
        "Export package (.zip)",
        validators=[FileRequired(), FileAllowed(["zip"], "Only .zip export packages are accepted.")],
    )

    connection_type = SelectField(
        "Target",
        choices=[("local", "Local (this server)"), ("ssh", "Remote over SSH")],
        default="local",
    )

    ssh_host = StringField("SSH host", validators=[OptionalValidator()])
    ssh_port = IntegerField("SSH port", default=22, validators=[OptionalValidator(), NumberRange(min=1, max=65535)])
    ssh_username = StringField("SSH username", validators=[OptionalValidator()])
    ssh_password = PasswordField(
        "SSH password",
        validators=[OptionalValidator()],
        description="Password auth only — no SSH key required or used.",
    )
    remote_os = SelectField(
        "Remote OS",
        choices=[("linux", "Linux"), ("windows", "Windows")],
        default="linux",
        description="Windows targets need OpenSSH Server enabled (built into Windows 10/11 and Server).",
    )

    target_path = StringField(
        "Target SnailyCAD install path",
        validators=[DataRequired()],
        description="Where to restore files — on this server, or on the remote host if using SSH. Created if it doesn't exist.",
        filters=[clean_path],
    )

    db_type = SelectField(
        "Restore database as",
        choices=[("", "Don't restore database"), ("postgres", "PostgreSQL"), ("sqlite", "SQLite")],
        validators=[OptionalValidator()],
    )
    db_host = StringField("DB host", default="localhost", validators=[OptionalValidator()])
    db_port = IntegerField("DB port", default=5432, validators=[OptionalValidator(), NumberRange(min=1, max=65535)])
    db_name = StringField("DB name", validators=[OptionalValidator()])
    db_user = StringField("DB user", validators=[OptionalValidator()])
    db_password = PasswordField("DB password", validators=[OptionalValidator()])
    sqlite_target_path = StringField(
        "Target SQLite file path", validators=[OptionalValidator()],
        description="Path on the target (local or SSH remote) machine.",
        filters=[clean_path],
    )

    submit = SubmitField("Start Import")

    def get_db_target(self):
        if self.db_type.data == "postgres":
            return {
                "type": "postgres",
                "host": self.db_host.data or "localhost",
                "port": self.db_port.data or 5432,
                "name": self.db_name.data,
                "user": self.db_user.data or "postgres",
                "password": self.db_password.data or "",
            }
        if self.db_type.data == "sqlite":
            return {"type": "sqlite", "path": self.sqlite_target_path.data}
        return {}

    def get_transport_config(self):
        if self.connection_type.data == "ssh":
            return {
                "host": self.ssh_host.data,
                "port": self.ssh_port.data or 22,
                "username": self.ssh_username.data,
                "password": self.ssh_password.data or "",
                "remote_os": self.remote_os.data,
            }
        return {}
