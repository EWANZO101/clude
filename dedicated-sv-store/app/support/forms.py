from flask_wtf import FlaskForm
from wtforms import StringField, TextAreaField, SelectField, BooleanField
from wtforms.validators import DataRequired, Length

from app.models.support import TicketPriority

PRIORITY_CHOICES = [(p.value, p.name.title()) for p in TicketPriority]


class TicketForm(FlaskForm):
    subject = StringField("Subject", validators=[DataRequired(), Length(max=255)])
    category = StringField("Category", validators=[DataRequired(), Length(max=100)])
    priority = SelectField("Priority", choices=PRIORITY_CHOICES, default=TicketPriority.NORMAL.value)
    description = TextAreaField("Description", validators=[DataRequired()])


class TicketMessageForm(FlaskForm):
    body = TextAreaField("Message", validators=[DataRequired()])
    is_internal_note = BooleanField("Internal note (staff only)")


class CustomerTicketMessageForm(FlaskForm):
    body = TextAreaField("Message", validators=[DataRequired()])
