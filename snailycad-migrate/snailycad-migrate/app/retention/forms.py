from flask_wtf import FlaskForm
from wtforms import TextAreaField, IntegerField, BooleanField, SubmitField
from wtforms.validators import DataRequired, NumberRange, ValidationError


class ExtensionRequestForm(FlaskForm):
    reason = TextAreaField(
        "Why do you need more time?",
        validators=[DataRequired()],
        description="A clear reason helps get your request reviewed faster.",
    )
    requested_days = IntegerField(
        "Requested retention period (days)",
        validators=[DataRequired(), NumberRange(min=8, max=3650)],
        description="Must be more than the standard 7 days.",
    )

    consent_no_guarantee = BooleanField(
        "I understand that OpsLab cannot guarantee 100% data security after the standard 7-day retention period."
    )
    consent_increases_period = BooleanField(
        "I understand that extended retention increases the period my data is stored."
    )
    consent_not_responsible = BooleanField(
        "I agree that OpsLab is not responsible for risks associated with keeping data stored beyond the recommended period."
    )
    consent_remove_asap = BooleanField(
        "I understand that I should remove or export my data as soon as possible."
    )
    consent_accept_terms = BooleanField(
        "I accept the Extended Data Retention Terms & Conditions."
    )

    submit = SubmitField("Submit request")

    def validate_consent_accept_terms(self, field):
        all_checked = all([
            self.consent_no_guarantee.data,
            self.consent_increases_period.data,
            self.consent_not_responsible.data,
            self.consent_remove_asap.data,
            self.consent_accept_terms.data,
        ])
        if not all_checked:
            raise ValidationError("All boxes above must be checked to submit an extension request.")
