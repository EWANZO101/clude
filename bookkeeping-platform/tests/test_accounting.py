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
