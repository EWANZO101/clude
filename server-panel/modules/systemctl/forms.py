from flask_wtf import FlaskForm
from wtforms import StringField, SelectField
from wtforms.validators import DataRequired, Length, Regexp

from services.file_browser_service import RUNTIME_LABELS


class CreateServiceForm(FlaskForm):
    app_name = StringField(
        "Application Name",
        validators=[DataRequired(), Length(max=64), Regexp(r"^[a-zA-Z0-9_.@-]+$",
            message="Letters, numbers, dots, dashes, and underscores only.")],
    )
    working_dir = StringField("Working Directory (Path)", validators=[DataRequired(), Length(max=255)])
    runtime = SelectField("Runtime", choices=list(RUNTIME_LABELS.items()), default="python")
    port = StringField("Port", validators=[Length(max=10)])
    exec_start = StringField("Start Command", validators=[DataRequired(), Length(max=255)])
    run_user = StringField("User", validators=[DataRequired(), Length(max=64)], default="root")
    description = StringField("Description", validators=[Length(max=255)])
