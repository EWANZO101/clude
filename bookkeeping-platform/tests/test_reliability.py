from decimal import Decimal
from datetime import date
from app.extensions import db
from app.models.business import Business
from app.models.accounting import create_default_chart_of_accounts, Account, JournalEntry, JournalLine
from app.accounting.engine import post_journal_entry
from app.accounting.integrity import run_integrity_check
from app.models.audit import AuditLog
from app.models.backup import Backup


def _setup_business():
    biz = Business(name="Reliability Co", base_currency="USD")
    db.session.add(biz)
    db.session.flush()
    create_default_chart_of_accounts(biz)
    db.session.commit()
    return biz


def test_posting_journal_entry_writes_audit_log(app, db):
    biz = _setup_business()
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()

    entry = post_journal_entry(
        business_id=biz.id, entry_date=date.today(),
        lines=[{"account_id": cash.id, "debit": Decimal("10.00")}, {"account_id": revenue.id, "credit": Decimal("10.00")}],
        description="Test",
    )

    logs = AuditLog.query.filter_by(business_id=biz.id, entity_id=entry.id).all()
    assert len(logs) == 1
    assert logs[0].action == "journal_entry.posted"


def test_integrity_check_finds_no_issues_on_clean_ledger(app, db):
    biz = _setup_business()
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()
    post_journal_entry(
        business_id=biz.id, entry_date=date.today(),
        lines=[{"account_id": cash.id, "debit": Decimal("50.00")}, {"account_id": revenue.id, "credit": Decimal("50.00")}],
    )

    run = run_integrity_check(business_id=biz.id)
    assert run.issue_count == 0


def test_integrity_check_flags_entry_corrupted_outside_the_engine(app, db):
    """Simulates a direct DB edit bypassing the engine, to prove the
    self-audit catches drift that the engine's own guard can't see after
    the fact."""
    biz = _setup_business()
    cash = Account.query.filter_by(business_id=biz.id, code="1000").first()
    revenue = Account.query.filter_by(business_id=biz.id, code="4000").first()
    entry = post_journal_entry(
        business_id=biz.id, entry_date=date.today(),
        lines=[{"account_id": cash.id, "debit": Decimal("50.00")}, {"account_id": revenue.id, "credit": Decimal("50.00")}],
    )

    # Bypass the engine on purpose to simulate corruption/a bug elsewhere.
    line = JournalLine.query.filter_by(journal_entry_id=entry.id, account_id=cash.id).first()
    line.debit = Decimal("999.00")
    db.session.commit()

    run = run_integrity_check(business_id=biz.id)
    assert run.issue_count == 1
    assert run.issues[0].check_name == "unbalanced_journal_entry"


def test_backup_is_created_and_verified(tmp_path):
    # The backup service copies the actual SQLite *file*, so this test spins
    # up its own file-backed app rather than using the shared in-memory
    # testing fixture (which has no file for sqlite3.connect to back up).
    import os
    from app import create_app
    from app.extensions import db as _db

    db_path = tmp_path / "backup_test.db"
    os.environ["DATABASE_URL"] = f"sqlite:///{db_path}"
    os.environ["BACKUP_DIR"] = str(tmp_path / "backups")
    try:
        app = create_app("development")
        app.config["ENABLE_SCHEDULER"] = False
        with app.app_context():
            _db.create_all()
            biz = _setup_business()

            from app.backups.service import create_backup
            backup = create_backup(triggered_by="manual")
            assert backup.status == "success", backup.verification_error
            assert backup.checksum_sha256 is not None
            assert backup.size_bytes and backup.size_bytes > 0
    finally:
        os.environ.pop("DATABASE_URL", None)
        os.environ.pop("BACKUP_DIR", None)


def test_admin_dashboard_is_restricted(app, db, client):
    from app.models.user import User
    user = User(email="nonadmin@example.com", full_name="Regular User")
    user.set_password("password123456")
    db.session.add(user)
    db.session.commit()

    client.post("/auth/login", data={"email": "nonadmin@example.com", "password": "password123456"})
    resp = client.get("/admin/")
    assert resp.status_code == 403
