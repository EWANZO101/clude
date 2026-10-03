from datetime import datetime, date, timedelta
import os
import secrets

from dateutil.relativedelta import relativedelta
from flask import Blueprint, render_template, redirect, url_for, flash, request, session, current_app
from flask_login import login_required, current_user

from app.extensions import db
from app.core.events.bus import emit, on
from app.core.storage.service import save_upload, file_path
from app.core.export.registry import register_exporter

from .models import FinanceAccount, FinanceTransaction, FinanceCategory, FinanceImportBatch
from .models import FinanceBankConnection
from .models import (
    FinanceBudget, FinanceBill, FinanceSubscription, FinanceRecurringPayment,
    FinancePlannedPurchase, FinanceSavingsGoal, FinanceSettings, FinanceMonthlyPlanItem,
    FinanceDebt, FinanceDebtPayment,
)
from .money import to_minor, to_major, format_money
from .csv_import import parse_csv_preview
from .dedupe import find_and_remove_duplicates
from .categorize import ensure_default_categories, suggest_category, remember_correction
from . import calculations as calc
from .crypto import encrypt_token, decrypt_token
from .providers.monzo import get_provider as get_monzo_provider
from .providers.base import BankProviderError

bp = Blueprint("finance", __name__, url_prefix="/finance", template_folder="templates")


def _ensure_schema():
    """Adds columns introduced after the module's initial db.create_all()
    run — SQLAlchemy's create_all() only creates missing tables, never
    alters existing ones, so an already-deployed finance_accounts table
    needs these added explicitly. SQLite only; other engines should use a
    real migration tool."""
    try:
        if not db.engine.url.get_backend_name().startswith("sqlite"):
            return
        with db.engine.connect() as conn:
            from sqlalchemy import text
            cols = [row[1] for row in conn.execute(text("PRAGMA table_info(finance_accounts)"))]
            if "account_number" not in cols:
                conn.execute(text("ALTER TABLE finance_accounts ADD COLUMN account_number VARCHAR(20)"))
            if "sort_code" not in cols:
                conn.execute(text("ALTER TABLE finance_accounts ADD COLUMN sort_code VARCHAR(10)"))
            conn.commit()
    except Exception:
        pass


_ensure_schema()


@bp.before_request
def _ensure_categories():
    if current_user.is_authenticated:
        ensure_default_categories(current_user.id)


@bp.app_template_filter("money")
def money_filter(amount_minor, currency="GBP"):
    return format_money(amount_minor or 0, currency)


@bp.app_context_processor
def inject_credit_card_balance():
    """Total owed across active credit-card accounts, shown in the sidebar on
    /finance pages. Card balances get entered as either positive or negative
    depending on the person, so the magnitude is what's displayed as 'owed'."""
    if not (current_user.is_authenticated and request.path.startswith("/finance")):
        return {}
    try:
        cards = FinanceAccount.query.filter_by(
            user_id=current_user.id, account_type="credit_card", active=True
        ).all()
    except Exception:
        return {}
    return {"credit_card_sidebar": {
        "count": len(cards),
        "owed_minor": abs(sum(c.balance_minor or 0 for c in cards)),
        "currency": cards[0].currency if cards else "GBP",
    }}


@bp.route("/")
@login_required
def index():
    accounts = FinanceAccount.query.filter_by(user_id=current_user.id, active=True).all()
    total_balance = sum(a.balance_minor for a in accounts)
    recent = FinanceTransaction.query.filter_by(user_id=current_user.id, ignored=False).order_by(
        FinanceTransaction.date.desc()
    ).limit(10).all()

    budgets = FinanceBudget.query.filter_by(user_id=current_user.id).all()
    budget_rows = [(b, calc.budget_status(current_user.id, b)) for b in budgets]

    today = date.today()
    horizon = today + relativedelta(days=14)
    upcoming_bills = FinanceBill.query.filter(
        FinanceBill.user_id == current_user.id, FinanceBill.active == True,  # noqa: E712
        FinanceBill.next_due_date.isnot(None), FinanceBill.next_due_date <= horizon,
    ).order_by(FinanceBill.next_due_date).all()

    forecast = calc.financial_forecast(current_user.id)
    safe_balance = calc.safe_discretionary_money(current_user.id)

    return render_template("finance/index.html", accounts=accounts, total_balance=total_balance,
                            recent=recent, budget_rows=budget_rows, upcoming_bills=upcoming_bills,
                            forecast=forecast, safe_balance=safe_balance)


# ---- Accounts ----

def _import_monzo_transactions(user_id, account, provider, access_token, provider_account_id, since=None):
    """Pulls transactions from Monzo and creates any not already imported,
    using Monzo's own transaction id for dedup (external_transaction_id) —
    far more reliable than the hash-based dedup CSV import needs, since
    Monzo's ids are stable and unique. Only creates transaction rows; the
    account's own balance is set separately from get_balance. Returns the
    count actually created."""
    remote_transactions = provider.list_transactions(access_token, provider_account_id, since=since)
    if not remote_transactions:
        return 0

    existing_ids = {
        t for (t,) in db.session.query(FinanceTransaction.external_transaction_id).filter_by(
            user_id=user_id, account_id=account.id,
        ).filter(FinanceTransaction.external_transaction_id.isnot(None)).all()
    }

    created = 0
    for rt in remote_transactions:
        if rt["external_transaction_id"] in existing_ids:
            continue

        category_id = suggest_category(user_id, rt["description"])
        txn = FinanceTransaction(
            user_id=user_id, account_id=account.id,
            date=datetime.strptime(rt["date"], "%Y-%m-%d").date(),
            merchant_name=rt["description"], raw_description=rt["raw_description"],
            clean_description=rt["description"],
            amount_minor=rt["amount_minor"], currency=rt.get("currency", account.currency),
            direction="credit" if rt["amount_minor"] >= 0 else "debit",
            category_id=category_id,
            import_source="bank_sync",
            external_transaction_id=rt["external_transaction_id"],
        )
        db.session.add(txn)
        created += 1

    if created:
        emit("transactions.changed", user_id=user_id, source="bank_sync", count=created)

    return created


def _pull_monzo_accounts(connection, access_token):
    """Fetches the account list + balances from Monzo for an already-authorised
    connection and creates/updates FinanceAccount rows. Shared by the OAuth
    callback (first attempt, right after consent) and the manual 'Fetch
    accounts' action (used once the person has approved the in-app push,
    since the callback's first attempt commonly hits SCA and gets nothing).
    Returns the number of newly created accounts. Raises BankProviderError
    if Monzo itself rejects the call (e.g. still not approved)."""
    provider = get_monzo_provider("monzo")
    remote_accounts = provider.list_accounts(access_token)

    created = 0
    for ra in remote_accounts:
        existing = FinanceAccount.query.filter_by(
            user_id=current_user.id, bank_connection_id=connection.id,
        ).filter(FinanceAccount.name == ra["name"]).first()
        if existing:
            account = existing
        else:
            is_default = FinanceAccount.query.filter_by(user_id=current_user.id).count() == 0
            account = FinanceAccount(
                user_id=current_user.id, bank_connection_id=connection.id,
                name=ra["name"], account_type=ra["account_type"],
                institution_name="Monzo", currency=ra.get("currency", "GBP"),
                is_default=is_default,
            )
            db.session.add(account)
            created += 1

        account.account_number = ra.get("account_number") or account.account_number
        account.sort_code = ra.get("sort_code") or account.sort_code

        try:
            balance = provider.get_balance(access_token, ra["provider_account_id"])
            account.balance_minor = balance["balance_minor"]
        except BankProviderError:
            pass  # account created; balance sync can happen later via "Sync now"

        try:
            _import_monzo_transactions(current_user.id, account, provider, access_token, ra["provider_account_id"])
        except BankProviderError:
            pass  # transactions can be pulled in later via "Sync now"

    return created


@bp.route("/accounts")
@login_required
def accounts():
    accounts = FinanceAccount.query.filter_by(user_id=current_user.id).order_by(FinanceAccount.name).all()
    # A Monzo connection can exist with zero linked accounts — this happens
    # whenever the initial OAuth callback ran before SCA approval finished.
    # Surface those so there's always a visible way to finish the connection.
    linked_connection_ids = {a.bank_connection_id for a in accounts if a.bank_connection_id}
    pending_connections = FinanceBankConnection.query.filter(
        FinanceBankConnection.user_id == current_user.id,
        FinanceBankConnection.status != "disconnected",
        ~FinanceBankConnection.id.in_(linked_connection_ids) if linked_connection_ids else True,
    ).all()
    return render_template("finance/accounts.html", accounts=accounts, pending_connections=pending_connections)


@bp.route("/accounts/connections/<connection_id>/fetch", methods=["POST"])
@login_required
def fetch_connection_accounts(connection_id):
    connection = FinanceBankConnection.query.filter_by(
        id=connection_id, user_id=current_user.id, provider="monzo",
    ).first_or_404()
    access_token = decrypt_token(connection.access_token_encrypted)

    try:
        created = _pull_monzo_accounts(connection, access_token)
    except BankProviderError as e:
        connection.last_error = str(e)
        db.session.commit()
        flash(f"Still couldn't fetch accounts: {e}. Make sure you approved the request in the Monzo app.", "error")
        return redirect(url_for("finance.accounts"))

    connection.status = "connected"
    connection.last_synced_at = datetime.utcnow()
    connection.last_error = None
    db.session.commit()

    if created:
        flash(f"Fetched {created} account(s) from Monzo.", "success")
    else:
        flash("Connected to Monzo, but it didn't return any accounts to add.", "warning")
    return redirect(url_for("finance.accounts"))


def _bank_list(monzo_provider):
    return [
        {"key": "monzo", "name": "Monzo", "connectable": monzo_provider.is_configured()},
        {"key": "starling", "name": "Starling Bank", "connectable": False},
        {"key": "barclays", "name": "Barclays", "connectable": False},
        {"key": "hsbc", "name": "HSBC", "connectable": False},
        {"key": "lloyds", "name": "Lloyds", "connectable": False},
        {"key": "natwest", "name": "NatWest", "connectable": False},
        {"key": "nationwide", "name": "Nationwide", "connectable": False},
        {"key": "santander", "name": "Santander", "connectable": False},
        {"key": "halifax", "name": "Halifax", "connectable": False},
        {"key": "tsb", "name": "TSB", "connectable": False},
    ]


# ---- Setup guide ----
# Per-bank info for the "where do I get this" page. `kind` drives which
# template block renders:
#   "direct"      - this app has real OAuth code for it (Monzo only)
#   "aggregator"  - no UK bank hands out OAuth apps to random self-hosted
#                   projects one at a time; multi-bank access goes through
#                   an Open Banking aggregator instead, so there's no
#                   per-bank dev portal step to give.
BANK_SETUP_INFO = {
    "monzo": {
        "kind": "direct",
        "portal_name": "Monzo Developer Tools",
        "portal_url": "https://developers.monzo.com",
        "env_vars": ["MONZO_CLIENT_ID", "MONZO_CLIENT_SECRET"],
        "steps": [
            "Go to developers.monzo.com and sign in with the Monzo account you want to connect.",
            "Open the Monzo app on your phone — the site can't authorize you without it.",
            "Click \"Clients\" in the top nav, then \"New OAuth Client\".",
            "Name: anything (e.g. this app's name). Logo URL: optional, leave blank.",
            "Redirect URLs: paste the exact URL shown below.",
            "Confidentiality: choose \"Confidential\".",
            "Click Submit — you'll get a Client ID and Client Secret. Copy both immediately, the secret isn't shown again.",
            "Paste them into .env as MONZO_CLIENT_ID and MONZO_CLIENT_SECRET, then restart the app.",
        ],
        "note": "Monzo's API is restricted to your own account (or a short allow-list of accounts you add "
                "in the developer console) — it isn't approved for arbitrary public users.",
    },
    "starling": {"kind": "aggregator", "display_name": "Starling Bank"},
    "barclays": {"kind": "aggregator", "display_name": "Barclays"},
    "hsbc": {"kind": "aggregator", "display_name": "HSBC"},
    "lloyds": {"kind": "aggregator", "display_name": "Lloyds"},
    "natwest": {"kind": "aggregator", "display_name": "NatWest"},
    "nationwide": {"kind": "aggregator", "display_name": "Nationwide"},
    "santander": {"kind": "aggregator", "display_name": "Santander"},
    "halifax": {"kind": "aggregator", "display_name": "Halifax"},
    "tsb": {"kind": "aggregator", "display_name": "TSB"},
}

# Open Banking aggregators that cover all nine banks above through one
# integration — this is how apps normally reach banks that don't hand out
# individual developer credentials. None of this is wired into the app yet;
# it's here so the next integration doesn't start from zero.
OB_AGGREGATORS = [
    {"name": "GoCardless Bank Account Data", "url": "https://gocardless.com/bank-account-data/",
     "note": "Free tier for read-only account/transaction data (formerly Nordigen). Usually the cheapest way in."},
    {"name": "TrueLayer", "url": "https://truelayer.com", "note": "Paid, UK-focused, well documented."},
    {"name": "Yapily", "url": "https://www.yapily.com", "note": "Paid, UK/EU coverage."},
    {"name": "Plaid", "url": "https://plaid.com", "note": "Paid; UK coverage exists but its strength is US/EU."},
]


def _mask(value):
    """Show enough of a stored credential to confirm it's the right one,
    without displaying the whole thing back on screen."""
    if not value:
        return None
    if len(value) <= 8:
        return value[0] + "…" + value[-1]
    return value[:4] + "…" + value[-4:]


PLACEHOLDER_VALUES = {"YOUR_MONZO_CLIENT_ID", "YOUR_MONZO_CLIENT_SECRET", ""}


@bp.route("/accounts/setup-guide")
@login_required
def setup_guide():
    monzo = get_monzo_provider("monzo")
    banks = _bank_list(monzo)
    for bank in banks:
        bank["setup"] = BANK_SETUP_INFO.get(bank["key"], {})

    current_id = os.environ.get("MONZO_CLIENT_ID", "")
    current_secret = os.environ.get("MONZO_CLIENT_SECRET", "")
    monzo_saved = {
        "client_id_masked": _mask(current_id) if current_id not in PLACEHOLDER_VALUES else None,
        "client_secret_masked": _mask(current_secret) if current_secret not in PLACEHOLDER_VALUES else None,
        "is_placeholder": current_id in PLACEHOLDER_VALUES or current_secret in PLACEHOLDER_VALUES,
    }

    return render_template(
        "finance/setup_guide.html",
        banks=banks,
        redirect_uri=_oauth_redirect_uri(),
        aggregators=OB_AGGREGATORS,
        monzo_saved=monzo_saved,
    )


@bp.route("/accounts/setup-guide/monzo", methods=["POST"])
@login_required
def save_monzo_credentials():
    from dotenv import find_dotenv, set_key

    client_id = request.form.get("monzo_client_id", "").strip()
    client_secret = request.form.get("monzo_client_secret", "").strip()

    if not client_id or not client_secret:
        flash("Both fields are required — paste the Client ID and Client Secret exactly as Monzo showed them.", "error")
        return redirect(url_for("finance.setup_guide"))
    if client_id in PLACEHOLDER_VALUES or client_secret in PLACEHOLDER_VALUES:
        flash("That looks like the placeholder text, not a real value from Monzo's Clients page.", "error")
        return redirect(url_for("finance.setup_guide"))
    if " " in client_id or " " in client_secret:
        flash("There's a space in one of those values — copy again straight from Monzo, without extra characters.", "error")
        return redirect(url_for("finance.setup_guide"))

    env_path = find_dotenv()
    if not env_path:
        flash("Couldn't find the .env file on the server to write to — set these manually instead.", "error")
        return redirect(url_for("finance.setup_guide"))

    set_key(env_path, "MONZO_CLIENT_ID", client_id)
    set_key(env_path, "MONZO_CLIENT_SECRET", client_secret)
    flash("Saved to .env. This won't take effect until the app is restarted — "
          "run ./install.sh (or restart your service) now.", "success")
    return redirect(url_for("finance.setup_guide"))


@bp.route("/accounts/new", methods=["GET", "POST"])
@login_required
def new_account():
    if request.method == "POST":
        name = request.form.get("name", "").strip() or "Account"
        account_type = request.form.get("account_type", "current")
        institution = request.form.get("institution_name", "").strip()
        account_number = request.form.get("account_number", "").strip()
        sort_code = request.form.get("sort_code", "").strip()
        opening_balance = request.form.get("opening_balance", "0").strip() or "0"

        try:
            balance_minor = to_minor(opening_balance)
        except ValueError as e:
            flash(str(e), "error")
            monzo = get_monzo_provider("monzo")
            return render_template("finance/new_account.html", banks=_bank_list(monzo), monzo_configured=monzo.is_configured())

        is_default = FinanceAccount.query.filter_by(user_id=current_user.id).count() == 0
        account = FinanceAccount(
            user_id=current_user.id, name=name, account_type=account_type,
            institution_name=institution, account_number=account_number or None,
            sort_code=sort_code or None, balance_minor=balance_minor,
            is_default=is_default,
        )
        db.session.add(account)
        db.session.commit()
        flash(f"Account '{name}' created.", "success")
        return redirect(url_for("finance.accounts"))

    monzo = get_monzo_provider("monzo")
    return render_template("finance/new_account.html", banks=_bank_list(monzo), monzo_configured=monzo.is_configured())


# ---- Monzo OAuth connect flow ----

def _oauth_redirect_uri():
    base = os.environ.get("APP_BASE_URL", request.url_root.rstrip("/"))
    return f"{base}/finance/oauth/monzo/callback"


@bp.route("/accounts/connect/monzo")
@login_required
def connect_monzo():
    provider = get_monzo_provider("monzo")
    if not provider.is_configured():
        flash("Monzo isn't configured on this server — set MONZO_CLIENT_ID and MONZO_CLIENT_SECRET in .env "
              "(register a client at https://developers.monzo.com first).", "error")
        return redirect(url_for("finance.new_account"))

    state = secrets.token_urlsafe(24)
    session["monzo_oauth_state"] = state
    try:
        auth_url = provider.get_auth_url(_oauth_redirect_uri(), state)
    except BankProviderError as e:
        flash(str(e), "error")
        return redirect(url_for("finance.new_account"))
    return redirect(auth_url)


@bp.route("/oauth/monzo/callback")
@login_required
def monzo_callback():
    error = request.args.get("error")
    if error:
        flash(f"Monzo authorisation was not completed: {error}", "error")
        return redirect(url_for("finance.new_account"))

    state = request.args.get("state")
    expected_state = session.pop("monzo_oauth_state", None)
    if not state or not expected_state or state != expected_state:
        flash("Monzo sign-in couldn't be verified (state mismatch) — please try connecting again.", "error")
        return redirect(url_for("finance.new_account"))

    code = request.args.get("code")
    if not code:
        flash("Monzo didn't return an authorisation code.", "error")
        return redirect(url_for("finance.new_account"))

    provider = get_monzo_provider("monzo")
    try:
        tokens = provider.exchange_code(code, _oauth_redirect_uri())
    except BankProviderError as e:
        flash(f"Couldn't complete the Monzo connection: {e}", "error")
        return redirect(url_for("finance.new_account"))

    connection = FinanceBankConnection.query.filter_by(
        user_id=current_user.id, provider="monzo",
    ).first()
    if not connection:
        connection = FinanceBankConnection(user_id=current_user.id, provider="monzo")
        db.session.add(connection)

    connection.access_token_encrypted = encrypt_token(tokens["access_token"])
    connection.refresh_token_encrypted = encrypt_token(tokens.get("refresh_token"))
    connection.provider_account_id = tokens.get("user_id")
    connection.status = "connected"
    connection.last_synced_at = datetime.utcnow()
    connection.last_error = None
    db.session.commit()

    # Try to pull accounts immediately. If the user hasn't approved the
    # in-app push notification yet (Strong Customer Authentication), this
    # will 403 — that's expected and not treated as a failure; the accounts
    # page will show a "Fetch accounts" button for this connection until
    # they've approved it and come back.
    try:
        created = _pull_monzo_accounts(connection, tokens["access_token"])
    except BankProviderError as e:
        connection.last_error = str(e)
        db.session.commit()
        flash(
            "Monzo connected — check your Monzo app for a notification to approve access, "
            "then come back and hit \"Fetch accounts\" below.", "warning",
        )
        return redirect(url_for("finance.accounts"))

    db.session.commit()
    flash(f"Connected to Monzo — {created} account(s) added.", "success")
    return redirect(url_for("finance.accounts"))


@bp.route("/accounts/<account_id>/sync", methods=["POST"])
@login_required
def sync_account(account_id):
    account = FinanceAccount.query.filter_by(id=account_id, user_id=current_user.id).first_or_404()
    connection = account.bank_connection
    if not connection or connection.provider != "monzo":
        flash("This account isn't connected to a live bank feed.", "error")
        return redirect(url_for("finance.accounts"))

    provider = get_monzo_provider("monzo")
    access_token = decrypt_token(connection.access_token_encrypted)
    imported_count = [0]  # mutable box so the nested closure can write to it

    def _try_sync(token):
        remote_accounts = provider.list_accounts(token)
        match = next((a for a in remote_accounts if a["name"] == account.name), None)
        if not match:
            return False
        account.account_number = match.get("account_number") or account.account_number
        account.sort_code = match.get("sort_code") or account.sort_code
        balance = provider.get_balance(token, match["provider_account_id"])
        account.balance_minor = balance["balance_minor"]

        since = None
        if connection.last_synced_at:
            # A day's buffer before the last sync, not the exact instant, so a
            # transaction that posted moments after the last sync ran is never
            # silently missed by a razor-thin boundary. Dedup on external id
            # means re-fetching a day of overlap is harmless.
            since = (connection.last_synced_at - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        imported_count[0] = _import_monzo_transactions(
            current_user.id, account, provider, token, match["provider_account_id"], since=since
        )
        return True

    try:
        _try_sync(access_token)
    except BankProviderError as e:
        # Access token may have expired — try a refresh, once.
        refresh_token = decrypt_token(connection.refresh_token_encrypted)
        if refresh_token:
            try:
                new_tokens = provider.refresh_access_token(refresh_token)
                connection.access_token_encrypted = encrypt_token(new_tokens["access_token"])
                connection.refresh_token_encrypted = encrypt_token(new_tokens.get("refresh_token"))
                db.session.commit()
                _try_sync(new_tokens["access_token"])
            except BankProviderError as e2:
                connection.status = "error"
                connection.last_error = str(e2)
                db.session.commit()
                flash(f"Sync failed: {e2}", "error")
                return redirect(url_for("finance.accounts"))
        else:
            connection.status = "error"
            connection.last_error = str(e)
            db.session.commit()
            flash(f"Sync failed: {e}", "error")
            return redirect(url_for("finance.accounts"))

    connection.status = "connected"
    connection.last_synced_at = datetime.utcnow()
    connection.last_error = None
    db.session.commit()
    if imported_count[0]:
        flash(f"Account synced — {imported_count[0]} new transaction(s) imported.", "success")
    else:
        flash("Account synced. No new transactions since last sync.", "success")
    return redirect(url_for("finance.accounts"))


@bp.route("/accounts/<account_id>/disconnect", methods=["POST"])
@login_required
def disconnect_account(account_id):
    account = FinanceAccount.query.filter_by(id=account_id, user_id=current_user.id).first_or_404()
    connection = account.bank_connection
    if connection:
        access_token = decrypt_token(connection.access_token_encrypted)
        provider = get_monzo_provider("monzo")
        try:
            if access_token:
                provider.logout(access_token)
        except Exception:
            pass
        connection.status = "disconnected"
        connection.access_token_encrypted = None
        connection.refresh_token_encrypted = None
        db.session.commit()
    flash("Bank connection disconnected. The account and its history are kept — reconnect any time.", "success")
    return redirect(url_for("finance.accounts"))


@bp.route("/accounts/<account_id>/set-default", methods=["POST"])
@login_required
def set_default_account(account_id):
    FinanceAccount.query.filter_by(user_id=current_user.id).update({"is_default": False})
    account = FinanceAccount.query.filter_by(id=account_id, user_id=current_user.id).first_or_404()
    account.is_default = True
    db.session.commit()
    return redirect(url_for("finance.accounts"))


@bp.route("/accounts/<account_id>/deactivate", methods=["POST"])
@login_required
def deactivate_account(account_id):
    account = FinanceAccount.query.filter_by(id=account_id, user_id=current_user.id).first_or_404()
    account.active = not account.active
    db.session.commit()
    return redirect(url_for("finance.accounts"))


@bp.route("/accounts/<account_id>/delete", methods=["POST"])
@login_required
def delete_account(account_id):
    """Permanently removes the account and everything tied to it -- all its
    transactions go with it (cascade="all, delete-orphan" on the relationship
    in models.py). Unlike Deactivate (a reversible hide) or Disconnect (drops
    the live bank feed but keeps history), this cannot be undone."""
    account = FinanceAccount.query.filter_by(id=account_id, user_id=current_user.id).first_or_404()
    name = account.name
    db.session.delete(account)
    db.session.commit()
    flash(f"'{name}' and its transaction history have been permanently deleted.", "success")
    return redirect(url_for("finance.accounts"))


# ---- Transactions ----

@bp.route("/transactions")
@login_required
def transactions():
    query = FinanceTransaction.query.filter_by(user_id=current_user.id)

    account_id = request.args.get("account_id")
    if account_id:
        query = query.filter_by(account_id=account_id)

    category_id = request.args.get("category_id")
    if category_id:
        query = query.filter_by(category_id=category_id)

    show_ignored = request.args.get("show_ignored") == "1"
    if not show_ignored:
        query = query.filter_by(ignored=False)

    search = request.args.get("q", "").strip()
    if search:
        query = query.filter(FinanceTransaction.clean_description.ilike(f"%{search}%"))

    # Totals for the current filter set (before pagination narrows it to one page).
    in_minor = query.filter(FinanceTransaction.amount_minor > 0).with_entities(
        db.func.coalesce(db.func.sum(FinanceTransaction.amount_minor), 0)
    ).scalar()
    out_minor = query.filter(FinanceTransaction.amount_minor < 0).with_entities(
        db.func.coalesce(db.func.sum(FinanceTransaction.amount_minor), 0)
    ).scalar()

    page = request.args.get("page", 1, type=int)
    pagination = query.order_by(FinanceTransaction.date.desc()).paginate(page=page, per_page=50, error_out=False)
    accounts = FinanceAccount.query.filter_by(user_id=current_user.id).all()
    categories = FinanceCategory.query.filter(
        (FinanceCategory.user_id == current_user.id) | (FinanceCategory.user_id.is_(None))
    ).order_by(FinanceCategory.name).all()

    return render_template("finance/transactions.html", transactions=pagination.items, pagination=pagination,
                            accounts=accounts, categories=categories, search=search, show_ignored=show_ignored,
                            in_minor=in_minor, out_minor=out_minor, net_minor=in_minor + out_minor)


@bp.route("/transactions/bulk-categorize", methods=["POST"])
@login_required
def bulk_categorize_transactions():
    """Applies one category to several selected transactions at once, so
    clearing out an uncategorised list doesn't mean repeating the same
    per-row action dozens of times."""
    category_id = request.form.get("category_id")
    txn_ids = request.form.getlist("txn_ids")
    if not category_id or not txn_ids:
        flash("Select a category and at least one transaction.", "error")
        return redirect(url_for("finance.transactions"))

    txns = FinanceTransaction.query.filter(
        FinanceTransaction.id.in_(txn_ids), FinanceTransaction.user_id == current_user.id,
    ).all()
    for txn in txns:
        txn.category_id = int(category_id)
        remember_correction(current_user.id, txn.clean_description or txn.raw_description, txn.category_id)
    db.session.commit()
    if txns:
        emit("transactions.changed", user_id=current_user.id, source="bulk_categorize", count=len(txns))
    flash(f"Categorised {len(txns)} transaction(s).", "success")
    return redirect(url_for("finance.transactions"))


@bp.route("/transactions/auto-categorize", methods=["POST"])
@login_required
def auto_categorize_transactions():
    """Runs the same rule/keyword categorisation used on import across any
    transaction that's still uncategorised, so an improved keyword list (or
    a rule learned from a later correction) benefits existing history too,
    not just future imports."""
    uncategorized = FinanceTransaction.query.filter_by(
        user_id=current_user.id, category_id=None,
    ).all()
    updated = 0
    for txn in uncategorized:
        description = txn.clean_description or txn.raw_description
        category_id = suggest_category(current_user.id, description)
        if category_id:
            txn.category_id = category_id
            updated += 1

    if updated:
        db.session.commit()
        emit("transactions.changed", user_id=current_user.id, source="auto_categorize", count=updated)
        flash(f"Categorised {updated} of {len(uncategorized)} previously uncategorised transaction(s).", "success")
    else:
        flash("Nothing to categorise -- everything uncategorised was left as-is." if uncategorized
              else "Nothing uncategorised to go through.", "warning")
    return redirect(url_for("finance.transactions"))


@bp.route("/transactions/<txn_id>/edit", methods=["POST"])
@login_required
def edit_transaction(txn_id):
    txn = FinanceTransaction.query.filter_by(id=txn_id, user_id=current_user.id).first_or_404()
    txn.clean_description = request.form.get("clean_description", txn.clean_description)
    txn.notes = request.form.get("notes", txn.notes)
    txn.tags = request.form.get("tags", txn.tags)

    category_id = request.form.get("category_id")
    if category_id:
        txn.category_id = int(category_id)
        remember_correction(current_user.id, txn.clean_description or txn.raw_description, txn.category_id)
        emit("transaction.categorised", transaction_id=txn.id, category_id=txn.category_id)

    db.session.commit()
    emit("transaction.updated", transaction_id=txn.id)
    return redirect(url_for("finance.transactions"))


@bp.route("/transactions/<txn_id>/toggle-ignore", methods=["POST"])
@login_required
def toggle_ignore(txn_id):
    txn = FinanceTransaction.query.filter_by(id=txn_id, user_id=current_user.id).first_or_404()
    txn.ignored = not txn.ignored
    db.session.commit()
    return redirect(url_for("finance.transactions"))


@bp.route("/transactions/<txn_id>/toggle-review", methods=["POST"])
@login_required
def toggle_review(txn_id):
    txn = FinanceTransaction.query.filter_by(id=txn_id, user_id=current_user.id).first_or_404()
    txn.reviewed = not txn.reviewed
    db.session.commit()
    return redirect(url_for("finance.transactions"))


@bp.route("/transactions/<txn_id>/split", methods=["POST"])
@login_required
def split_transaction(txn_id):
    parent = FinanceTransaction.query.filter_by(id=txn_id, user_id=current_user.id).first_or_404()
    amounts = request.form.getlist("split_amount")
    labels = request.form.getlist("split_label")

    allocated = 0
    for i, amount_str in enumerate(amounts):
        amount_str = amount_str.strip()
        if not amount_str:
            continue
        try:
            amount_minor = to_minor(amount_str)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("finance.transactions"))
        if parent.amount_minor < 0:
            amount_minor = -abs(amount_minor)
        allocated += amount_minor
        db.session.add(FinanceTransaction(
            user_id=current_user.id, account_id=parent.account_id, date=parent.date,
            merchant_name=parent.merchant_name,
            clean_description=labels[i] if i < len(labels) and labels[i] else parent.clean_description,
            raw_description=parent.raw_description, amount_minor=amount_minor, currency=parent.currency,
            direction=parent.direction, txn_type="spending", import_source="split",
            parent_transaction_id=parent.id,
        ))

    db.session.commit()
    flash("Transaction split.", "success")
    return redirect(url_for("finance.transactions"))


@bp.route("/transactions/<txn_id>/delete", methods=["POST"])
@login_required
def delete_transaction(txn_id):
    txn = FinanceTransaction.query.filter_by(id=txn_id, user_id=current_user.id).first_or_404()
    emit("transaction.deleted", user_id=current_user.id, transaction_id=txn_id, superseded_by=None)
    db.session.delete(txn)
    db.session.commit()
    return redirect(url_for("finance.transactions"))


@bp.route("/transactions/dedupe", methods=["POST"])
@login_required
def dedupe_transactions():
    report = find_and_remove_duplicates(current_user.id)
    removed_total = sum(abs(r["amount_minor"]) for r in report["removed"])
    if report["removed"]:
        msg = f"Removed {len(report['removed'])} duplicate transaction(s) totalling {format_money(removed_total)}."
        if report["flagged"]:
            msg += f" {len(report['flagged'])} group(s) skipped for manual review (involve a split)."
        flash(msg, "success")
    elif report["flagged"]:
        flash(f"No duplicates auto-removed. {len(report['flagged'])} group(s) need manual review (involve a split).", "info")
    else:
        flash("No duplicate transactions found.", "info")
    return redirect(url_for("finance.transactions"))


@on("transactions.changed")
def _on_transactions_changed_dedupe(**payload):
    """Keeps duplicates from accumulating going forward -- runs the same
    cross-source dedupe sweep after every import/sync/bulk edit, not just
    when someone clicks 'Remove duplicates'. Defensive per the event-handler
    convention used throughout this app: must never break the request that
    triggered the event."""
    user_id = payload.get("user_id")
    if not user_id:
        return
    try:
        find_and_remove_duplicates(user_id)
    except Exception:
        db.session.rollback()
        current_app.logger.exception("Automatic dedupe failed for user %s", user_id)


# ---- Statement import ----

@bp.route("/import", methods=["GET", "POST"])
@login_required
def import_statement():
    accounts = FinanceAccount.query.filter_by(user_id=current_user.id, active=True).all()
    if request.method == "POST":
        account_id = request.form.get("account_id")
        upload = request.files.get("statement_file")
        if not account_id or not upload or not upload.filename:
            flash("Choose an account and a file to import.", "error")
            return render_template("finance/import.html", accounts=accounts)

        if not upload.filename.lower().endswith(".csv"):
            flash("Only CSV import is available right now — OFX/QFX/PDF are on the roadmap.", "error")
            return render_template("finance/import.html", accounts=accounts)

        try:
            stored, path = save_upload(upload, purpose="bank_statement", user=current_user)
            with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
                csv_text = f.read()
            parsed_rows = parse_csv_preview(csv_text, account_id)
        except Exception as e:
            flash(f"Could not parse that file: {e}", "error")
            return render_template("finance/import.html", accounts=accounts)

        existing_hashes = {
            h for (h,) in db.session.query(FinanceTransaction.dedupe_hash).filter_by(
                user_id=current_user.id, account_id=account_id
            ).all() if h
        }
        for row in parsed_rows:
            row["duplicate"] = row["dedupe_hash"] in existing_hashes

        batch = FinanceImportBatch(
            user_id=current_user.id, account_id=account_id, filename=stored.original_filename,
            file_format="csv", row_count=len(parsed_rows),
        )
        db.session.add(batch)
        db.session.commit()

        return render_template("finance/import_preview.html", rows=parsed_rows, batch=batch,
                                account_id=account_id)

    return render_template("finance/import.html", accounts=accounts)


@bp.route("/import/<batch_id>/confirm", methods=["POST"])
@login_required
def confirm_import(batch_id):
    batch = FinanceImportBatch.query.filter_by(id=batch_id, user_id=current_user.id).first_or_404()
    account = FinanceAccount.query.filter_by(id=batch.account_id, user_id=current_user.id).first_or_404()

    dates = request.form.getlist("date")
    descriptions = request.form.getlist("description")
    amounts = request.form.getlist("amount_minor")
    external_ids = request.form.getlist("external_id")
    dedupe_hashes = request.form.getlist("dedupe_hash")
    include_flags = set(request.form.getlist("include"))

    imported = 0
    duplicates = 0
    pre_existing_hashes = {
        h for (h,) in db.session.query(FinanceTransaction.dedupe_hash).filter_by(
            user_id=current_user.id, account_id=account.id
        ).all() if h
    }
    seen_in_batch = {}

    for i in range(len(dates)):
        row_hash = dedupe_hashes[i]
        if str(i) not in include_flags:
            continue
        if row_hash in pre_existing_hashes:
            duplicates += 1
            continue

        # Two genuinely distinct transactions in the same statement can share an
        # identical date/amount/description (e.g. two same-price purchases in one
        # day) and therefore the same dedupe_hash. Disambiguate within this batch
        # only, so repeat *uploads* of the same file are still caught as duplicates
        # (pre_existing_hashes is never mutated here).
        occurrence = seen_in_batch.get(row_hash, 0)
        seen_in_batch[row_hash] = occurrence + 1
        effective_hash = row_hash if occurrence == 0 else f"{row_hash}:{occurrence}"

        amount_minor = int(amounts[i])
        description = descriptions[i]
        category_id = suggest_category(current_user.id, description)

        txn = FinanceTransaction(
            user_id=current_user.id, account_id=account.id,
            date=datetime.strptime(dates[i], "%Y-%m-%d").date(),
            raw_description=description, clean_description=description,
            amount_minor=amount_minor, currency=account.currency,
            direction="credit" if amount_minor >= 0 else "debit",
            category_id=category_id,
            import_source="csv", import_batch_id=batch.id,
            external_transaction_id=external_ids[i] or None,
            dedupe_hash=effective_hash,
        )
        db.session.add(txn)
        account.balance_minor += amount_minor
        imported += 1

    batch.imported_count = imported
    batch.duplicate_count = duplicates
    batch.status = "confirmed"
    db.session.commit()

    emit("transaction.imported", batch_id=batch.id, imported=imported, duplicates=duplicates)
    if imported:
        emit("transactions.changed", user_id=current_user.id, source="csv_import", count=imported)
    flash(f"Imported {imported} transactions ({duplicates} duplicates skipped).", "success")
    return redirect(url_for("finance.transactions"))


# ---- Budgets ----

@bp.route("/budgets")
@login_required
def budgets():
    rows = FinanceBudget.query.filter_by(user_id=current_user.id).all()
    budget_rows = [(b, calc.budget_status(current_user.id, b)) for b in rows]
    categories = FinanceCategory.query.filter(
        (FinanceCategory.user_id == current_user.id) | (FinanceCategory.user_id.is_(None))
    ).order_by(FinanceCategory.name).all()
    return render_template("finance/budgets.html", budget_rows=budget_rows, categories=categories)


@bp.route("/budgets/new", methods=["POST"])
@login_required
def new_budget():
    category_id = request.form.get("category_id")
    amount = request.form.get("amount", "0")
    if category_id:
        try:
            amount_minor = to_minor(amount)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("finance.budgets"))
        existing = FinanceBudget.query.filter_by(user_id=current_user.id, category_id=category_id).first()
        if existing:
            existing.amount_minor = amount_minor
        else:
            db.session.add(FinanceBudget(user_id=current_user.id, category_id=int(category_id),
                                          amount_minor=amount_minor))
        db.session.commit()
    return redirect(url_for("finance.budgets"))


@bp.route("/budgets/<int:budget_id>/delete", methods=["POST"])
@login_required
def delete_budget(budget_id):
    b = FinanceBudget.query.filter_by(id=budget_id, user_id=current_user.id).first_or_404()
    db.session.delete(b)
    db.session.commit()
    return redirect(url_for("finance.budgets"))


# ---- Bills ----

@bp.route("/bills")
@login_required
def bills():
    items = FinanceBill.query.filter_by(user_id=current_user.id).order_by(FinanceBill.next_due_date).all()
    categories = FinanceCategory.query.filter(
        (FinanceCategory.user_id == current_user.id) | (FinanceCategory.user_id.is_(None))
    ).order_by(FinanceCategory.name).all()
    safe_balance = calc.safe_discretionary_money(current_user.id)
    return render_template("finance/bills.html", bills=items, categories=categories, safe_balance=safe_balance)


@bp.route("/bills/new", methods=["POST"])
@login_required
def new_bill():
    name = request.form.get("name", "").strip()
    amount = request.form.get("amount", "0")
    due_day = request.form.get("due_day", "1")
    frequency = request.form.get("frequency", "monthly")
    category_id = request.form.get("category_id") or None
    if name:
        try:
            amount_minor = to_minor(amount)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("finance.bills"))
        due_day_int = min(max(int(due_day or 1), 1), 28)
        today = date.today()
        next_due = today.replace(day=due_day_int)
        if next_due < today:
            next_due += relativedelta(months=1)
        db.session.add(FinanceBill(
            user_id=current_user.id, name=name, amount_minor=amount_minor, due_day=due_day_int,
            frequency=frequency, category_id=int(category_id) if category_id else None, next_due_date=next_due,
        ))
        db.session.commit()
        flash(f"Bill '{name}' added.", "success")
    return redirect(url_for("finance.bills"))


@bp.route("/bills/<bill_id>/mark-paid", methods=["POST"])
@login_required
def mark_bill_paid(bill_id):
    bill = FinanceBill.query.filter_by(id=bill_id, user_id=current_user.id).first_or_404()
    if bill.frequency == "monthly":
        bill.next_due_date = bill.next_due_date + relativedelta(months=1)
    elif bill.frequency == "weekly":
        bill.next_due_date = bill.next_due_date + relativedelta(weeks=1)
    elif bill.frequency == "annual":
        bill.next_due_date = bill.next_due_date + relativedelta(years=1)
    db.session.commit()
    return _redirect_next("finance.bills")


@bp.route("/bills/<bill_id>/toggle-active", methods=["POST"])
@login_required
def toggle_bill_active(bill_id):
    bill = FinanceBill.query.filter_by(id=bill_id, user_id=current_user.id).first_or_404()
    bill.active = not bill.active
    db.session.commit()
    return redirect(url_for("finance.bills"))


@bp.route("/bills/<bill_id>/delete", methods=["POST"])
@login_required
def delete_bill(bill_id):
    bill = FinanceBill.query.filter_by(id=bill_id, user_id=current_user.id).first_or_404()
    db.session.delete(bill)
    db.session.commit()
    return redirect(url_for("finance.bills"))


# ---- Subscriptions ----

@bp.route("/subscriptions")
@login_required
def subscriptions():
    items = FinanceSubscription.query.filter_by(user_id=current_user.id).order_by(
        FinanceSubscription.status, FinanceSubscription.name
    ).all()
    total_monthly = sum(s.monthly_cost_minor for s in items if s.status == "active")
    categories = FinanceCategory.query.filter(
        (FinanceCategory.user_id == current_user.id) | (FinanceCategory.user_id.is_(None))
    ).order_by(FinanceCategory.name).all()
    return render_template("finance/subscriptions.html", subscriptions=items,
                            total_monthly=total_monthly, categories=categories)


@bp.route("/subscriptions/new", methods=["POST"])
@login_required
def new_subscription():
    name = request.form.get("name", "").strip()
    amount = request.form.get("amount", "0")
    frequency = request.form.get("frequency", "monthly")
    category_id = request.form.get("category_id") or None
    if name:
        try:
            amount_minor = to_minor(amount)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("finance.subscriptions"))
        next_payment = date.today() + (relativedelta(months=1) if frequency == "monthly" else relativedelta(years=1))
        db.session.add(FinanceSubscription(
            user_id=current_user.id, name=name, amount_minor=amount_minor, frequency=frequency,
            category_id=int(category_id) if category_id else None, next_payment_date=next_payment,
        ))
        db.session.commit()
        flash(f"Subscription '{name}' added.", "success")
    return redirect(url_for("finance.subscriptions"))


@bp.route("/subscriptions/<sub_id>/cancel", methods=["POST"])
@login_required
def cancel_subscription(sub_id):
    sub = FinanceSubscription.query.filter_by(id=sub_id, user_id=current_user.id).first_or_404()
    sub.status = "cancelled"
    db.session.commit()
    return redirect(url_for("finance.subscriptions"))


@bp.route("/subscriptions/<sub_id>/delete", methods=["POST"])
@login_required
def delete_subscription(sub_id):
    sub = FinanceSubscription.query.filter_by(id=sub_id, user_id=current_user.id).first_or_404()
    db.session.delete(sub)
    db.session.commit()
    return redirect(url_for("finance.subscriptions"))


# ---- Recurring payments ----

@bp.route("/recurring")
@login_required
def recurring():
    calc.detect_recurring_payments(current_user.id)
    show_ignored = request.args.get("show_ignored") == "1"
    query = FinanceRecurringPayment.query.filter_by(user_id=current_user.id).filter(
        FinanceRecurringPayment.status != "cancelled"
    )
    if not show_ignored:
        query = query.filter(FinanceRecurringPayment.status != "ignored")
    items = query.order_by(FinanceRecurringPayment.next_payment_date).all()
    ignored_count = FinanceRecurringPayment.query.filter_by(
        user_id=current_user.id, status="ignored",
    ).count()
    return render_template("finance/recurring.html", items=items, show_ignored=show_ignored,
                            ignored_count=ignored_count)


@bp.route("/recurring/<item_id>/confirm", methods=["POST"])
@login_required
def confirm_recurring(item_id):
    item = FinanceRecurringPayment.query.filter_by(id=item_id, user_id=current_user.id).first_or_404()
    item.status = "confirmed"
    db.session.commit()
    return redirect(url_for("finance.recurring"))


@bp.route("/recurring/<item_id>/ignore", methods=["POST"])
@login_required
def ignore_recurring(item_id):
    item = FinanceRecurringPayment.query.filter_by(id=item_id, user_id=current_user.id).first_or_404()
    item.status = "ignored"
    db.session.commit()
    return redirect(url_for("finance.recurring"))


@bp.route("/recurring/<item_id>/mark-cancelled", methods=["POST"])
@login_required
def mark_recurring_cancelled(item_id):
    item = FinanceRecurringPayment.query.filter_by(id=item_id, user_id=current_user.id).first_or_404()
    item.status = "cancelled"
    db.session.commit()
    return redirect(url_for("finance.recurring"))


# ---- Planned purchases ----

@bp.route("/purchases")
@login_required
def purchases():
    items = FinancePlannedPurchase.query.filter_by(user_id=current_user.id, purchased=False).order_by(
        FinancePlannedPurchase.priority.desc(), FinancePlannedPurchase.desired_date
    ).all()
    safe_balance = calc.safe_discretionary_money(current_user.id)
    return render_template("finance/purchases.html", items=items, safe_balance=safe_balance)


@bp.route("/purchases/new", methods=["POST"])
@login_required
def new_purchase():
    name = request.form.get("name", "").strip()
    price = request.form.get("price", "0")
    quantity = request.form.get("quantity", "1")
    url_field = request.form.get("url", "").strip()
    priority = request.form.get("priority", "medium")
    desired_date_raw = request.form.get("desired_date", "").strip()
    notes = request.form.get("notes", "")
    if name:
        try:
            price_minor = to_minor(price)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("finance.purchases"))
        desired_date = None
        if desired_date_raw:
            try:
                desired_date = datetime.strptime(desired_date_raw, "%Y-%m-%d").date()
            except ValueError:
                flash("That date didn\'t look right -- use YYYY-MM-DD, or leave it blank.", "error")
                return redirect(url_for("finance.purchases"))
        db.session.add(FinancePlannedPurchase(
            user_id=current_user.id, name=name, price_minor=price_minor,
            quantity=int(quantity or 1), url=url_field, priority=priority,
            desired_date=desired_date, notes=notes,
        ))
        db.session.commit()
        flash(f"Added '{name}' to planned purchases.", "success")
    return redirect(url_for("finance.purchases"))


@bp.route("/purchases/<purchase_id>/mark-purchased", methods=["POST"])
@login_required
def mark_purchased(purchase_id):
    item = FinancePlannedPurchase.query.filter_by(id=purchase_id, user_id=current_user.id).first_or_404()
    item.purchased = True
    db.session.commit()
    return redirect(url_for("finance.purchases"))


@bp.route("/purchases/<purchase_id>/delete", methods=["POST"])
@login_required
def delete_purchase(purchase_id):
    item = FinancePlannedPurchase.query.filter_by(id=purchase_id, user_id=current_user.id).first_or_404()
    db.session.delete(item)
    db.session.commit()
    return redirect(url_for("finance.purchases"))


# ---- Monthly planning ----

def _redirect_next(default_endpoint):
    next_endpoint = request.form.get("next")
    allowed = {"finance.due", "finance.bills", "finance.subscriptions", "finance.debts"}
    if next_endpoint in allowed:
        return redirect(url_for(next_endpoint))
    return redirect(url_for(default_endpoint))
def _parse_month_param():
    raw = request.args.get("month", "")
    try:
        return datetime.strptime(raw + "-01", "%Y-%m-%d").date()
    except ValueError:
        return date.today().replace(day=1)


@bp.route("/planning")
@login_required
def planning():
    month = _parse_month_param()
    impact = calc.monthly_plan_impact(current_user.id, month)
    prev_month = (month - timedelta(days=1)).replace(day=1)
    next_month = month + relativedelta(months=1)
    return render_template("finance/planning.html", impact=impact, month=month,
                            prev_month=prev_month, next_month=next_month)


@bp.route("/planning/new", methods=["POST"])
@login_required
def new_plan_item():
    month = _parse_month_param()
    name = request.form.get("name", "").strip()
    amount = request.form.get("amount", "0")
    if name:
        try:
            amount_minor = to_minor(amount)
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("finance.planning", month=month.strftime("%Y-%m")))
        db.session.add(FinanceMonthlyPlanItem(
            user_id=current_user.id, month=month, name=name, amount_minor=amount_minor,
            notes=request.form.get("notes", "").strip(),
        ))
        db.session.commit()
    return redirect(url_for("finance.planning", month=month.strftime("%Y-%m")))


@bp.route("/planning/<item_id>/delete", methods=["POST"])
@login_required
def delete_plan_item(item_id):
    item = FinanceMonthlyPlanItem.query.filter_by(id=item_id, user_id=current_user.id).first_or_404()
    month = item.month
    db.session.delete(item)
    db.session.commit()
    return redirect(url_for("finance.planning", month=month.strftime("%Y-%m")))


# ---- Savings ----

@bp.route("/savings")
@login_required
def savings():
    goals = FinanceSavingsGoal.query.filter_by(user_id=current_user.id).order_by(
        FinanceSavingsGoal.achieved, FinanceSavingsGoal.target_date
    ).all()
    suggestions = calc.money_saving_suggestions(current_user.id)
    return render_template("finance/savings.html", goals=goals, suggestions=suggestions)


@bp.route("/savings/new", methods=["POST"])
@login_required
def new_savings_goal():
    name = request.form.get("name", "").strip()
    target = request.form.get("target", "0")
    target_date_raw = request.form.get("target_date", "").strip()
    monthly_contribution = request.form.get("monthly_contribution", "0")
    if name:
        try:
            target_minor = to_minor(target)
            contribution_minor = to_minor(monthly_contribution or "0")
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("finance.savings"))
        target_date = None
        if target_date_raw:
            try:
                target_date = datetime.strptime(target_date_raw, "%Y-%m-%d").date()
            except ValueError:
                flash("That date didn\'t look right -- use YYYY-MM-DD, or leave it blank.", "error")
                return redirect(url_for("finance.savings"))
        db.session.add(FinanceSavingsGoal(
            user_id=current_user.id, name=name, target_minor=target_minor,
            target_date=target_date, monthly_contribution_minor=contribution_minor,
        ))
        db.session.commit()
        flash(f"Savings goal '{name}' created.", "success")
    return redirect(url_for("finance.savings"))


@bp.route("/savings/<goal_id>/add-funds", methods=["POST"])
@login_required
def add_savings_funds(goal_id):
    goal = FinanceSavingsGoal.query.filter_by(id=goal_id, user_id=current_user.id).first_or_404()
    amount = request.form.get("amount", "0")
    try:
        goal.current_minor += to_minor(amount)
    except ValueError as e:
        flash(str(e), "error")
        return redirect(url_for("finance.savings"))
    if goal.current_minor >= goal.target_minor:
        goal.achieved = True
    db.session.commit()
    return redirect(url_for("finance.savings"))


@bp.route("/savings/<goal_id>/delete", methods=["POST"])
@login_required
def delete_savings_goal(goal_id):
    goal = FinanceSavingsGoal.query.filter_by(id=goal_id, user_id=current_user.id).first_or_404()
    db.session.delete(goal)
    db.session.commit()
    return redirect(url_for("finance.savings"))


# ---- Debts (money owed to companies under a payment plan) ----

@bp.route("/debts")
@login_required
def debts():
    items = FinanceDebt.query.filter_by(user_id=current_user.id).order_by(
        FinanceDebt.settled, FinanceDebt.creditor_name
    ).all()
    total_owed_minor = calc.total_debt_owed(current_user.id)
    return render_template("finance/debts.html", debts=items, total_owed_minor=total_owed_minor)


@bp.route("/debts/new", methods=["POST"])
@login_required
def new_debt():
    creditor_name = request.form.get("creditor_name", "").strip()
    remaining = request.form.get("remaining", "0")
    original = request.form.get("original", "").strip()
    monthly_payment = request.form.get("monthly_payment", "0")
    next_payment_date_raw = request.form.get("next_payment_date", "").strip()
    notes = request.form.get("notes", "").strip()
    if creditor_name:
        try:
            remaining_minor = to_minor(remaining)
            monthly_payment_minor = to_minor(monthly_payment)
            original_minor = to_minor(original) if original else None
        except ValueError as e:
            flash(str(e), "error")
            return redirect(url_for("finance.debts"))
        next_payment_date = None
        if next_payment_date_raw:
            try:
                next_payment_date = datetime.strptime(next_payment_date_raw, "%Y-%m-%d").date()
            except ValueError:
                flash("That date didn\'t look right -- use YYYY-MM-DD, or leave it blank.", "error")
                return redirect(url_for("finance.debts"))
        db.session.add(FinanceDebt(
            user_id=current_user.id, creditor_name=creditor_name, remaining_minor=remaining_minor,
            original_minor=original_minor, monthly_payment_minor=monthly_payment_minor,
            next_payment_date=next_payment_date, notes=notes,
        ))
        db.session.commit()
        flash(f"\'{creditor_name}\' added.", "success")
    return redirect(url_for("finance.debts"))


@bp.route("/debts/<debt_id>/log-payment", methods=["POST"])
@login_required
def log_debt_payment(debt_id):
    debt = FinanceDebt.query.filter_by(id=debt_id, user_id=current_user.id).first_or_404()
    amount_raw = request.form.get("amount", "").strip()
    try:
        amount_minor = to_minor(amount_raw) if amount_raw else debt.monthly_payment_minor
    except ValueError as e:
        flash(str(e), "error")
        return redirect(url_for("finance.debts"))

    debt.remaining_minor = max(0, debt.remaining_minor - amount_minor)
    if debt.remaining_minor == 0:
        debt.settled = True
        flash(f"\'{debt.creditor_name}\' is paid off.", "success")
    else:
        flash(f"Logged {format_money(amount_minor)} against \'{debt.creditor_name}\' -- "
              f"{format_money(debt.remaining_minor)} left.", "success")
    if debt.next_payment_date:
        debt.next_payment_date = debt.next_payment_date + relativedelta(months=1)
    db.session.commit()
    return redirect(url_for("finance.debts"))


@bp.route("/debts/<debt_id>/delete", methods=["POST"])
@login_required
def delete_debt(debt_id):
    debt = FinanceDebt.query.filter_by(id=debt_id, user_id=current_user.id).first_or_404()
    db.session.delete(debt)
    db.session.commit()
    return redirect(url_for("finance.debts"))
@bp.route("/debts/<debt_id>/frequency", methods=["POST"])
@login_required
def update_debt_frequency(debt_id):
    debt = FinanceDebt.query.filter_by(id=debt_id, user_id=current_user.id).first_or_404()
    frequency = request.form.get("frequency", "monthly")
    if frequency in ("monthly", "fortnightly", "weekly", "variable"):
        debt.frequency = frequency
        db.session.commit()
    return redirect(url_for("finance.debts"))


# ---- Debts: custom payment schedule (calendar-based, per-payment amounts) ----

@bp.route("/debts/<debt_id>/schedule/generate", methods=["POST"])
@login_required
def generate_debt_schedule(debt_id):
    """Builds a brand-new schedule of N payments for this debt, replacing any
    unpaid entries that already exist. Each payment defaults to an equal
    split of the total, but every row can be edited individually afterwards."""
    debt = FinanceDebt.query.filter_by(id=debt_id, user_id=current_user.id).first_or_404()

    try:
        count = int(request.form.get("count", "0"))
    except ValueError:
        count = 0
    if count < 1 or count > 120:
        flash("Enter a number of payments between 1 and 120.", "error")
        return redirect(url_for("finance.debts"))

    start_date_raw = request.form.get("start_date", "").strip()
    try:
        start_date = datetime.strptime(start_date_raw, "%Y-%m-%d").date() if start_date_raw else date.today()
    except ValueError:
        flash("That start date didn't look right -- use YYYY-MM-DD.", "error")
        return redirect(url_for("finance.debts"))

    interval = request.form.get("interval", "monthly")
    step = {
        "weekly": relativedelta(weeks=1),
        "fortnightly": relativedelta(weeks=2),
        "monthly": relativedelta(months=1),
    }.get(interval, relativedelta(months=1))

    total_raw = request.form.get("total_amount", "").strip()
    try:
        total_minor = to_minor(total_raw) if total_raw else debt.remaining_minor
    except ValueError as e:
        flash(str(e), "error")
        return redirect(url_for("finance.debts"))

    # Remove any existing *unpaid* schedule rows -- paid history is kept.
    FinanceDebtPayment.query.filter_by(debt_id=debt.id, paid=False).delete()

    base_amount = total_minor // count
    remainder = total_minor - (base_amount * count)
    due = start_date
    for i in range(count):
        amount = base_amount + (remainder if i == count - 1 else 0)
        db.session.add(FinanceDebtPayment(debt_id=debt.id, due_date=due, amount_minor=amount))
        due = due + step

    db.session.commit()
    flash(f"Set up {count} payments for '{debt.creditor_name}'.", "success")
    return redirect(url_for("finance.debts"))


@bp.route("/debts/<debt_id>/schedule/add", methods=["POST"])
@login_required
def add_debt_payment(debt_id):
    """Adds one payment to a debt's existing custom schedule."""
    debt = FinanceDebt.query.filter_by(id=debt_id, user_id=current_user.id).first_or_404()
    due_date_raw = request.form.get("due_date", "").strip()
    amount_raw = request.form.get("amount", "").strip()
    try:
        due_date = datetime.strptime(due_date_raw, "%Y-%m-%d").date()
        amount_minor = to_minor(amount_raw)
    except ValueError:
        flash("Enter a valid date (YYYY-MM-DD) and amount for the new payment.", "error")
        return redirect(url_for("finance.debts"))
    db.session.add(FinanceDebtPayment(debt_id=debt.id, due_date=due_date, amount_minor=amount_minor))
    db.session.commit()
    flash("Payment added to schedule.", "success")
    return redirect(url_for("finance.debts"))


@bp.route("/debts/<debt_id>/schedule/<payment_id>/edit", methods=["POST"])
@login_required
def edit_debt_payment(debt_id, payment_id):
    """Lets each individual scheduled payment have its own date and amount."""
    debt = FinanceDebt.query.filter_by(id=debt_id, user_id=current_user.id).first_or_404()
    payment = FinanceDebtPayment.query.filter_by(id=payment_id, debt_id=debt.id).first_or_404()

    due_date_raw = request.form.get("due_date", "").strip()
    amount_raw = request.form.get("amount", "").strip()
    try:
        if due_date_raw:
            payment.due_date = datetime.strptime(due_date_raw, "%Y-%m-%d").date()
        if amount_raw:
            payment.amount_minor = to_minor(amount_raw)
    except ValueError:
        flash("That date or amount didn't look right.", "error")
        return redirect(url_for("finance.debts"))

    db.session.commit()
    return redirect(url_for("finance.debts"))


@bp.route("/debts/<debt_id>/schedule/<payment_id>/delete", methods=["POST"])
@login_required
def delete_debt_payment(debt_id, payment_id):
    payment = FinanceDebtPayment.query.filter_by(id=payment_id, debt_id=debt_id).first_or_404()
    db.session.delete(payment)
    db.session.commit()
    return redirect(url_for("finance.debts"))


@bp.route("/debts/<debt_id>/schedule/<payment_id>/mark-paid", methods=["POST"])
@login_required
def mark_debt_payment_paid(debt_id, payment_id):
    debt = FinanceDebt.query.filter_by(id=debt_id, user_id=current_user.id).first_or_404()
    payment = FinanceDebtPayment.query.filter_by(id=payment_id, debt_id=debt.id).first_or_404()

    payment.paid = True
    payment.paid_at = datetime.utcnow()
    debt.remaining_minor = max(0, debt.remaining_minor - payment.amount_minor)

    if debt.remaining_minor == 0 or not debt.unpaid_scheduled_payments:
        debt.settled = True
        flash(f"'{debt.creditor_name}' is paid off.", "success")
    else:
        flash(f"Logged {format_money(payment.amount_minor)} against '{debt.creditor_name}' -- "
              f"{format_money(debt.remaining_minor)} left.", "success")

    db.session.commit()
    return redirect(url_for("finance.debts"))


@bp.route("/debts/<debt_id>/schedule/clear", methods=["POST"])
@login_required
def clear_debt_schedule(debt_id):
    """Drops the custom schedule and falls back to the simple fixed-amount
    frequency mode."""
    debt = FinanceDebt.query.filter_by(id=debt_id, user_id=current_user.id).first_or_404()
    FinanceDebtPayment.query.filter_by(debt_id=debt.id).delete()
    db.session.commit()
    flash(f"Custom schedule cleared for '{debt.creditor_name}'.", "success")
    return redirect(url_for("finance.debts"))


@bp.route("/due")
@login_required
def due():
    everything = calc.everything_due(current_user.id)
    missed = calc.missed_payments(current_user.id)
    return render_template("finance/due.html", everything=everything, missed=missed)


# ---- Financial calendar (month agenda view) ----

@bp.route("/calendar")
@login_required
def calendar():
    month_str = request.args.get("month")
    if month_str:
        year, month = map(int, month_str.split("-"))
        anchor = date(year, month, 1)
    else:
        anchor = date.today().replace(day=1)

    start, end = calc.month_bounds(anchor)

    events = []
    for bill in FinanceBill.query.filter_by(user_id=current_user.id, active=True).all():
        if bill.next_due_date and start <= bill.next_due_date <= end:
            events.append({"date": bill.next_due_date, "label": bill.name, "kind": "Bill",
                            "amount_minor": -bill.amount_minor})
    for sub in FinanceSubscription.query.filter_by(user_id=current_user.id, status="active").all():
        if sub.next_payment_date and start <= sub.next_payment_date <= end:
            events.append({"date": sub.next_payment_date, "label": sub.name, "kind": "Subscription",
                            "amount_minor": -sub.amount_minor})
    for rec in FinanceRecurringPayment.query.filter_by(user_id=current_user.id, status="confirmed").all():
        if rec.next_payment_date and start <= rec.next_payment_date <= end:
            events.append({"date": rec.next_payment_date, "label": rec.display_name, "kind": "Recurring",
                            "amount_minor": rec.amount_minor})
    for purchase in FinancePlannedPurchase.query.filter_by(user_id=current_user.id, purchased=False).all():
        if purchase.desired_date and start <= purchase.desired_date <= end:
            events.append({"date": purchase.desired_date, "label": purchase.name, "kind": "Planned purchase",
                            "amount_minor": -purchase.total_price_minor})

    events.sort(key=lambda e: e["date"])
    prev_month = (anchor - relativedelta(months=1)).strftime("%Y-%m")
    next_month = (anchor + relativedelta(months=1)).strftime("%Y-%m")

    return render_template("finance/calendar.html", events=events, anchor=anchor,
                            prev_month=prev_month, next_month=next_month)


# ---- Forecast ----

@bp.route("/forecast")
@login_required
def forecast():
    data = calc.financial_forecast(current_user.id)
    safe_balance = calc.safe_discretionary_money(current_user.id)
    return render_template("finance/forecast.html", forecast=data, safe_balance=safe_balance)


# ---- 12-month history ----

@bp.route("/history")
@login_required
def history():
    today = date.today()
    months = []
    for i in range(11, -1, -1):
        month_date = today - relativedelta(months=i)
        start, end = calc.month_bounds(month_date)
        income = db.session.query(db.func.coalesce(db.func.sum(FinanceTransaction.amount_minor), 0)).filter(
            FinanceTransaction.user_id == current_user.id, FinanceTransaction.date >= start,
            FinanceTransaction.date <= end, FinanceTransaction.amount_minor > 0,
            FinanceTransaction.ignored == False,  # noqa: E712
        ).scalar() or 0
        spending = db.session.query(db.func.coalesce(db.func.sum(FinanceTransaction.amount_minor), 0)).filter(
            FinanceTransaction.user_id == current_user.id, FinanceTransaction.date >= start,
            FinanceTransaction.date <= end, FinanceTransaction.amount_minor < 0,
            FinanceTransaction.ignored == False,  # noqa: E712
        ).scalar() or 0
        months.append({
            "label": month_date.strftime("%b %Y"), "income_minor": income,
            "spending_minor": abs(spending), "net_minor": income + spending,
        })

    max_spending = max((m["spending_minor"] for m in months), default=1) or 1
    for m in months:
        m["bar_pct"] = round(m["spending_minor"] / max_spending * 100) if max_spending else 0

    return render_template("finance/history.html", months=months)


# ---- Finance settings ----

@bp.route("/settings", methods=["GET", "POST"])
@login_required
def settings():
    settings_row = calc.get_or_create_settings(current_user.id)
    accounts = FinanceAccount.query.filter_by(user_id=current_user.id, active=True).all()

    if request.method == "POST":
        try:
            minimum_safe_balance = to_minor(request.form.get("minimum_safe_balance", "0") or "0")
            monthly_savings_target = to_minor(request.form.get("monthly_savings_target", "0") or "0")
            annual_savings_target = to_minor(request.form.get("annual_savings_target", "0") or "0")
            emergency_fund_target = to_minor(request.form.get("emergency_fund_target", "0") or "0")
        except ValueError as e:
            flash(str(e), "error")
            return render_template("finance/settings.html", settings=settings_row, accounts=accounts)

        settings_row.default_account_id = request.form.get("default_account_id") or None
        settings_row.minimum_safe_balance_minor = minimum_safe_balance
        settings_row.monthly_savings_target_minor = monthly_savings_target
        settings_row.annual_savings_target_minor = annual_savings_target
        settings_row.emergency_fund_target_minor = emergency_fund_target
        db.session.commit()
        flash("Finance settings saved.", "success")
        return redirect(url_for("finance.settings"))

    return render_template("finance/settings.html", settings=settings_row, accounts=accounts)


# ---- Full-system export registration (Part 10) ----

def _export_finance(user):
    import csv as _csv
    import io as _io
    import json as _json

    txns = FinanceTransaction.query.filter_by(user_id=user.id).order_by(FinanceTransaction.date).all()
    buf = _io.StringIO()
    writer = _csv.writer(buf)
    writer.writerow(["date", "description", "amount", "currency", "category", "account", "type", "tags", "notes"])
    for t in txns:
        writer.writerow([
            t.date.isoformat(), t.clean_description or t.raw_description, to_major(t.amount_minor),
            t.currency, t.category.name if t.category else "", t.account.name if t.account else "",
            t.txn_type, t.tags or "", t.notes or "",
        ])

    accounts = FinanceAccount.query.filter_by(user_id=user.id).all()
    budgets = FinanceBudget.query.filter_by(user_id=user.id).all()
    bills = FinanceBill.query.filter_by(user_id=user.id).all()
    subs = FinanceSubscription.query.filter_by(user_id=user.id).all()
    goals = FinanceSavingsGoal.query.filter_by(user_id=user.id).all()

    summary = {
        "accounts": [{"name": a.name, "type": a.account_type, "balance": to_major(a.balance_minor)} for a in accounts],
        "budgets": [{"category": b.category.name if b.category else None, "monthly_amount": to_major(b.amount_minor)} for b in budgets],
        "bills": [{"name": b.name, "amount": to_major(b.amount_minor), "frequency": b.frequency} for b in bills],
        "subscriptions": [{"name": s.name, "amount": to_major(s.amount_minor), "frequency": s.frequency} for s in subs],
        "savings_goals": [{"name": g.name, "target": to_major(g.target_minor), "saved": to_major(g.current_minor)} for g in goals],
    }

    return {
        "finance_transactions.csv": (buf.getvalue(), "text/csv"),
        "finance_summary.json": (_json.dumps(summary, indent=2, default=str), "application/json"),
    }


register_exporter("finance", "Finance (transactions, accounts, budgets, bills)", _export_finance)
