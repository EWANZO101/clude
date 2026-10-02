from flask_wtf import FlaskForm
from wtforms import StringField, TextAreaField, SelectField, SubmitField
from wtforms.validators import DataRequired, Length, Email


class NewTicketForm(FlaskForm):
    subject = StringField("Subject", validators=[DataRequired(), Length(max=255)])
    message = TextAreaField("How can we help?", validators=[DataRequired()])
    submit = SubmitField("Create ticket")


class ReplyForm(FlaskForm):
    body = TextAreaField("Reply", validators=[DataRequired()])
    submit = SubmitField("Send reply")


class AdminNewTicketForm(FlaskForm):
    user_email = StringField("User's email", validators=[DataRequired(), Email()])
    subject = StringField("Subject", validators=[DataRequired(), Length(max=255)])
    message = TextAreaField("Message", validators=[DataRequired()])
    submit = SubmitField("Open ticket")


class TicketActionForm(FlaskForm):
    """Bare CSRF-carrying form for the assign/priority/status action buttons."""
    priority = SelectField(
        "Priority",
        choices=[("low", "Low"), ("normal", "Normal"), ("high", "High"), ("urgent", "Urgent")],
    )
    status = SelectField(
        "Status",
        choices=[
            ("open", "Open"), ("pending_user", "Waiting on user"),
            ("pending_support", "Waiting on support"), ("resolved", "Resolved"), ("closed", "Closed"),
        ],
    )
    submit = SubmitField("Update")
