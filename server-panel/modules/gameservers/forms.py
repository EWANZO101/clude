from flask_wtf import FlaskForm
from wtforms import StringField, IntegerField, PasswordField
from wtforms.validators import DataRequired, Length, NumberRange, Optional


class GameServerForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(max=80)])
    service_unit = StringField(
        "Systemd unit (optional)",
        validators=[Optional(), Length(max=128)],
        description="Links start/stop/restart/logs to an existing service, e.g. fxserver-cfrp.service",
    )
    http_host = StringField("FXServer HTTP host", validators=[DataRequired(), Length(max=255)], default="127.0.0.1")
    http_port = IntegerField("FXServer HTTP/game port", validators=[DataRequired(), NumberRange(min=1, max=65535)], default=30120)

    rcon_host = StringField(
        "RCON host (optional)", validators=[Optional(), Length(max=255)],
        description="Leave blank to use the HTTP host above.",
    )
    rcon_port = IntegerField(
        "RCON port (optional)", validators=[Optional(), NumberRange(min=1, max=65535)],
        description="Leave blank to use the HTTP port above.",
    )
    rcon_password = PasswordField(
        "RCON password (optional)", validators=[Optional(), Length(max=255)],
        description="Matches rcon_password in server.cfg. Leave blank to disable the RCON console for this server.",
    )
    ban_resource_note = StringField(
        "Ban resource note (optional)", validators=[Optional(), Length(max=255)],
        description="Reminder of which ban resource/command this server uses — persistent bans aren't reachable via RCON.",
    )
