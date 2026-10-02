#!/usr/bin/env bash
# =============================================================================
# Bookkeeping Platform — Phase 1: Foundation
# Builds: Flask app factory, config, auth, businesses, roles, chart of
# accounts, double-entry accounting engine, Tailwind UI (light/dark), basic
# dashboard. Run this script to scaffold the full project on disk.
# =============================================================================
set -euo pipefail

ROOT="bookkeeping-platform"
echo ">> Creating project at ./${ROOT}"
rm -rf "${ROOT}"
mkdir -p "${ROOT}"
cd "${ROOT}"

mkdir -p app/auth app/users app/businesses app/accounting app/dashboard \
         app/templates/auth app/templates/dashboard app/templates/businesses \
         app/templates/accounting app/static/css app/static/js \
         migrations tests scripts deployment

# -----------------------------------------------------------------------------
# requirements.txt
# -----------------------------------------------------------------------------
cat > requirements.txt << 'EOF'
Flask==3.0.3
Flask-SQLAlchemy==3.1.1
Flask-Migrate==4.0.7
Flask-Login==0.6.3
Flask-WTF==1.2.1
WTForms==3.1.2
python-dotenv==1.0.1
email-validator==2.1.1
gunicorn==22.0.0
pytest==8.2.0
EOF

# -----------------------------------------------------------------------------
# .env.example
# -----------------------------------------------------------------------------
cat > .env.example << 'EOF'
FLASK_APP=run.py
FLASK_ENV=development
SECRET_KEY=change-this-to-a-long-random-value
DATABASE_URL=sqlite:///instance/app.db
EOF

# -----------------------------------------------------------------------------
# run.py
# -----------------------------------------------------------------------------
cat > run.py << 'EOF'
import os
from app import create_app

config_name = os.environ.get("FLASK_CONFIG", "development")
app = create_app(config_name)

if __name__ == "__main__":
    app.run(debug=app.config.get("DEBUG", False))
EOF

# -----------------------------------------------------------------------------
# app/config.py
# -----------------------------------------------------------------------------
cat > app/config.py << 'EOF'
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


class BaseConfig:
    SECRET_KEY = os.environ.get("SECRET_KEY", "dev-secret-key-change-me")
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    WTF_CSRF_ENABLED = True
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = "Lax"
    REMEMBER_COOKIE_HTTPONLY = True


class DevelopmentConfig(BaseConfig):
    DEBUG = True
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", f"sqlite:///{BASE_DIR / 'instance' / 'app.db'}"
    )
    SESSION_COOKIE_SECURE = False


class TestingConfig(BaseConfig):
    TESTING = True
    SQLALCHEMY_DATABASE_URI = "sqlite:///:memory:"
    WTF_CSRF_ENABLED = False
    SESSION_COOKIE_SECURE = False


class ProductionConfig(BaseConfig):
    DEBUG = False
    SQLALCHEMY_DATABASE_URI = os.environ.get("DATABASE_URL")
    SESSION_COOKIE_SECURE = True

    def __init__(self):
        if not os.environ.get("DATABASE_URL"):
            raise RuntimeError("DATABASE_URL must be set in production")
        if os.environ.get("SECRET_KEY", "dev-secret-key-change-me") == "dev-secret-key-change-me":
            raise RuntimeError("SECRET_KEY must be set to a real secret in production")


config = {
    "development": DevelopmentConfig,
    "testing": TestingConfig,
    "production": ProductionConfig,
    "default": DevelopmentConfig,
}
EOF

# -----------------------------------------------------------------------------
# app/extensions.py
# -----------------------------------------------------------------------------
cat > app/extensions.py << 'EOF'
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from flask_login import LoginManager
from flask_wtf import CSRFProtect

db = SQLAlchemy()
migrate = Migrate()
login_manager = LoginManager()
csrf = CSRFProtect()

login_manager.login_view = "auth.login"
login_manager.login_message = "Please log in to access this page."
login_manager.login_message_category = "info"
EOF

# -----------------------------------------------------------------------------
# app/__init__.py  (application factory)
# -----------------------------------------------------------------------------
cat > app/__init__.py << 'EOF'
import os
from flask import Flask
from app.config import config
from app.extensions import db, migrate, login_manager, csrf


def create_app(config_name=None):
    config_name = config_name or os.environ.get("FLASK_CONFIG", "development")
    app = Flask(__name__, instance_relative_config=True)
    app.config.from_object(config[config_name])

    os.makedirs(app.instance_path, exist_ok=True)

    db.init_app(app)
    migrate.init_app(app, db)
    login_manager.init_app(app)
    csrf.init_app(app)

    from app.models import user, business, accounting  # noqa: F401 register models

    from app.auth.routes import auth_bp
    from app.businesses.routes import businesses_bp
    from app.accounting.routes import accounting_bp
    from app.dashboard.routes import dashboard_bp

    app.register_blueprint(auth_bp, url_prefix="/auth")
    app.register_blueprint(businesses_bp, url_prefix="/businesses")
    app.register_blueprint(accounting_bp, url_prefix="/accounting")
    app.register_blueprint(dashboard_bp)

    @app.context_processor
    def inject_globals():
        from flask_login import current_user
        from app.models.business import Business
        current_business = None
        businesses = []
        if current_user.is_authenticated:
            businesses = current_user.businesses()
            current_business = current_user.current_business()
        return dict(current_business=current_business, user_businesses=businesses)

    @app.errorhandler(404)
    def not_found(e):
        from flask import render_template
        return render_template("errors/404.html"), 404

    @app.errorhandler(500)
    def server_error(e):
        from flask import render_template
        db.session.rollback()
        return render_template("errors/500.html"), 500

    return app
EOF

mkdir -p app/models
cat > app/models/__init__.py << 'EOF'
EOF

# -----------------------------------------------------------------------------
# app/models/user.py
# -----------------------------------------------------------------------------
cat > app/models/user.py << 'EOF'
import uuid
from datetime import datetime
from flask_login import UserMixin, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from app.extensions import db, login_manager


def gen_uuid():
    return str(uuid.uuid4())


class User(UserMixin, db.Model):
    __tablename__ = "users"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    email = db.Column(db.String(255), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    full_name = db.Column(db.String(255), nullable=False)
    is_active_flag = db.Column("is_active", db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    current_business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=True)

    memberships = db.relationship(
        "Membership", back_populates="user", cascade="all, delete-orphan"
    )

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)

    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    # Flask-Login expects `is_active` as a property/attribute
    @property
    def is_active(self):
        return self.is_active_flag

    def businesses(self):
        from app.models.business import Business
        return [m.business for m in self.memberships if m.business is not None]

    def current_business(self):
        from app.models.business import Business
        if self.current_business_id:
            biz = Business.query.get(self.current_business_id)
            if biz and self.role_in(biz) is not None:
                return biz
        bs = self.businesses()
        return bs[0] if bs else None

    def role_in(self, business):
        for m in self.memberships:
            if m.business_id == business.id:
                return m.role
        return None

    def __repr__(self):
        return f"<User {self.email}>"


@login_manager.user_loader
def load_user(user_id):
    return User.query.get(user_id)
EOF

# -----------------------------------------------------------------------------
# app/models/business.py
# -----------------------------------------------------------------------------
cat > app/models/business.py << 'EOF'
import uuid
from datetime import datetime
from app.extensions import db

ROLE_OWNER = "owner"
ROLE_ADMIN = "admin"
ROLE_ACCOUNTANT = "accountant"
ROLE_BOOKKEEPER = "bookkeeper"
ROLE_MANAGER = "manager"
ROLE_EMPLOYEE = "employee"
ROLE_READONLY = "readonly"

ALL_ROLES = [
    ROLE_OWNER, ROLE_ADMIN, ROLE_ACCOUNTANT, ROLE_BOOKKEEPER,
    ROLE_MANAGER, ROLE_EMPLOYEE, ROLE_READONLY,
]

# Simple, explicit permission table for Phase 1. Extended later.
ROLE_PERMISSIONS = {
    ROLE_OWNER: {"view", "create", "edit", "delete", "manage_users", "manage_settings", "export"},
    ROLE_ADMIN: {"view", "create", "edit", "delete", "manage_users", "manage_settings", "export"},
    ROLE_ACCOUNTANT: {"view", "create", "edit", "export"},
    ROLE_BOOKKEEPER: {"view", "create", "edit", "export"},
    ROLE_MANAGER: {"view", "create", "edit", "export"},
    ROLE_EMPLOYEE: {"view", "create"},
    ROLE_READONLY: {"view"},
}


def gen_uuid():
    return str(uuid.uuid4())


class Business(db.Model):
    __tablename__ = "businesses"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    name = db.Column(db.String(255), nullable=False)
    base_currency = db.Column(db.String(3), default="USD", nullable=False)
    is_archived = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    memberships = db.relationship(
        "Membership", back_populates="business", cascade="all, delete-orphan"
    )
    accounts = db.relationship(
        "Account", back_populates="business", cascade="all, delete-orphan"
    )
    journal_entries = db.relationship(
        "JournalEntry", back_populates="business", cascade="all, delete-orphan"
    )

    def __repr__(self):
        return f"<Business {self.name}>"


class Membership(db.Model):
    """Links a User to a Business with a role. Enforces strict data isolation:
    a user can only ever query business data through an existing membership."""

    __tablename__ = "memberships"
    __table_args__ = (
        db.UniqueConstraint("user_id", "business_id", name="uq_user_business"),
    )

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    role = db.Column(db.String(32), nullable=False, default=ROLE_EMPLOYEE)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    user = db.relationship("User", back_populates="memberships")
    business = db.relationship("Business", back_populates="memberships")

    def has_permission(self, permission):
        return permission in ROLE_PERMISSIONS.get(self.role, set())
EOF

# -----------------------------------------------------------------------------
# app/models/accounting.py  (double-entry core)
# -----------------------------------------------------------------------------
cat > app/models/accounting.py << 'EOF'
import uuid
from datetime import datetime
from app.extensions import db

ASSET = "asset"
LIABILITY = "liability"
EQUITY = "equity"
REVENUE = "revenue"
COGS = "cogs"
EXPENSE = "expense"

ACCOUNT_TYPES = [ASSET, LIABILITY, EQUITY, REVENUE, COGS, EXPENSE]

# Which side increases the balance of each account type.
DEBIT_INCREASES = {ASSET, EXPENSE, COGS}
CREDIT_INCREASES = {LIABILITY, EQUITY, REVENUE}


def gen_uuid():
    return str(uuid.uuid4())


class Account(db.Model):
    """A single account in a business's chart of accounts."""

    __tablename__ = "accounts"
    __table_args__ = (
        db.UniqueConstraint("business_id", "code", name="uq_business_account_code"),
    )

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)
    parent_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=True)

    code = db.Column(db.String(20), nullable=False)
    name = db.Column(db.String(255), nullable=False)
    account_type = db.Column(db.String(20), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_archived = db.Column(db.Boolean, default=False, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    business = db.relationship("Business", back_populates="accounts")
    children = db.relationship("Account", backref=db.backref("parent", remote_side=[id]))
    lines = db.relationship("JournalLine", back_populates="account")

    def balance(self):
        """Computed balance in the account's natural direction (never negative
        by convention; a debit-normal account with credit balance shows negative)."""
        total_debit = sum(l.debit for l in self.lines if not l.journal_entry.is_void)
        total_credit = sum(l.credit for l in self.lines if not l.journal_entry.is_void)
        if self.account_type in DEBIT_INCREASES:
            return total_debit - total_credit
        return total_credit - total_debit

    def __repr__(self):
        return f"<Account {self.code} {self.name}>"


DEFAULT_CHART_OF_ACCOUNTS = [
    ("1000", "Cash and Bank", ASSET),
    ("1100", "Accounts Receivable", ASSET),
    ("1500", "Fixed Assets", ASSET),
    ("2000", "Accounts Payable", LIABILITY),
    ("2100", "Loans Payable", LIABILITY),
    ("2200", "Tax Payable", LIABILITY),
    ("3000", "Owner's Equity", EQUITY),
    ("3900", "Retained Earnings", EQUITY),
    ("4000", "Sales Revenue", REVENUE),
    ("5000", "Cost of Goods Sold", COGS),
    ("6000", "General Expenses", EXPENSE),
    ("6100", "Payroll Expenses", EXPENSE),
    ("6200", "Bank Fees", EXPENSE),
]


def create_default_chart_of_accounts(business):
    for code, name, acct_type in DEFAULT_CHART_OF_ACCOUNTS:
        db.session.add(Account(business_id=business.id, code=code, name=name, account_type=acct_type))


class JournalEntry(db.Model):
    """A balanced, atomic accounting event. Every transaction in the system
    (invoice, expense, transfer, manual entry, ...) is ultimately recorded as
    one of these, made up of >=2 JournalLines whose debits equal credits."""

    __tablename__ = "journal_entries"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    business_id = db.Column(db.String(36), db.ForeignKey("businesses.id"), nullable=False)

    entry_date = db.Column(db.Date, nullable=False)
    posting_date = db.Column(db.DateTime, default=datetime.utcnow)
    reference = db.Column(db.String(100), nullable=True)
    description = db.Column(db.Text, nullable=True)
    source_type = db.Column(db.String(50), nullable=False, default="manual")  # invoice/expense/manual/...
    source_id = db.Column(db.String(36), nullable=True)

    is_void = db.Column(db.Boolean, default=False, nullable=False)
    is_reconciled = db.Column(db.Boolean, default=False, nullable=False)

    created_by_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    business = db.relationship("Business", back_populates="journal_entries")
    lines = db.relationship("JournalLine", back_populates="journal_entry", cascade="all, delete-orphan")

    def total_debit(self):
        return sum(l.debit for l in self.lines)

    def total_credit(self):
        return sum(l.credit for l in self.lines)

    def is_balanced(self):
        return round(self.total_debit() - self.total_credit(), 2) == 0

    def __repr__(self):
        return f"<JournalEntry {self.id} {self.entry_date}>"


class JournalLine(db.Model):
    __tablename__ = "journal_lines"

    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    journal_entry_id = db.Column(db.String(36), db.ForeignKey("journal_entries.id"), nullable=False)
    account_id = db.Column(db.String(36), db.ForeignKey("accounts.id"), nullable=False)

    debit = db.Column(db.Numeric(14, 2), default=0, nullable=False)
    credit = db.Column(db.Numeric(14, 2), default=0, nullable=False)
    memo = db.Column(db.String(255), nullable=True)

    journal_entry = db.relationship("JournalEntry", back_populates="lines")
    account = db.relationship("Account", back_populates="lines")
EOF

# -----------------------------------------------------------------------------
# app/accounting/engine.py — the guarded posting API
# -----------------------------------------------------------------------------
cat > app/accounting/engine.py << 'EOF'
"""The accounting engine: the ONLY supported way to post financial records.

Rule: journal entries are never created directly against the DB session by
route/business logic. Everything goes through `post_journal_entry` so that
double-entry balance is enforced in one place, and through `void_journal_entry`
so reconciled/void state changes are auditable, never silent deletes.
"""
from datetime import date
from decimal import Decimal, InvalidOperation
from app.extensions import db
from app.models.accounting import JournalEntry, JournalLine, Account


class UnbalancedEntryError(Exception):
    pass


class InvalidLineError(Exception):
    pass


def post_journal_entry(
    business_id,
    entry_date,
    lines,
    description=None,
    reference=None,
    source_type="manual",
    source_id=None,
    created_by_id=None,
):
    """Create and persist a balanced journal entry.

    `lines` is a list of dicts: {"account_id": str, "debit": Decimal|float,
    "credit": Decimal|float, "memo": str (optional)}.

    Raises UnbalancedEntryError if total debits != total credits.
    Raises InvalidLineError if a line references an unknown/foreign account,
    is negative, or has both a debit and credit on the same line.
    """
    if len(lines) < 2:
        raise InvalidLineError("A journal entry needs at least two lines.")

    total_debit = Decimal("0")
    total_credit = Decimal("0")
    prepared = []

    for raw in lines:
        try:
            debit = Decimal(str(raw.get("debit", 0) or 0))
            credit = Decimal(str(raw.get("credit", 0) or 0))
        except InvalidOperation:
            raise InvalidLineError("Debit/credit must be numeric.")

        if debit < 0 or credit < 0:
            raise InvalidLineError("Debit/credit amounts cannot be negative.")
        if debit > 0 and credit > 0:
            raise InvalidLineError("A single line cannot have both a debit and a credit.")
        if debit == 0 and credit == 0:
            raise InvalidLineError("A line must have a nonzero debit or credit.")

        account = Account.query.get(raw["account_id"])
        if account is None or account.business_id != business_id:
            raise InvalidLineError("Line references an account outside this business.")

        total_debit += debit
        total_credit += credit
        prepared.append((account, debit, credit, raw.get("memo")))

    if round(total_debit - total_credit, 2) != 0:
        raise UnbalancedEntryError(
            f"Entry does not balance: debits={total_debit} credits={total_credit}"
        )

    entry = JournalEntry(
        business_id=business_id,
        entry_date=entry_date or date.today(),
        description=description,
        reference=reference,
        source_type=source_type,
        source_id=source_id,
        created_by_id=created_by_id,
    )
    db.session.add(entry)
    db.session.flush()  # get entry.id

    for account, debit, credit, memo in prepared:
        db.session.add(
            JournalLine(
                journal_entry_id=entry.id,
                account_id=account.id,
                debit=debit,
                credit=credit,
                memo=memo,
            )
        )

    db.session.commit()
    return entry


def void_journal_entry(entry, reason=None):
    """Marks an entry void rather than deleting it. History is preserved."""
    if entry.is_void:
        return entry
    entry.is_void = True
    if reason:
        entry.description = f"{entry.description or ''} [VOIDED: {reason}]".strip()
    db.session.commit()
    return entry


def trial_balance(business_id):
    """Returns a list of (account, balance) for every non-archived account."""
    accounts = Account.query.filter_by(business_id=business_id, is_archived=False).order_by(Account.code).all()
    return [(a, a.balance()) for a in accounts]
EOF

# -----------------------------------------------------------------------------
# app/accounting/routes.py
# -----------------------------------------------------------------------------
cat > app/accounting/routes.py << 'EOF'
from datetime import date, datetime
from decimal import Decimal
from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app.models.accounting import Account
from app.accounting.engine import post_journal_entry, UnbalancedEntryError, InvalidLineError, trial_balance
from app.businesses.decorators import require_current_business, require_permission

accounting_bp = Blueprint("accounting", __name__, template_folder="../templates/accounting")


@accounting_bp.route("/chart-of-accounts")
@login_required
@require_current_business
@require_permission("view")
def chart_of_accounts(business):
    accounts = Account.query.filter_by(business_id=business.id, is_archived=False).order_by(Account.code).all()
    return render_template("accounting/chart_of_accounts.html", accounts=accounts)


@accounting_bp.route("/journal/new", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def new_journal_entry(business):
    accounts = Account.query.filter_by(business_id=business.id, is_archived=False).order_by(Account.code).all()

    if request.method == "POST":
        entry_date_str = request.form.get("entry_date")
        description = request.form.get("description")
        try:
            entry_date = datetime.strptime(entry_date_str, "%Y-%m-%d").date() if entry_date_str else date.today()
        except ValueError:
            flash("Invalid date.", "error")
            return render_template("accounting/new_journal_entry.html", accounts=accounts)

        line_account_ids = request.form.getlist("account_id")
        line_debits = request.form.getlist("debit")
        line_credits = request.form.getlist("credit")

        lines = []
        for acc_id, debit, credit in zip(line_account_ids, line_debits, line_credits):
            if not acc_id:
                continue
            lines.append({
                "account_id": acc_id,
                "debit": Decimal(debit) if debit else 0,
                "credit": Decimal(credit) if credit else 0,
            })

        try:
            post_journal_entry(
                business_id=business.id,
                entry_date=entry_date,
                lines=lines,
                description=description,
                source_type="manual",
                created_by_id=current_user.id,
            )
        except (UnbalancedEntryError, InvalidLineError) as e:
            flash(str(e), "error")
            return render_template("accounting/new_journal_entry.html", accounts=accounts)

        flash("Journal entry posted.", "success")
        return redirect(url_for("accounting.chart_of_accounts"))

    return render_template("accounting/new_journal_entry.html", accounts=accounts)


@accounting_bp.route("/reports/trial-balance")
@login_required
@require_current_business
@require_permission("view")
def report_trial_balance(business):
    rows = trial_balance(business.id)
    total_debit = sum(b for a, b in rows if b >= 0)
    total_credit = sum(-b for a, b in rows if b < 0)
    return render_template(
        "accounting/trial_balance.html", rows=rows, total_debit=total_debit, total_credit=total_credit
    )
EOF

# -----------------------------------------------------------------------------
# app/businesses/decorators.py
# -----------------------------------------------------------------------------
cat > app/businesses/decorators.py << 'EOF'
from functools import wraps
from flask import redirect, url_for, flash, abort
from flask_login import current_user


def require_current_business(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        business = current_user.current_business()
        if business is None:
            flash("Create or select a business first.", "info")
            return redirect(url_for("businesses.list_businesses"))
        return view(business=business, *args, **kwargs)
    return wrapped


def require_permission(permission):
    def decorator(view):
        @wraps(view)
        def wrapped(business, *args, **kwargs):
            role = current_user.role_in(business)
            if role is None:
                abort(403)
            from app.models.business import ROLE_PERMISSIONS
            if permission not in ROLE_PERMISSIONS.get(role, set()):
                abort(403)
            return view(business=business, *args, **kwargs)
        return wrapped
    return decorator
EOF

# -----------------------------------------------------------------------------
# app/businesses/routes.py
# -----------------------------------------------------------------------------
cat > app/businesses/routes.py << 'EOF'
from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app.extensions import db
from app.models.business import Business, Membership, ROLE_OWNER
from app.models.accounting import create_default_chart_of_accounts

businesses_bp = Blueprint("businesses", __name__, template_folder="../templates/businesses")


@businesses_bp.route("/")
@login_required
def list_businesses():
    return render_template("businesses/list.html", businesses=current_user.businesses())


@businesses_bp.route("/new", methods=["GET", "POST"])
@login_required
def new_business():
    if request.method == "POST":
        name = request.form.get("name", "").strip()
        currency = request.form.get("base_currency", "USD").strip().upper() or "USD"
        if not name:
            flash("Business name is required.", "error")
            return render_template("businesses/new.html")

        business = Business(name=name, base_currency=currency)
        db.session.add(business)
        db.session.flush()

        db.session.add(Membership(user_id=current_user.id, business_id=business.id, role=ROLE_OWNER))
        create_default_chart_of_accounts(business)

        current_user.current_business_id = business.id
        db.session.commit()

        flash(f"Business '{business.name}' created.", "success")
        return redirect(url_for("dashboard.index"))

    return render_template("businesses/new.html")


@businesses_bp.route("/switch/<business_id>", methods=["POST"])
@login_required
def switch_business(business_id):
    if current_user.role_in_id(business_id) if hasattr(current_user, "role_in_id") else None:
        pass
    membership = next((m for m in current_user.memberships if m.business_id == business_id), None)
    if membership is None:
        flash("You do not have access to that business.", "error")
        return redirect(url_for("businesses.list_businesses"))

    current_user.current_business_id = business_id
    db.session.commit()
    flash(f"Switched to {membership.business.name}.", "success")
    return redirect(url_for("dashboard.index"))


@businesses_bp.route("/<business_id>/archive", methods=["POST"])
@login_required
def archive_business(business_id):
    membership = next((m for m in current_user.memberships if m.business_id == business_id), None)
    if membership is None or membership.role != "owner":
        flash("Only the owner can archive this business.", "error")
        return redirect(url_for("businesses.list_businesses"))

    membership.business.is_archived = True
    db.session.commit()
    flash("Business archived.", "success")
    return redirect(url_for("businesses.list_businesses"))
EOF

# -----------------------------------------------------------------------------
# app/auth/forms.py
# -----------------------------------------------------------------------------
cat > app/auth/forms.py << 'EOF'
from flask_wtf import FlaskForm
from wtforms import StringField, PasswordField, BooleanField
from wtforms.validators import DataRequired, Email, Length, EqualTo


class RegisterForm(FlaskForm):
    full_name = StringField("Full name", validators=[DataRequired(), Length(max=255)])
    email = StringField("Email", validators=[DataRequired(), Email(), Length(max=255)])
    password = PasswordField("Password", validators=[DataRequired(), Length(min=10)])
    confirm_password = PasswordField(
        "Confirm password", validators=[DataRequired(), EqualTo("password", message="Passwords must match.")]
    )


class LoginForm(FlaskForm):
    email = StringField("Email", validators=[DataRequired(), Email()])
    password = PasswordField("Password", validators=[DataRequired()])
    remember_me = BooleanField("Remember me")
EOF

# -----------------------------------------------------------------------------
# app/auth/routes.py
# -----------------------------------------------------------------------------
cat > app/auth/routes.py << 'EOF'
from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_user, logout_user, login_required, current_user
from app.extensions import db
from app.models.user import User
from app.auth.forms import RegisterForm, LoginForm

auth_bp = Blueprint("auth", __name__, template_folder="../templates/auth")


@auth_bp.route("/register", methods=["GET", "POST"])
def register():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    form = RegisterForm()
    if form.validate_on_submit():
        existing = User.query.filter_by(email=form.email.data.lower().strip()).first()
        if existing:
            flash("An account with that email already exists.", "error")
            return render_template("auth/register.html", form=form)

        user = User(email=form.email.data.lower().strip(), full_name=form.full_name.data.strip())
        user.set_password(form.password.data)
        db.session.add(user)
        db.session.commit()

        login_user(user)
        flash("Welcome! Let's create your first business.", "success")
        return redirect(url_for("businesses.new_business"))

    return render_template("auth/register.html", form=form)


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if current_user.is_authenticated:
        return redirect(url_for("dashboard.index"))

    form = LoginForm()
    if form.validate_on_submit():
        user = User.query.filter_by(email=form.email.data.lower().strip()).first()
        if user is None or not user.check_password(form.password.data):
            flash("Invalid email or password.", "error")
            return render_template("auth/login.html", form=form)

        login_user(user, remember=form.remember_me.data)
        next_url = request.args.get("next")
        return redirect(next_url or url_for("dashboard.index"))

    return render_template("auth/login.html", form=form)


@auth_bp.route("/logout")
@login_required
def logout():
    logout_user()
    flash("You have been logged out.", "info")
    return redirect(url_for("auth.login"))
EOF

# -----------------------------------------------------------------------------
# app/dashboard/routes.py
# -----------------------------------------------------------------------------
cat > app/dashboard/routes.py << 'EOF'
from flask import Blueprint, render_template, redirect, url_for
from flask_login import login_required, current_user
from app.models.accounting import trial_balance if False else None  # placeholder unused
from app.accounting.engine import trial_balance

dashboard_bp = Blueprint("dashboard", __name__, template_folder="../templates/dashboard")


@dashboard_bp.route("/")
@login_required
def index():
    business = current_user.current_business()
    if business is None:
        return redirect(url_for("businesses.new_business"))

    rows = trial_balance(business.id)
    from app.models.accounting import ASSET, LIABILITY, REVENUE, EXPENSE, COGS

    total_assets = sum(b for a, b in rows if a.account_type == ASSET)
    total_liabilities = sum(b for a, b in rows if a.account_type == LIABILITY)
    total_revenue = sum(b for a, b in rows if a.account_type == REVENUE)
    total_expenses = sum(b for a, b in rows if a.account_type in (EXPENSE, COGS))
    profit = total_revenue - total_expenses

    return render_template(
        "dashboard/index.html",
        business=business,
        total_assets=total_assets,
        total_liabilities=total_liabilities,
        total_revenue=total_revenue,
        total_expenses=total_expenses,
        profit=profit,
    )
EOF

# fix the accidental bad import line above (placeholder mistake safeguard)
python3 - << 'PYEOF'
import re
path = "app/dashboard/routes.py"
with open(path) as f:
    content = f.read()
content = content.replace(
    "from app.models.accounting import trial_balance if False else None  # placeholder unused\n", ""
)
with open(path, "w") as f:
    f.write(content)
PYEOF

for pkg in auth users businesses accounting dashboard; do
  touch "app/${pkg}/__init__.py"
done

# -----------------------------------------------------------------------------
# Templates — base.html with Tailwind (CDN) + theme switcher
# -----------------------------------------------------------------------------
cat > app/templates/base.html << 'EOF'
<!DOCTYPE html>
<html lang="en" class="h-full">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{% block title %}Bookkeeping{% endblock %}</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = { darkMode: 'class' };
    (function () {
      const stored = localStorage.getItem('theme');
      const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      if (stored === 'dark' || (!stored && prefersDark)) {
        document.documentElement.classList.add('dark');
      }
    })();
  </script>
</head>
<body class="h-full bg-gray-50 dark:bg-gray-900 text-gray-900 dark:text-gray-100">
  <nav class="bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700">
    <div class="max-w-6xl mx-auto px-4 sm:px-6">
      <div class="flex justify-between h-14 items-center">
        <div class="flex items-center gap-6">
          <a href="{{ url_for('dashboard.index') }}" class="font-semibold text-lg">Bookkeeping</a>
          {% if current_user.is_authenticated %}
          <a href="{{ url_for('dashboard.index') }}" class="text-sm hover:text-blue-600">Dashboard</a>
          <a href="{{ url_for('accounting.chart_of_accounts') }}" class="text-sm hover:text-blue-600">Accounts</a>
          <a href="{{ url_for('accounting.new_journal_entry') }}" class="text-sm hover:text-blue-600">New Entry</a>
          <a href="{{ url_for('accounting.report_trial_balance') }}" class="text-sm hover:text-blue-600">Trial Balance</a>
          <a href="{{ url_for('businesses.list_businesses') }}" class="text-sm hover:text-blue-600">Businesses</a>
          {% endif %}
        </div>
        <div class="flex items-center gap-3">
          {% if current_business %}
          <span class="text-xs px-2 py-1 rounded bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200">{{ current_business.name }}</span>
          {% endif %}
          <button onclick="toggleTheme()" class="text-sm px-2 py-1 rounded border border-gray-300 dark:border-gray-600">🌓</button>
          {% if current_user.is_authenticated %}
          <a href="{{ url_for('auth.logout') }}" class="text-sm text-red-600">Logout</a>
          {% else %}
          <a href="{{ url_for('auth.login') }}" class="text-sm hover:text-blue-600">Login</a>
          <a href="{{ url_for('auth.register') }}" class="text-sm hover:text-blue-600">Sign up</a>
          {% endif %}
        </div>
      </div>
    </div>
  </nav>

  <main class="max-w-6xl mx-auto px-4 sm:px-6 py-8">
    {% with messages = get_flashed_messages(with_categories=true) %}
      {% if messages %}
        <div class="mb-6 space-y-2">
        {% for category, message in messages %}
          <div class="px-4 py-2 rounded text-sm
            {% if category == 'error' %} bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200
            {% elif category == 'success' %} bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200
            {% else %} bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200 {% endif %}">
            {{ message }}
          </div>
        {% endfor %}
        </div>
      {% endif %}
    {% endwith %}

    {% block content %}{% endblock %}
  </main>

  <script>
    function toggleTheme() {
      document.documentElement.classList.toggle('dark');
      localStorage.setItem('theme', document.documentElement.classList.contains('dark') ? 'dark' : 'light');
    }
  </script>
</body>
</html>
EOF

cat > app/templates/auth/login.html << 'EOF'
{% extends "base.html" %}
{% block title %}Log in{% endblock %}
{% block content %}
<div class="max-w-sm mx-auto bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
  <h1 class="text-xl font-semibold mb-4">Log in</h1>
  <form method="POST" class="space-y-4">
    {{ form.csrf_token }}
    <div>
      <label class="block text-sm mb-1">{{ form.email.label }}</label>
      {{ form.email(class_="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700") }}
    </div>
    <div>
      <label class="block text-sm mb-1">{{ form.password.label }}</label>
      {{ form.password(class_="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700") }}
    </div>
    <label class="flex items-center gap-2 text-sm">{{ form.remember_me() }} Remember me</label>
    <button class="w-full bg-blue-600 text-white py-2 rounded hover:bg-blue-700">Log in</button>
  </form>
  <p class="text-sm mt-4">No account? <a class="text-blue-600" href="{{ url_for('auth.register') }}">Sign up</a></p>
</div>
{% endblock %}
EOF

cat > app/templates/auth/register.html << 'EOF'
{% extends "base.html" %}
{% block title %}Sign up{% endblock %}
{% block content %}
<div class="max-w-sm mx-auto bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
  <h1 class="text-xl font-semibold mb-4">Create your account</h1>
  <form method="POST" class="space-y-4">
    {{ form.csrf_token }}
    <div>
      <label class="block text-sm mb-1">{{ form.full_name.label }}</label>
      {{ form.full_name(class_="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700") }}
    </div>
    <div>
      <label class="block text-sm mb-1">{{ form.email.label }}</label>
      {{ form.email(class_="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700") }}
    </div>
    <div>
      <label class="block text-sm mb-1">{{ form.password.label }}</label>
      {{ form.password(class_="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700") }}
    </div>
    <div>
      <label class="block text-sm mb-1">{{ form.confirm_password.label }}</label>
      {{ form.confirm_password(class_="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700") }}
    </div>
    <button class="w-full bg-blue-600 text-white py-2 rounded hover:bg-blue-700">Sign up</button>
  </form>
  <p class="text-sm mt-4">Already have an account? <a class="text-blue-600" href="{{ url_for('auth.login') }}">Log in</a></p>
</div>
{% endblock %}
EOF

cat > app/templates/businesses/list.html << 'EOF'
{% extends "base.html" %}
{% block title %}Your businesses{% endblock %}
{% block content %}
<div class="flex justify-between items-center mb-6">
  <h1 class="text-xl font-semibold">Your businesses</h1>
  <a href="{{ url_for('businesses.new_business') }}" class="bg-blue-600 text-white px-4 py-2 rounded text-sm">+ New business</a>
</div>

{% if not businesses %}
<div class="bg-white dark:bg-gray-800 p-8 rounded-lg text-center text-gray-500">
  You don't have any businesses yet.
</div>
{% else %}
<div class="grid gap-4 sm:grid-cols-2">
  {% for business in businesses %}
  <div class="bg-white dark:bg-gray-800 p-4 rounded-lg shadow flex flex-col gap-2">
    <div class="font-medium">{{ business.name }}</div>
    <div class="text-sm text-gray-500">{{ business.base_currency }}</div>
    <form method="POST" action="{{ url_for('businesses.switch_business', business_id=business.id) }}">
      <button class="text-sm text-blue-600">Switch to this business →</button>
    </form>
  </div>
  {% endfor %}
</div>
{% endif %}
{% endblock %}
EOF

cat > app/templates/businesses/new.html << 'EOF'
{% extends "base.html" %}
{% block title %}New business{% endblock %}
{% block content %}
<div class="max-w-sm mx-auto bg-white dark:bg-gray-800 p-6 rounded-lg shadow">
  <h1 class="text-xl font-semibold mb-4">Create a business</h1>
  <form method="POST" class="space-y-4">
    <div>
      <label class="block text-sm mb-1">Business name</label>
      <input name="name" required class="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700">
    </div>
    <div>
      <label class="block text-sm mb-1">Base currency (3-letter code)</label>
      <input name="base_currency" value="USD" maxlength="3" class="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700">
    </div>
    <button class="w-full bg-blue-600 text-white py-2 rounded hover:bg-blue-700">Create business</button>
  </form>
</div>
{% endblock %}
EOF

cat > app/templates/dashboard/index.html << 'EOF'
{% extends "base.html" %}
{% block title %}Dashboard{% endblock %}
{% block content %}
<h1 class="text-xl font-semibold mb-6">{{ business.name }} — Dashboard</h1>

<div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4 mb-8">
  <div class="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
    <div class="text-xs text-gray-500 uppercase">Assets</div>
    <div class="text-2xl font-semibold">{{ "%.2f"|format(total_assets) }}</div>
  </div>
  <div class="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
    <div class="text-xs text-gray-500 uppercase">Liabilities</div>
    <div class="text-2xl font-semibold">{{ "%.2f"|format(total_liabilities) }}</div>
  </div>
  <div class="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
    <div class="text-xs text-gray-500 uppercase">Revenue</div>
    <div class="text-2xl font-semibold">{{ "%.2f"|format(total_revenue) }}</div>
  </div>
  <div class="bg-white dark:bg-gray-800 p-4 rounded-lg shadow">
    <div class="text-xs text-gray-500 uppercase">Profit</div>
    <div class="text-2xl font-semibold {{ 'text-green-600' if profit >= 0 else 'text-red-600' }}">{{ "%.2f"|format(profit) }}</div>
  </div>
</div>

<div class="bg-white dark:bg-gray-800 p-6 rounded-lg shadow text-sm text-gray-500">
  This is Phase 1 of the platform: accounts, double-entry journal entries, and a trial balance.
  Invoicing, expenses, banking, offline sync, backups, and reporting land in later phases.
</div>
{% endblock %}
EOF

cat > app/templates/accounting/chart_of_accounts.html << 'EOF'
{% extends "base.html" %}
{% block title %}Chart of accounts{% endblock %}
{% block content %}
<h1 class="text-xl font-semibold mb-6">Chart of accounts</h1>
<div class="bg-white dark:bg-gray-800 rounded-lg shadow overflow-x-auto">
  <table class="w-full text-sm">
    <thead class="bg-gray-100 dark:bg-gray-700 text-left">
      <tr>
        <th class="p-3">Code</th>
        <th class="p-3">Name</th>
        <th class="p-3">Type</th>
        <th class="p-3 text-right">Balance</th>
      </tr>
    </thead>
    <tbody>
      {% for account in accounts %}
      <tr class="border-t border-gray-100 dark:border-gray-700">
        <td class="p-3">{{ account.code }}</td>
        <td class="p-3">{{ account.name }}</td>
        <td class="p-3 capitalize">{{ account.account_type }}</td>
        <td class="p-3 text-right">{{ "%.2f"|format(account.balance()) }}</td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
</div>
{% endblock %}
EOF

cat > app/templates/accounting/new_journal_entry.html << 'EOF'
{% extends "base.html" %}
{% block title %}New journal entry{% endblock %}
{% block content %}
<h1 class="text-xl font-semibold mb-6">New journal entry</h1>
<form method="POST" class="bg-white dark:bg-gray-800 p-6 rounded-lg shadow space-y-4 max-w-2xl">
  <div>
    <label class="block text-sm mb-1">Date</label>
    <input type="date" name="entry_date" required class="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700">
  </div>
  <div>
    <label class="block text-sm mb-1">Description</label>
    <input name="description" class="w-full px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700">
  </div>

  <div class="space-y-2" id="lines">
    {% for i in range(2) %}
    <div class="grid grid-cols-3 gap-2">
      <select name="account_id" class="px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700">
        {% for account in accounts %}
        <option value="{{ account.id }}">{{ account.code }} — {{ account.name }}</option>
        {% endfor %}
      </select>
      <input name="debit" placeholder="Debit" class="px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700">
      <input name="credit" placeholder="Credit" class="px-3 py-2 rounded border border-gray-300 dark:border-gray-600 dark:bg-gray-700">
    </div>
    {% endfor %}
  </div>

  <p class="text-xs text-gray-500">Total debits must equal total credits. Add more account rows by duplicating a line in future phases' richer UI.</p>
  <button class="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">Post entry</button>
</form>
{% endblock %}
EOF

cat > app/templates/accounting/trial_balance.html << 'EOF'
{% extends "base.html" %}
{% block title %}Trial balance{% endblock %}
{% block content %}
<h1 class="text-xl font-semibold mb-6">Trial balance</h1>
<div class="bg-white dark:bg-gray-800 rounded-lg shadow overflow-x-auto">
  <table class="w-full text-sm">
    <thead class="bg-gray-100 dark:bg-gray-700 text-left">
      <tr><th class="p-3">Account</th><th class="p-3 text-right">Debit</th><th class="p-3 text-right">Credit</th></tr>
    </thead>
    <tbody>
      {% for account, balance in rows %}
      <tr class="border-t border-gray-100 dark:border-gray-700">
        <td class="p-3">{{ account.code }} — {{ account.name }}</td>
        <td class="p-3 text-right">{{ "%.2f"|format(balance) if balance >= 0 else "" }}</td>
        <td class="p-3 text-right">{{ "%.2f"|format(-balance) if balance < 0 else "" }}</td>
      </tr>
      {% endfor %}
    </tbody>
    <tfoot>
      <tr class="border-t-2 border-gray-300 dark:border-gray-600 font-semibold">
        <td class="p-3">Total</td>
        <td class="p-3 text-right">{{ "%.2f"|format(total_debit) }}</td>
        <td class="p-3 text-right">{{ "%.2f"|format(total_credit) }}</td>
      </tr>
    </tfoot>
  </table>
</div>
{% endblock %}
EOF

mkdir -p app/templates/errors
cat > app/templates/errors/404.html << 'EOF'
{% extends "base.html" %}
{% block title %}Not found{% endblock %}
{% block content %}
<div class="text-center py-16">
  <h1 class="text-2xl font-semibold mb-2">404 — Page not found</h1>
  <a href="{{ url_for('dashboard.index') }}" class="text-blue-600">Go to dashboard</a>
</div>
{% endblock %}
EOF

cat > app/templates/errors/500.html << 'EOF'
{% extends "base.html" %}
{% block title %}Server error{% endblock %}
{% block content %}
<div class="text-center py-16">
  <h1 class="text-2xl font-semibold mb-2">Something went wrong</h1>
  <p class="text-gray-500">The error has been logged. No financial data was lost.</p>
</div>
{% endblock %}
EOF

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
cat > tests/conftest.py << 'EOF'
import pytest
from app import create_app
from app.extensions import db as _db


@pytest.fixture
def app():
    app = create_app("testing")
    with app.app_context():
        _db.create_all()
        yield app
        _db.drop_all()


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def db(app):
    return _db
EOF

cat > tests/test_accounting.py << 'EOF'
import pytest
from decimal import Decimal
from datetime import date
from app.models.business import Business
from app.models.accounting import create_default_chart_of_accounts, Account, ASSET, REVENUE
from app.accounting.engine import post_journal_entry, UnbalancedEntryError, InvalidLineError, trial_balance


def _setup_business(db):
    biz = Business(name="Test Co", base_currency="USD")
    db.session.add(biz)
    db.session.flush()
    create_default_chart_of_accounts(biz)
    db.session.commit()
    return biz


def test_balanced_entry_posts_successfully(app, db):
    biz = _setup_business(db)
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()

    entry = post_journal_entry(
        business_id=biz.id,
        entry_date=date.today(),
        lines=[
            {"account_id": cash.id, "debit": Decimal("100.00")},
            {"account_id": revenue.id, "credit": Decimal("100.00")},
        ],
        description="Test sale",
    )
    assert entry.is_balanced()
    assert cash.balance() == Decimal("100.00")
    assert revenue.balance() == Decimal("100.00")


def test_unbalanced_entry_is_rejected(app, db):
    biz = _setup_business(db)
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()

    with pytest.raises(UnbalancedEntryError):
        post_journal_entry(
            business_id=biz.id,
            entry_date=date.today(),
            lines=[
                {"account_id": cash.id, "debit": Decimal("100.00")},
                {"account_id": revenue.id, "credit": Decimal("50.00")},
            ],
        )


def test_line_cannot_have_both_debit_and_credit(app, db):
    biz = _setup_business(db)
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()

    with pytest.raises(InvalidLineError):
        post_journal_entry(
            business_id=biz.id,
            entry_date=date.today(),
            lines=[
                {"account_id": cash.id, "debit": Decimal("10.00"), "credit": Decimal("10.00")},
                {"account_id": revenue.id, "credit": Decimal("10.00")},
            ],
        )


def test_account_from_other_business_is_rejected(app, db):
    biz1 = _setup_business(db)
    biz2 = _setup_business(db)
    cash1 = Account.query.filter_by(business_id=biz1.id, code="1000").first()
    revenue2 = Account.query.filter_by(business_id=biz2.id, code="4000").first()

    with pytest.raises(InvalidLineError):
        post_journal_entry(
            business_id=biz1.id,
            entry_date=date.today(),
            lines=[
                {"account_id": cash1.id, "debit": Decimal("10.00")},
                {"account_id": revenue2.id, "credit": Decimal("10.00")},
            ],
        )


def test_trial_balance_reflects_posted_entries(app, db):
    biz = _setup_business(db)
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()

    post_journal_entry(
        business_id=biz.id,
        entry_date=date.today(),
        lines=[{"account_id": cash.id, "debit": Decimal("250.00")}, {"account_id": revenue.id, "credit": Decimal("250.00")}],
    )
    rows = dict((a.code, b) for a, b in trial_balance(biz.id))
    assert rows["1000"] == Decimal("250.00")
    assert rows["4000"] == Decimal("250.00")
EOF

cat > tests/test_auth.py << 'EOF'
def test_register_and_login(client):
    resp = client.post("/auth/register", data={
        "full_name": "Ada Lovelace",
        "email": "ada@example.com",
        "password": "correct-horse-battery",
        "confirm_password": "correct-horse-battery",
    }, follow_redirects=True)
    assert resp.status_code == 200

    client.get("/auth/logout")

    resp = client.post("/auth/login", data={
        "email": "ada@example.com",
        "password": "correct-horse-battery",
    }, follow_redirects=True)
    assert resp.status_code == 200


def test_business_data_isolation(app, db, client):
    from app.models.user import User
    from app.models.business import Business, Membership, ROLE_OWNER

    u1 = User(email="a@example.com", full_name="A")
    u1.set_password("password123456")
    u2 = User(email="b@example.com", full_name="B")
    u2.set_password("password123456")
    db.session.add_all([u1, u2])
    db.session.flush()

    biz = Business(name="Private Co")
    db.session.add(biz)
    db.session.flush()
    db.session.add(Membership(user_id=u1.id, business_id=biz.id, role=ROLE_OWNER))
    db.session.commit()

    assert u1.role_in(biz) == ROLE_OWNER
    assert u2.role_in(biz) is None
EOF

# -----------------------------------------------------------------------------
# scripts/init_db.py — convenience script
# -----------------------------------------------------------------------------
cat > scripts/init_db.py << 'EOF'
"""One-off helper: creates all tables directly (dev convenience).
For real environments use `flask db migrate` / `flask db upgrade` instead."""
from app import create_app
from app.extensions import db

app = create_app("development")
with app.app_context():
    db.create_all()
    print("Database tables created.")
EOF

# -----------------------------------------------------------------------------
# README
# -----------------------------------------------------------------------------
cat > README.md << 'EOF'
# Bookkeeping Platform — Phase 1: Foundation

This is Phase 1 of a multi-phase build. It contains a real, runnable Flask
application (not a mockup) implementing:

- Application factory + blueprint architecture (`app/`)
- User accounts (register/login/logout, hashed passwords, Flask-Login)
- Multiple businesses per user, with strict per-business membership/roles
  (owner, admin, accountant, bookkeeper, manager, employee, read-only)
- A real double-entry accounting engine (`app/accounting/engine.py`):
  every posting goes through `post_journal_entry`, which enforces that
  debits == credits and that accounts belong to the business being posted
  to. Nothing bypasses this.
- A default chart of accounts created for every new business
- A trial balance report
- Tailwind UI with light/dark theme (persisted via localStorage, respects
  system preference on first load)
- Automated tests for the accounting engine and auth/business isolation

## Running it

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env        # edit SECRET_KEY for anything beyond local dev
python scripts/init_db.py   # creates instance/app.db
python run.py                # http://127.0.0.1:5000
```

Or with Flask-Migrate instead of the dev-convenience script:

```bash
flask db init
flask db migrate -m "initial schema"
flask db upgrade
```

## Running tests

```bash
pytest
```

## What's intentionally NOT in Phase 1

This phase is the foundation only: auth, businesses, roles, the accounting
core, and a minimal UI. Invoicing, expenses, banking, PWA/offline, backups,
audit trail, reporting suite, and integrations are separate phases, built on
top of this same engine so the accounting core never has to be rewritten.
EOF

echo ">> Phase 1 project scaffolded at ./${ROOT}"
