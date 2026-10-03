from datetime import datetime, timezone as dt_timezone

from app import db
from app.services.crypto import EncryptedString

STATUSES = ["new", "contacted", "verifying", "resolved", "closed"]
STATUS_LABELS = {
    "new": "New",
    "contacted": "ISP contacted",
    "verifying": "Awaiting your verification",
    "resolved": "Resolved",
    "closed": "Closed",
}


class SupportRequest(db.Model):
    """A customer's request + authorisation to contact their ISP on their
    behalf, per the ISP Support & Customer Authorisation policy.

    Fields the policy explicitly marks as sensitive-if-required
    (account/customer number, DOB, mother's maiden name, childhood
    nickname, security answers, other security info) are encrypted at
    rest via EncryptedString — see app/services/crypto.py. Passwords and
    one-time codes are never collected, so there's deliberately no column
    for them anywhere in this model.
    """

    __tablename__ = "support_requests"

    id = db.Column(db.Integer, primary_key=True)
    status = db.Column(db.String(20), nullable=False, default="new", index=True)
    submitted_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc), index=True)
    resolved_at = db.Column(db.DateTime, nullable=True)

    # Contact / identification — not especially sensitive on their own.
    full_name = db.Column(db.String(200), nullable=False)
    email = db.Column(db.String(255), nullable=True)
    phone = db.Column(db.String(50), nullable=True)
    isp_name = db.Column(db.String(200), nullable=False)
    problem_description = db.Column(db.Text, nullable=False)

    # Account verification details — encrypted at rest.
    account_number = db.Column(EncryptedString, nullable=True)
    customer_number = db.Column(EncryptedString, nullable=True)
    full_address = db.Column(EncryptedString, nullable=True)
    service_address = db.Column(EncryptedString, nullable=True)
    date_of_birth = db.Column(EncryptedString, nullable=True)  # stored as free text, not a Date — optional field
    last_bill_date = db.Column(db.String(20), nullable=True)
    last_bill_amount = db.Column(db.String(20), nullable=True)

    # ISP-specific security questions — encrypted at rest.
    mothers_maiden_name = db.Column(EncryptedString, nullable=True)
    childhood_nickname = db.Column(EncryptedString, nullable=True)
    security_question = db.Column(db.String(255), nullable=True)
    security_answer = db.Column(EncryptedString, nullable=True)
    other_security_info = db.Column(EncryptedString, nullable=True)

    # Consent — every field required by the policy's authorisation section.
    consent_authorised = db.Column(db.Boolean, nullable=False, default=False)
    consent_accurate = db.Column(db.Boolean, nullable=False, default=False)
    consent_purpose = db.Column(db.Boolean, nullable=False, default=False)
    consent_additional_verification = db.Column(db.Boolean, nullable=False, default=False)
    consent_no_password_request = db.Column(db.Boolean, nullable=False, default=False)

    admin_notes = db.Column(db.Text, nullable=True)

    access_logs = db.relationship(
        "SupportAccessLog", backref="request", lazy="dynamic", cascade="all, delete-orphan"
    )

    @property
    def status_label(self):
        return STATUS_LABELS.get(self.status, self.status)


class SupportAccessLog(db.Model):
    """Records every time a staff account opens a support request's detail
    page — the "audit logs showing who accessed customer information"
    requirement from the policy.
    """

    __tablename__ = "support_access_logs"

    id = db.Column(db.Integer, primary_key=True)
    support_request_id = db.Column(db.Integer, db.ForeignKey("support_requests.id"), nullable=False, index=True)
    user_id = db.Column(db.Integer, db.ForeignKey("users.id"), nullable=False)
    accessed_at = db.Column(db.DateTime, default=lambda: datetime.now(dt_timezone.utc))

    user = db.relationship("User")
