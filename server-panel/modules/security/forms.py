from flask_wtf import FlaskForm
from wtforms import StringField
from wtforms.validators import DataRequired, Length


class BlockIpForm(FlaskForm):
    ip = StringField("IP Address", validators=[DataRequired(), Length(max=45)])
