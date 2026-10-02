from flask_wtf import FlaskForm
from wtforms import StringField, SelectField, BooleanField, IntegerField, PasswordField, SubmitField, TextAreaField
from wtforms.validators import DataRequired, Optional as OptionalValidator, NumberRange

from app.path_utils import clean_path


class AgentExportForm(FlaskForm):
    include_files = BooleanField("Include files (config, uploads, etc.)", default=True)

    install_path = StringField(
        "SnailyCAD install path (on the machine that will run the agent)",
        filters=[clean_path],
        description="The FOLDER SnailyCAD is installed in (e.g. D:\\SnailyCAD) — not a specific file inside "
                     "it. Required if including files. Even for a database-only export, filling this in lets "
                     "the database name/host/user be auto-detected from its .env — leave it blank only if you'd "
                     "rather type the database details in by hand below.",
    )

    db_type = SelectField(
        "Database type",
        choices=[("", "No database (files only)"), ("postgres", "PostgreSQL"), ("sqlite", "SQLite")],
    )
    db_host = StringField("DB host", default="localhost", validators=[OptionalValidator()])
    db_port = IntegerField("DB port", default=5432, validators=[OptionalValidator(), NumberRange(min=1, max=65535)])
    db_name = StringField("DB name", validators=[OptionalValidator()],
                           description="Leave blank to auto-detect from the install's .env (needs install path set).")
    db_user = StringField("DB user", validators=[OptionalValidator()])
    db_password = PasswordField("DB password", validators=[OptionalValidator()])
    sqlite_path = StringField("SQLite file path", validators=[OptionalValidator()], filters=[clean_path])

    include_uploads = BooleanField("Include uploaded assets", default=True)
    extra_paths = TextAreaField(
        "Extra files/folders to include (one per line, relative to install path)",
        validators=[OptionalValidator()],
    )

    submit = SubmitField("Generate agent token")

    def validate_install_path(self, field):
        if self.include_files.data and not field.data:
            from wtforms import ValidationError
            raise ValidationError(
                "Required when \"Include files\" is checked. "
                "Uncheck it above for a database-only export."
            )

    def validate_db_type(self, field):
        if not self.include_files.data and not field.data:
            from wtforms import ValidationError
            raise ValidationError(
                "Select a database type, or check \"Include files\" above — "
                "the job needs to do at least one of the two."
            )

    def get_db_config(self):
        if self.db_type.data == "postgres":
            return {
                "type": "postgres", "host": self.db_host.data or "localhost",
                "port": self.db_port.data or 5432, "name": self.db_name.data,
                "user": self.db_user.data or "postgres", "password": self.db_password.data or "",
            }
        if self.db_type.data == "sqlite":
            return {"type": "sqlite", "path": self.sqlite_path.data}
        return {}

    def get_extra_paths(self):
        if not self.extra_paths.data:
            return []
        return [line.strip() for line in self.extra_paths.data.splitlines() if line.strip()]


class AgentImportForm(FlaskForm):
    source_export_id = SelectField("Export to restore", validators=[DataRequired()])

    restore_files = BooleanField("Restore files (config, uploads, etc.)", default=True)

    target_path = StringField(
        "Target SnailyCAD install path (on the machine that will run the agent)",
        filters=[clean_path],
        description="Required if restoring files. For a database-only restore, filling this in still lets the "
                     "database name/host/user be auto-detected if there's already a SnailyCAD .env there — leave "
                     "it blank only if you'd rather type the database details in by hand below.",
    )

    db_type = SelectField(
        "Restore database as",
        choices=[("", "Don't restore database"), ("postgres", "PostgreSQL"), ("sqlite", "SQLite")],
    )
    db_host = StringField("DB host", default="localhost", validators=[OptionalValidator()])
    db_port = IntegerField("DB port", default=5432, validators=[OptionalValidator(), NumberRange(min=1, max=65535)])
    db_name = StringField("DB name", validators=[OptionalValidator()],
                           description="Leave blank to auto-detect from the install's .env (needs install path set).")
    db_user = StringField("DB user", validators=[OptionalValidator()])
    db_password = PasswordField("DB password", validators=[OptionalValidator()])
    sqlite_target_path = StringField("Target SQLite file path", validators=[OptionalValidator()], filters=[clean_path])

    submit = SubmitField("Generate agent token")

    def validate_target_path(self, field):
        if self.restore_files.data and not field.data:
            from wtforms import ValidationError
            raise ValidationError(
                "Required when \"Restore files\" is checked. "
                "Uncheck it above for a database-only restore."
            )

    def validate_db_type(self, field):
        if not self.restore_files.data and not field.data:
            from wtforms import ValidationError
            raise ValidationError(
                "Select a database type, or check \"Restore files\" above — "
                "the job needs to do at least one of the two."
            )

    def get_db_target(self):
        if self.db_type.data == "postgres":
            return {
                "type": "postgres", "host": self.db_host.data or "localhost",
                "port": self.db_port.data or 5432, "name": self.db_name.data,
                "user": self.db_user.data or "postgres", "password": self.db_password.data or "",
            }
        if self.db_type.data == "sqlite":
            return {"type": "sqlite", "path": self.sqlite_target_path.data}
        return {}


class RequestAssistForm(FlaskForm):
    kind = SelectField(
        "What do you need help with?",
        choices=[("export", "Exporting my data"), ("import", "Restoring an export")],
    )
    source_export_id = SelectField(
        "Export to restore (only needed if restoring)",
        validators=[OptionalValidator()],
    )
    note = TextAreaField(
        "Anything the admin should know? (optional)",
        validators=[OptionalValidator()],
        description="E.g. what machine this is, what's not working, anything unusual about the setup.",
    )
    submit = SubmitField("Grant 12-hour access")
