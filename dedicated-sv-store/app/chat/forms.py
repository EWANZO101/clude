from flask_wtf import FlaskForm
from wtforms import TextAreaField, BooleanField
from wtforms.validators import DataRequired


class MessageForm(FlaskForm):
    body = TextAreaField("Message", validators=[DataRequired()])
    is_internal_note = BooleanField("Internal note (staff only)")


class CustomerMessageForm(FlaskForm):
    body = TextAreaField("Message", validators=[DataRequired()])
