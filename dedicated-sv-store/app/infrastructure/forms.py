from flask_wtf import FlaskForm
from wtforms import StringField, IntegerField, DecimalField, SelectField, BooleanField
from wtforms.validators import DataRequired, Optional, Length, NumberRange


class DatacenterForm(FlaskForm):
    name = StringField("Name", validators=[DataRequired(), Length(max=150)])
    code = StringField("Code", validators=[DataRequired(), Length(max=20)])
    country = StringField("Country code", validators=[Optional(), Length(max=2)])
    city = StringField("City", validators=[Optional(), Length(max=100)])
    address = StringField("Address", validators=[Optional(), Length(max=255)])
    is_active = BooleanField("Active", default=True)


class RackForm(FlaskForm):
    datacenter_id = SelectField("Datacenter", coerce=int, validators=[DataRequired()])
    name = StringField("Rack name/number", validators=[DataRequired(), Length(max=50)])
    row = StringField("Row", validators=[Optional(), Length(max=50)])
    total_u = IntegerField("Total U", default=42, validators=[DataRequired(), NumberRange(min=1)])
    is_active = BooleanField("Active", default=True)


class RackAssignmentForm(FlaskForm):
    rack_id = SelectField("Rack", coerce=int, validators=[DataRequired()])
    start_u = IntegerField("Start U position", validators=[DataRequired(), NumberRange(min=1)])
    u_height = DecimalField("U height", default=1, validators=[DataRequired()], places=1)


class PowerAssignmentForm(FlaskForm):
    power_feed_a = StringField("Power feed A", validators=[Optional(), Length(max=50)])
    power_feed_b = StringField("Power feed B", validators=[Optional(), Length(max=50)])
    pdu_outlet_a = StringField("PDU outlet A", validators=[Optional(), Length(max=50)])
    pdu_outlet_b = StringField("PDU outlet B", validators=[Optional(), Length(max=50)])
    amperage = DecimalField("Amperage", validators=[Optional()], places=2)


class NetworkAssignmentForm(FlaskForm):
    switch_name = StringField("Switch", validators=[Optional(), Length(max=100)])
    switch_port = StringField("Switch port", validators=[Optional(), Length(max=50)])
    vlan = StringField("VLAN", validators=[Optional(), Length(max=50)])
    management_ip = StringField("Management IP", validators=[Optional(), Length(max=45)])
    public_ipv4 = StringField("Public IPv4", validators=[Optional(), Length(max=45)])
    public_ipv6 = StringField("Public IPv6", validators=[Optional(), Length(max=100)])
    bandwidth_mbps = IntegerField("Bandwidth (Mbps)", validators=[Optional()])
