from flask_wtf import FlaskForm
from wtforms import StringField, SelectField, BooleanField, IntegerField, PasswordField, SubmitField, TextAreaField
from wtforms.validators import DataRequired, Optional as OptionalValidator, NumberRange


class NewExportForm(FlaskForm):
    connection_type = SelectField(
        "Source",
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

    install_path = StringField(
        "SnailyCAD install path",
        validators=[DataRequired()],
        description="Absolute path to the SnailyCAD root directory — on this server, or on the remote host if using SSH.",
    )

    db_type = SelectField(
        "Database type",
        choices=[("", "No database (files only)"), ("postgres", "PostgreSQL"), ("sqlite", "SQLite")],
        validators=[OptionalValidator()],
    )

    db_host = StringField("DB host", default="localhost", validators=[OptionalValidator()])
    db_port = IntegerField("DB port", default=5432, validators=[OptionalValidator(), NumberRange(min=1, max=65535)])
    db_name = StringField("DB name", validators=[OptionalValidator()])
    db_user = StringField("DB user", validators=[OptionalValidator()])
    db_password = PasswordField("DB password", validators=[OptionalValidator()])
    sqlite_path = StringField(
        "SQLite file path", validators=[OptionalValidator()],
        description="Path on the source (local or SSH remote) machine.",
    )

    include_uploads = BooleanField("Include uploaded assets", default=True)

    extra_paths = TextAreaField(
        "Extra files/folders to include (one per line, relative to install path)",
        validators=[OptionalValidator()],
    )

    submit = SubmitField("Start Export")

    def get_db_config(self):
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
            return {"type": "sqlite", "path": self.sqlite_path.data}
        return {}

    def get_extra_paths(self):
        if not self.extra_paths.data:
            return []
        return [line.strip() for line in self.extra_paths.data.splitlines() if line.strip()]

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
