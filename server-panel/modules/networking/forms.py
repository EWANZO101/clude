from flask_wtf import FlaskForm
from wtforms import StringField
from wtforms.validators import DataRequired, Length


class HostnameForm(FlaskForm):
    hostname = StringField("Hostname", validators=[DataRequired(), Length(max=63)])


class StaticIpForm(FlaskForm):
    interface = StringField("Interface", validators=[DataRequired(), Length(max=32)])
    address_cidr = StringField("IP Address (CIDR)", validators=[DataRequired(), Length(max=20)])
    gateway = StringField("Gateway", validators=[DataRequired(), Length(max=45)])
    dns_servers = StringField("DNS Servers (comma separated)", validators=[DataRequired(), Length(max=200)])
