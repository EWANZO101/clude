import json
import secrets
from datetime import date, datetime

from flask_login import UserMixin
from werkzeug.security import check_password_hash, generate_password_hash

from extensions import db


def gen_token(n=20):
    return secrets.token_urlsafe(n)


class Company(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(120), nullable=False)
    default_currency = db.Column(db.String(3), default="GBP")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    # PDF / document branding
    brand_display_name = db.Column(db.String(120))  # falls back to `name` if unset
    brand_bg_color = db.Column(db.String(7), default="#0B1F3A")     # dark navy default
    brand_accent_color = db.Column(db.String(7), default="#B08D3E")  # gold default
    brand_logo_filename = db.Column(db.String(255))

    users = db.relationship("User", backref="company", lazy=True)
    clients = db.relationship("Client", backref="company", lazy=True)
    contracts = db.relationship("Contract", backref="company", lazy=True)


class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=False)
    name = db.Column(db.String(120), nullable=False)
    email = db.Column(db.String(160), unique=True, nullable=False)
    password_hash = db.Column(db.String(255), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def set_password(self, pw):
        self.password_hash = generate_password_hash(pw)

    def check_password(self, pw):
        return check_password_hash(self.password_hash, pw)


class Client(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=False)
    name = db.Column(db.String(160), nullable=False)
    email = db.Column(db.String(160))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    contracts = db.relationship("Contract", backref="client", lazy=True)


class Contract(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=False)
    client_id = db.Column(db.Integer, db.ForeignKey("client.id"), nullable=False)
    title = db.Column(db.String(200), nullable=False)
    total_amount = db.Column(db.Numeric(12, 2), nullable=False)
    currency_code = db.Column(db.String(3), nullable=False)
    allow_outstanding_balance = db.Column(db.Boolean, default=False)
    allows_schedule_changes = db.Column(db.Boolean, default=True)
    status = db.Column(db.String(20), default="draft")  # draft / sent / signed
    currency_locked = db.Column(db.Boolean, default=False)
    share_token = db.Column(db.String(64), unique=True, default=gen_token)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    # Agreement text + e-signature
    agreement_text = db.Column(db.Text)
    signed_by_name = db.Column(db.String(160))
    signature_text = db.Column(db.String(200))
    signed_at = db.Column(db.DateTime)

    # Share link protection + client self-serve schedule setup
    pin_code = db.Column(db.String(10))
    client_can_build_schedule = db.Column(db.Boolean, default=True)
    max_payment_months = db.Column(db.Integer)  # cap on how far out the client can spread payments

    schedule = db.relationship(
        "PaymentSchedule", backref="contract", uselist=False, cascade="all, delete-orphan"
    )
    audit_entries = db.relationship(
        "AuditLog", backref="contract", lazy=True, cascade="all, delete-orphan",
        order_by="desc(AuditLog.created_at)"
    )

    def lock_currency(self):
        self.currency_locked = True
        self.status = "sent"

    @property
    def is_signed(self):
        return self.signed_at is not None

    @property
    def amount_paid(self):
        if not self.schedule:
            return 0
        return sum(float(p.amount) for p in self.schedule.payments if p.status == "paid")

    @property
    def amount_remaining(self):
        return float(self.total_amount) - self.amount_paid

    @property
    def next_payment(self):
        if not self.schedule:
            return None
        upcoming = [p for p in self.schedule.payments if p.status in ("upcoming", "overdue")]
        upcoming.sort(key=lambda p: p.due_date)
        return upcoming[0] if upcoming else None

    @property
    def overdue_amount(self):
        if not self.schedule:
            return 0
        today = date.today()
        total = 0.0
        for p in self.schedule.payments:
            if p.status != "paid" and p.due_date < today:
                total += float(p.amount)
        return total

    @property
    def remaining_instalments(self):
        if not self.schedule:
            return 0
        return len([p for p in self.schedule.payments if p.status != "paid"])


class PaymentSchedule(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    contract_id = db.Column(db.Integer, db.ForeignKey("contract.id"), nullable=False)
    frequency = db.Column(db.String(20), nullable=False)  # one_time/weekly/biweekly/monthly/bimonthly/quarterly/custom
    start_date = db.Column(db.Date, nullable=False)
    day_of_month = db.Column(db.Integer)  # only for monthly-style
    num_instalments = db.Column(db.Integer, nullable=False)
    auto_end = db.Column(db.Boolean, default=True)
    amount_mode = db.Column(db.String(20), default="fixed")  # fixed/percentage/custom
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    payments = db.relationship(
        "Payment", backref="schedule", lazy=True, cascade="all, delete-orphan",
        order_by="Payment.sequence"
    )

    @property
    def total_scheduled(self):
        return sum(float(p.amount) for p in self.payments)

    @property
    def first_payment_date(self):
        return self.payments[0].due_date if self.payments else None

    @property
    def final_payment_date(self):
        return self.payments[-1].due_date if self.payments else None


class Payment(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    schedule_id = db.Column(db.Integer, db.ForeignKey("payment_schedule.id"), nullable=False)
    sequence = db.Column(db.Integer, nullable=False)
    due_date = db.Column(db.Date, nullable=False)
    amount = db.Column(db.Numeric(12, 2), nullable=False)
    label = db.Column(db.String(60))  # e.g. Deposit / Final payment
    status = db.Column(db.String(20), default="upcoming")  # upcoming/paid/overdue
    paid_at = db.Column(db.DateTime)

    def refresh_status(self):
        if self.status == "paid":
            return
        self.status = "overdue" if self.due_date < date.today() else "upcoming"


class ReminderSetting(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    company_id = db.Column(db.Integer, db.ForeignKey("company.id"), nullable=False, unique=True)
    days_before_due = db.Column(db.Integer, default=3)
    remind_on_due_date = db.Column(db.Boolean, default=True)
    remind_when_overdue = db.Column(db.Boolean, default=True)
    overdue_repeat_days = db.Column(db.Integer, default=7)


class AuditLog(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    contract_id = db.Column(db.Integer, db.ForeignKey("contract.id"), nullable=False)
    action = db.Column(db.String(60), nullable=False)
    original_schedule = db.Column(db.Text)  # JSON snapshot
    requested_change = db.Column(db.Text)   # JSON description
    new_schedule = db.Column(db.Text)       # JSON snapshot
    requested_by = db.Column(db.String(160))
    approved_by = db.Column(db.String(160))
    approval_status = db.Column(db.String(20), default="pending")  # pending/approved/rejected
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def original_dict(self):
        return json.loads(self.original_schedule) if self.original_schedule else None

    def new_dict(self):
        return json.loads(self.new_schedule) if self.new_schedule else None

    def change_dict(self):
        return json.loads(self.requested_change) if self.requested_change else None
