"""Finance core models. Monetary values are stored as integer minor units
(pence/cents) to avoid floating point errors — see app.py helpers to_minor/to_major.
"""
from datetime import datetime, date, timedelta
from app.extensions import db
from app.core.database.models import gen_uuid


class FinanceAccount(db.Model):
    __tablename__ = "finance_accounts"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    bank_connection_id = db.Column(db.String(36), db.ForeignKey("finance_bank_connections.id"), nullable=True)
    name = db.Column(db.String(120), nullable=False)
    account_type = db.Column(db.String(30), default="current")  # current, savings, credit_card
    institution_name = db.Column(db.String(120))
    account_number = db.Column(db.String(20))  # UK account number, from a connected provider or entered manually
    sort_code = db.Column(db.String(10))  # UK sort code, e.g. "04-00-04"
    currency = db.Column(db.String(10), default="GBP")
    balance_minor = db.Column(db.Integer, default=0)  # integer minor units, decimal-safe
    is_default = db.Column(db.Boolean, default=False)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    transactions = db.relationship("FinanceTransaction", backref="account", lazy="dynamic",
                                    cascade="all, delete-orphan")
    bank_connection = db.relationship("FinanceBankConnection", backref="accounts")


class FinanceBankConnection(db.Model):
    __tablename__ = "finance_bank_connections"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    provider = db.Column(db.String(40), nullable=False)  # monzo, starling, ...
    provider_account_id = db.Column(db.String(120))
    access_token_encrypted = db.Column(db.Text)  # encrypted at rest; never store raw bank passwords
    refresh_token_encrypted = db.Column(db.Text)
    status = db.Column(db.String(20), default="connected")  # connected, expired, error, disconnected
    last_synced_at = db.Column(db.DateTime)
    last_error = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class FinanceCategory(db.Model):
    __tablename__ = "finance_categories"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=True, index=True)  # null = system default
    name = db.Column(db.String(80), nullable=False)
    parent_id = db.Column(db.Integer, db.ForeignKey("finance_categories.id"), nullable=True)
    icon = db.Column(db.String(40))
    is_essential = db.Column(db.Boolean, default=False)

    subcategories = db.relationship("FinanceCategory", backref=db.backref("parent", remote_side=[id]))


class FinanceCategoryRule(db.Model):
    """User-defined or learned rule: description contains X -> category Y."""
    __tablename__ = "finance_category_rules"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    match_text = db.Column(db.String(200), nullable=False)
    category_id = db.Column(db.Integer, db.ForeignKey("finance_categories.id"), nullable=False)
    created_from_correction = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class FinanceTransaction(db.Model):
    __tablename__ = "finance_transactions"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    account_id = db.Column(db.String(36), db.ForeignKey("finance_accounts.id"), nullable=False, index=True)

    date = db.Column(db.Date, nullable=False, index=True)
    merchant_name = db.Column(db.String(200))
    raw_description = db.Column(db.String(400))
    clean_description = db.Column(db.String(400))
    amount_minor = db.Column(db.Integer, nullable=False)  # positive=credit, negative=debit, integer minor units
    currency = db.Column(db.String(10), default="GBP")

    category_id = db.Column(db.Integer, db.ForeignKey("finance_categories.id"), nullable=True)
    tags = db.Column(db.String(300))  # comma-separated for simplicity
    notes = db.Column(db.Text)
    location = db.Column(db.String(200))

    direction = db.Column(db.String(10))  # debit, credit
    txn_type = db.Column(db.String(20), default="spending")  # spending, income, transfer, refund, cash_withdrawal, cash_deposit
    status = db.Column(db.String(20), default="completed")  # pending, completed
    recurring = db.Column(db.Boolean, default=False)
    ignored = db.Column(db.Boolean, default=False)
    reviewed = db.Column(db.Boolean, default=False)

    import_source = db.Column(db.String(40))  # csv, ofx, qfx, manual, bank_sync
    import_batch_id = db.Column(db.String(36))
    external_transaction_id = db.Column(db.String(200), index=True)  # for duplicate detection
    dedupe_hash = db.Column(db.String(64), index=True)  # fallback duplicate key when no external id

    parent_transaction_id = db.Column(db.String(36), db.ForeignKey("finance_transactions.id"), nullable=True)  # for splits

    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    splits = db.relationship("FinanceTransaction", backref=db.backref("parent", remote_side=[id]))


class FinanceImportBatch(db.Model):
    __tablename__ = "finance_import_batches"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    account_id = db.Column(db.String(36), db.ForeignKey("finance_accounts.id"), nullable=False)
    filename = db.Column(db.String(255))
    file_format = db.Column(db.String(10))  # csv, ofx, qfx
    row_count = db.Column(db.Integer, default=0)
    imported_count = db.Column(db.Integer, default=0)
    duplicate_count = db.Column(db.Integer, default=0)
    status = db.Column(db.String(20), default="pending")  # pending, confirmed
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


# ---- Part 6: extended finance models ----

class FinanceSettings(db.Model):
    __tablename__ = "finance_settings"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, unique=True, index=True)
    default_account_id = db.Column(db.String(36), db.ForeignKey("finance_accounts.id"), nullable=True)
    minimum_safe_balance_minor = db.Column(db.Integer, default=0)
    monthly_savings_target_minor = db.Column(db.Integer, default=0)
    annual_savings_target_minor = db.Column(db.Integer, default=0)
    emergency_fund_target_minor = db.Column(db.Integer, default=0)


class FinanceBudget(db.Model):
    __tablename__ = "finance_budgets"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    category_id = db.Column(db.Integer, db.ForeignKey("finance_categories.id"), nullable=False)
    amount_minor = db.Column(db.Integer, nullable=False)
    period = db.Column(db.String(10), default="monthly")  # monthly (only period supported for now)
    warning_threshold_pct = db.Column(db.Integer, default=80)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    category = db.relationship("FinanceCategory")

    __table_args__ = (db.UniqueConstraint("user_id", "category_id", name="uq_budget_user_category"),)


class FinanceBill(db.Model):
    __tablename__ = "finance_bills"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(200), nullable=False)
    amount_minor = db.Column(db.Integer, nullable=False)
    category_id = db.Column(db.Integer, db.ForeignKey("finance_categories.id"), nullable=True)
    due_day = db.Column(db.Integer)  # day-of-month, 1-28 kept safe across months
    frequency = db.Column(db.String(20), default="monthly")  # monthly, weekly, annual
    next_due_date = db.Column(db.Date)
    active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    category = db.relationship("FinanceCategory")


class FinanceSubscription(db.Model):
    __tablename__ = "finance_subscriptions"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(200), nullable=False)
    amount_minor = db.Column(db.Integer, nullable=False)
    frequency = db.Column(db.String(20), default="monthly")  # monthly, annual
    category_id = db.Column(db.Integer, db.ForeignKey("finance_categories.id"), nullable=True)
    last_payment_date = db.Column(db.Date)
    next_payment_date = db.Column(db.Date)
    status = db.Column(db.String(20), default="active")  # active, cancelled
    detected_automatically = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    category = db.relationship("FinanceCategory")

    @property
    def monthly_cost_minor(self):
        return self.amount_minor if self.frequency == "monthly" else round(self.amount_minor / 12)

    @property
    def annual_cost_minor(self):
        return self.amount_minor * 12 if self.frequency == "monthly" else self.amount_minor


class FinanceRecurringPayment(db.Model):
    __tablename__ = "finance_recurring_payments"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    merchant_key = db.Column(db.String(200), nullable=False)  # normalised description used for detection
    display_name = db.Column(db.String(200))
    amount_minor = db.Column(db.Integer, nullable=False)
    frequency = db.Column(db.String(20), default="monthly")
    last_payment_date = db.Column(db.Date)
    next_payment_date = db.Column(db.Date)
    category_id = db.Column(db.Integer, db.ForeignKey("finance_categories.id"), nullable=True)
    status = db.Column(db.String(20), default="detected")  # detected, confirmed, ignored, cancelled
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    category = db.relationship("FinanceCategory")

    __table_args__ = (db.UniqueConstraint("user_id", "merchant_key", "amount_minor", name="uq_recurring_user_key_amount"),)


class FinanceMonthlyPlanItem(db.Model):
    """A one-off spend planned for a specific month -- 'I\'m thinking of
    spending X on Y this month'. Distinct from FinancePlannedPurchase
    (an open-ended wishlist with no month attached) and from FinanceBill
    (a recurring commitment): this is scoped to one calendar month and is
    meant to be worked through -- see calculations.monthly_plan_impact()."""
    __tablename__ = "finance_monthly_plan_items"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    month = db.Column(db.Date, nullable=False, index=True)  # always the 1st of the target month
    name = db.Column(db.String(200), nullable=False)
    amount_minor = db.Column(db.Integer, nullable=False)
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class FinancePlannedPurchase(db.Model):
    __tablename__ = "finance_planned_purchases"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(200), nullable=False)
    price_minor = db.Column(db.Integer, nullable=False)
    quantity = db.Column(db.Integer, default=1)
    url = db.Column(db.String(500))
    category_id = db.Column(db.Integer, db.ForeignKey("finance_categories.id"), nullable=True)
    priority = db.Column(db.String(10), default="medium")  # low, medium, high
    desired_date = db.Column(db.Date, nullable=True)
    notes = db.Column(db.Text)
    purchased = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    category = db.relationship("FinanceCategory")

    @property
    def total_price_minor(self):
        return self.price_minor * (self.quantity or 1)


class FinanceSavingsGoal(db.Model):
    __tablename__ = "finance_savings_goals"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    name = db.Column(db.String(200), nullable=False)
    target_minor = db.Column(db.Integer, nullable=False)
    current_minor = db.Column(db.Integer, default=0)
    target_date = db.Column(db.Date, nullable=True)
    monthly_contribution_minor = db.Column(db.Integer, default=0)
    account_id = db.Column(db.String(36), db.ForeignKey("finance_accounts.id"), nullable=True)
    achieved = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @property
    def progress_pct(self):
        if not self.target_minor:
            return 0
        return min(100, round(self.current_minor / self.target_minor * 100))


class FinanceDebt(db.Model):
    """Money owed to a company under a payment plan -- credit cards, store
    finance, catalogue debt, a payment plan with a utility company, etc.
    remaining_minor is the number that matters day to day; original_minor is
    just for reference. monthly_payment_minor feeds into
    calculations.safe_discretionary_money() the same way a bill does, so
    'how much I have left' already accounts for it."""
    __tablename__ = "finance_debts"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    user_id = db.Column(db.String(36), db.ForeignKey("users.id"), nullable=False, index=True)
    creditor_name = db.Column(db.String(200), nullable=False)
    original_minor = db.Column(db.Integer, nullable=True)
    remaining_minor = db.Column(db.Integer, nullable=False)
    monthly_payment_minor = db.Column(db.Integer, nullable=False)
    frequency = db.Column(db.String(20), default="monthly")
    next_payment_date = db.Column(db.Date, nullable=True)
    notes = db.Column(db.Text)
    settled = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @property
    def has_custom_schedule(self):
        return len(self.scheduled_payments) > 0

    @property
    def unpaid_scheduled_payments(self):
        return sorted(
            (p for p in self.scheduled_payments if not p.paid),
            key=lambda p: p.due_date,
        )

    @property
    def next_scheduled_payment(self):
        unpaid = self.unpaid_scheduled_payments
        return unpaid[0] if unpaid else None

    @property
    def monthly_equivalent_minor(self):
        if self.has_custom_schedule:
            # Custom schedules can be irregular, so approximate the monthly
            # contribution as whatever's due in the next 30 days.
            horizon = date.today() + timedelta(days=30)
            return sum(
                p.amount_minor for p in self.unpaid_scheduled_payments
                if p.due_date <= horizon
            )
        if self.frequency == "weekly":
            return round(self.monthly_payment_minor * 52 / 12)
        if self.frequency == "fortnightly":
            return round(self.monthly_payment_minor * 26 / 12)
        if self.frequency == "variable":
            return 0
        return self.monthly_payment_minor

    @property
    def payments_remaining(self):
        if self.has_custom_schedule:
            return len(self.unpaid_scheduled_payments)
        if not self.monthly_payment_minor or self.remaining_minor <= 0:
            return 0
        return -(-self.remaining_minor // self.monthly_payment_minor)


class FinanceDebtPayment(db.Model):
    """One entry in a debt's custom payment schedule -- lets a debt be paid
    off across any number of payments, each with its own due date and its
    own amount, instead of being locked to one fixed recurring amount."""
    __tablename__ = "finance_debt_payments"
    id = db.Column(db.String(36), primary_key=True, default=gen_uuid)
    debt_id = db.Column(db.String(36), db.ForeignKey("finance_debts.id"), nullable=False, index=True)
    due_date = db.Column(db.Date, nullable=False)
    amount_minor = db.Column(db.Integer, nullable=False)
    paid = db.Column(db.Boolean, default=False)
    paid_at = db.Column(db.DateTime, nullable=True)
    note = db.Column(db.String(200))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    debt = db.relationship(
        "FinanceDebt",
        backref=db.backref(
            "scheduled_payments",
            order_by="FinanceDebtPayment.due_date",
            cascade="all, delete-orphan",
        ),
    )
