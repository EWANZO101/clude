from flask_wtf import FlaskForm
from wtforms import StringField, SelectField
from wtforms.validators import DataRequired, Length


class OpenPortForm(FlaskForm):
    port = StringField("Port Number", validators=[DataRequired(), Length(max=6)])
    protocol = SelectField("Protocol", choices=[("tcp", "TCP"), ("udp", "UDP")], default="tcp")
    description = StringField("Description", validators=[Length(max=100)])


class IpRuleForm(FlaskForm):
    ip = StringField("IP Address / CIDR", validators=[DataRequired(), Length(max=45)])


class SshWhitelistForm(FlaskForm):
    ip = StringField("IP Address", validators=[DataRequired(), Length(max=45)])
