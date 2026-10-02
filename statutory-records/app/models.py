import uuid
from datetime import datetime, timedelta

from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash

from app.extensions import db


def gen_uuid():
    return str(uuid.uuid4())


class User(db.Model, UserMixin):
    __tablename__ = "users"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    name = db.Column(db.String(120), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    # Lets a director configure their own integrations entirely through the
    # UI (Settings -> Integrations) instead of anyone needing server/file
    # access. Encrypted at rest -- see app/crypto.py. Account-level rather
    # than per-company: a Companies House key is used to look a company UP,
    # before that company exists in this app, so it can't live on a Company
    # row -- one key per signed-up user, used for every company they add.
    companies_house_api_key_encrypted = db.Column(db.Text)

    companies = db.relationship("Company", backref="owner", cascade="all, delete-orphan")

    def set_password(self, raw):
        self.password_hash = generate_password_hash(raw)

    def check_password(self, raw):
        return check_password_hash(self.password_hash, raw)


class Company(db.Model):
    __tablename__ = "companies"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)

    company_name = db.Column(db.String(300), nullable=False)
    company_number = db.Column(db.String(20))
    company_type = db.Column(db.String(40), default="ltd")  # ltd, llp, plc, sole_trader, other
    company_status = db.Column(db.String(40), default="active")  # active, dormant, dissolved
    incorporation_date = db.Column(db.Date, nullable=True)
    registered_office_address = db.Column(db.String(400))
    sic_codes = db.Column(db.String(200))  # comma-separated
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    directors = db.relationship("Director", backref="company", cascade="all, delete-orphan",
                                 order_by="Director.resignation_date.is_(None).desc(), Director.name")
    deadlines = db.relationship("StatutoryDeadline", backref="company", cascade="all, delete-orphan",
                                 order_by="StatutoryDeadline.due_date")
    documents = db.relationship("Document", backref="company", cascade="all, delete-orphan",
                                 order_by="Document.uploaded_at.desc()")
    bank_connections = db.relationship("BankConnection", backref="company", cascade="all, delete-orphan")

    @property
    def bank_account(self):
        """A company has at most one connected bank account in this UI --
        return the first active one, if any."""
        for conn in self.bank_connections:
            if conn.status == "connected" and conn.accounts:
                return conn.accounts[0]
        return None

    @property
    def next_deadline(self):
        upcoming = [d for d in self.deadlines if not d.completed_at]
        return min(upcoming, key=lambda d: d.due_date) if upcoming else None

    @property
    def active_directors(self):
        return [d for d in self.directors if not d.resignation_date]


class Director(db.Model):
    __tablename__ = "directors"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    company_id = db.Column(db.String(36), db.ForeignKey("companies.id"), nullable=False, index=True)

    name = db.Column(db.String(200), nullable=False)
    role = db.Column(db.String(20), default="director")  # director, psc, both
    appointment_date = db.Column(db.Date, nullable=True)
    resignation_date = db.Column(db.Date, nullable=True)  # null = still active
    nationality = db.Column(db.String(80))
    notes = db.Column(db.Text)


DEADLINE_KINDS = [
    ("confirmation_statement", "Confirmation statement"),
    ("annual_accounts", "Annual accounts"),
    ("corporation_tax", "Corporation tax"),
    ("custom", "Other"),
]


class StatutoryDeadline(db.Model):
    __tablename__ = "statutory_deadlines"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    company_id = db.Column(db.String(36), db.ForeignKey("companies.id"), nullable=False, index=True)

    kind = db.Column(db.String(30), default="custom")
    label = db.Column(db.String(200))
    due_date = db.Column(db.Date, nullable=False)
    frequency = db.Column(db.String(20), default="annual")  # annual, one_off
    completed_at = db.Column(db.DateTime, nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @property
    def display_label(self):
        if self.label:
            return self.label
        return dict(DEADLINE_KINDS).get(self.kind, "Deadline")

    @property
    def days_until(self):
        from datetime import date
        return (self.due_date - date.today()).days

    @property
    def urgency(self):
        """overdue | soon | ok -- drives colour-coding wherever deadlines are shown."""
        if self.completed_at:
            return "done"
        days = self.days_until
        if days < 0:
            return "overdue"
        if days <= 30:
            return "soon"
        return "ok"

    def mark_complete(self):
        self.completed_at = datetime.utcnow()
        if self.frequency == "annual":
            # Roll forward and reopen -- same "mark paid rolls the due date
            # forward" pattern as a recurring bill, applied to a recurring
            # statutory filing instead.
            self.due_date = self.due_date + timedelta(days=365)
            self.completed_at = None


class BankConnection(db.Model):
    """A company's connected bank (Monzo Business etc). Tokens are Fernet-
    encrypted at rest -- see app/crypto.py -- same pattern as the payments
    app's finance module."""
    __tablename__ = "bank_connections"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    company_id = db.Column(db.String(36), db.ForeignKey("companies.id"), nullable=False, index=True)

    provider = db.Column(db.String(40), nullable=False)  # monzo, gocardless
    access_token_encrypted = db.Column(db.Text)
    refresh_token_encrypted = db.Column(db.Text)
    status = db.Column(db.String(20), default="connected")  # connected, expired, error, disconnected
    last_synced_at = db.Column(db.DateTime)
    last_error = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    # gocardless (Open Banking aggregator, covers ~all other UK banks) only:
    # auth there is per-requisition, not a refreshable OAuth token like
    # Monzo's, and a consent expires (bank-defined, usually ~90 days) rather
    # than refreshing indefinitely -- reconnecting makes a new requisition.
    institution_id = db.Column(db.String(120))
    institution_name = db.Column(db.String(200))
    requisition_id = db.Column(db.String(120))

    accounts = db.relationship("BankAccount", backref="connection", cascade="all, delete-orphan")


class BankAccount(db.Model):
    __tablename__ = "bank_accounts"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    connection_id = db.Column(db.String(36), db.ForeignKey("bank_connections.id"), nullable=False, index=True)
    company_id = db.Column(db.String(36), db.ForeignKey("companies.id"), nullable=False, index=True)

    provider_account_id = db.Column(db.String(120), nullable=False)
    name = db.Column(db.String(120))
    account_number = db.Column(db.String(20))
    sort_code = db.Column(db.String(10))
    currency = db.Column(db.String(10), default="GBP")
    balance_minor = db.Column(db.Integer, default=0)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    transactions = db.relationship("BankTransaction", backref="account", cascade="all, delete-orphan",
                                    order_by="BankTransaction.date.desc()")


class BankTransaction(db.Model):
    __tablename__ = "bank_transactions"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    account_id = db.Column(db.String(36), db.ForeignKey("bank_accounts.id"), nullable=False, index=True)
    company_id = db.Column(db.String(36), db.ForeignKey("companies.id"), nullable=False, index=True)

    date = db.Column(db.Date, nullable=False, index=True)
    description = db.Column(db.String(400))
    amount_minor = db.Column(db.Integer, nullable=False)
    currency = db.Column(db.String(10), default="GBP")
    external_transaction_id = db.Column(db.String(200), index=True)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    __table_args__ = (db.UniqueConstraint("account_id", "external_transaction_id", name="uq_bank_txn_account_extid"),)


class Document(db.Model):
    __tablename__ = "documents"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    company_id = db.Column(db.String(36), db.ForeignKey("companies.id"), nullable=False, index=True)

    original_filename = db.Column(db.String(255), nullable=False)
    stored_filename = db.Column(db.String(255), nullable=False)  # UUID-named on disk
    description = db.Column(db.String(300))
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)
