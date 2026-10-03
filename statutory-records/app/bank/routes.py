import os
import secrets
from datetime import datetime, date

from flask import Blueprint, redirect, url_for, flash, request, session, render_template
from flask_login import login_required, current_user

from app.extensions import db
from app.models import Company, BankConnection, BankAccount, BankTransaction
from app.crypto import encrypt_token, decrypt_token
from app.providers import get_direct_provider, DIRECT_PROVIDERS
from app.providers.base import BankProviderError
from app.providers import gocardless
from app.providers.gocardless import GoCardlessError

bank_bp = Blueprint("bank", __name__, url_prefix="")


def _owned_company_or_404(company_id):
    return Company.query.filter_by(id=company_id, user_id=current_user.id).first_or_404()


def _oauth_redirect_uri(provider_key):
    base = os.environ.get("APP_BASE_URL", request.url_root.rstrip("/"))
    return f"{base}/bank/oauth/{provider_key}/callback"


def _pull_accounts(connection, access_token):
    provider = get_direct_provider(connection.provider)
    remote_accounts = provider.list_accounts(access_token)
    created = 0
    for ra in remote_accounts:
        existing = BankAccount.query.filter_by(
            connection_id=connection.id, provider_account_id=ra["provider_account_id"],
        ).first()
        if existing:
            continue
        balance = provider.get_balance(access_token, ra["provider_account_id"])
        db.session.add(BankAccount(
            connection_id=connection.id, company_id=connection.company_id,
            provider_account_id=ra["provider_account_id"], name=ra["name"],
            account_number=ra.get("account_number"), sort_code=ra.get("sort_code"),
            currency=ra.get("currency", "GBP"), balance_minor=balance["balance_minor"],
        ))
        created += 1
    return created


@bank_bp.route("/companies/<company_id>/bank/connect/<provider_key>")
@login_required
def connect(company_id, provider_key):
    company = _owned_company_or_404(company_id)
    try:
        provider = get_direct_provider(provider_key)
    except BankProviderError as e:
        flash(str(e), "error")
        return redirect(url_for("main.company_detail", company_id=company.id))

    if not provider.is_configured():
        flash(f"{provider.display_name} isn't configured on this server yet — see .env for what's needed.", "error")
        return redirect(url_for("main.company_detail", company_id=company.id))

    state = secrets.token_urlsafe(24)
    session["bank_oauth_state"] = state
    session["bank_oauth_company_id"] = company.id
    session["bank_oauth_provider"] = provider_key
    try:
        auth_url = provider.get_auth_url(_oauth_redirect_uri(provider_key), state)
    except BankProviderError as e:
        flash(str(e), "error")
        return redirect(url_for("main.company_detail", company_id=company.id))
    return redirect(auth_url)


@bank_bp.route("/bank/oauth/<provider_key>/callback")
@login_required
def oauth_callback(provider_key):
    error = request.args.get("error")
    company_id = session.pop("bank_oauth_company_id", None)
    expected_provider = session.pop("bank_oauth_provider", None)
    fallback_redirect = url_for("main.dashboard") if not company_id else url_for("main.company_detail", company_id=company_id)

    if error:
        flash(f"Bank authorisation was not completed: {error}", "error")
        return redirect(fallback_redirect)

    state = request.args.get("state")
    expected_state = session.pop("bank_oauth_state", None)
    if (not state or not expected_state or state != expected_state
            or not company_id or provider_key != expected_provider):
        flash("Bank sign-in couldn't be verified (state mismatch) — please try connecting again.", "error")
        return redirect(fallback_redirect)

    company = _owned_company_or_404(company_id)

    code = request.args.get("code")
    if not code:
        flash("The bank didn't return an authorisation code.", "error")
        return redirect(fallback_redirect)

    try:
        provider = get_direct_provider(provider_key)
        tokens = provider.exchange_code(code, _oauth_redirect_uri(provider_key))
    except BankProviderError as e:
        flash(f"Couldn't complete the bank connection: {e}", "error")
        return redirect(fallback_redirect)

    connection = BankConnection.query.filter_by(company_id=company.id, provider=provider_key).first()
    if not connection:
        connection = BankConnection(company_id=company.id, provider=provider_key)
        db.session.add(connection)

    connection.access_token_encrypted = encrypt_token(tokens["access_token"])
    connection.refresh_token_encrypted = encrypt_token(tokens.get("refresh_token"))
    connection.status = "connected"
    connection.last_synced_at = datetime.utcnow()
    connection.last_error = None
    db.session.commit()

    # If the user hasn't approved access on the bank's side yet (Monzo's
    # in-app push notification, or similar), this 403s -- expected, not a
    # failure. The company page shows a "Sync now" button to retry.
    try:
        created = _pull_accounts(connection, tokens["access_token"])
    except BankProviderError as e:
        connection.last_error = str(e)
        db.session.commit()
        flash(f"{provider.display_name} connected — approve access on the bank's side if prompted, "
              "then come back and hit \"Sync now\".", "warning")
        return redirect(url_for("main.company_detail", company_id=company.id))

    db.session.commit()
    flash(f"{provider.display_name} connected — {created} account(s) added.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


@bank_bp.route("/companies/<company_id>/bank/sync", methods=["POST"])
@login_required
def sync(company_id):
    company = _owned_company_or_404(company_id)
    connection = BankConnection.query.filter_by(company_id=company.id).first()
    if not connection:
        flash("No bank connected for this company yet.", "error")
        return redirect(url_for("main.company_detail", company_id=company.id))

    if connection.provider == "gocardless":
        return _sync_gocardless(company, connection)
    return _sync_direct(company, connection)


def _sync_direct(company, connection):
    """Handles every OAuth-based direct provider (Monzo, Starling, ...) --
    same token-refresh-then-retry shape regardless of which one."""
    provider = get_direct_provider(connection.provider)
    access_token = decrypt_token(connection.access_token_encrypted)

    def _try_sync(token):
        created_accounts = _pull_accounts(connection, token)
        created_txns = 0
        for account in connection.accounts:
            balance = provider.get_balance(token, account.provider_account_id)
            account.balance_minor = balance["balance_minor"]

            existing_ids = {
                t for (t,) in db.session.query(BankTransaction.external_transaction_id)
                .filter_by(account_id=account.id).filter(BankTransaction.external_transaction_id.isnot(None)).all()
            }
            remote_txns = provider.list_transactions(token, account.provider_account_id)
            for rt in remote_txns:
                if rt["external_transaction_id"] in existing_ids:
                    continue
                db.session.add(BankTransaction(
                    account_id=account.id, company_id=company.id,
                    date=datetime.strptime(rt["date"], "%Y-%m-%d").date(),
                    description=rt["description"], amount_minor=rt["amount_minor"],
                    currency=rt.get("currency", "GBP"), external_transaction_id=rt["external_transaction_id"],
                ))
                created_txns += 1
        return created_accounts, created_txns

    try:
        created_accounts, created_txns = _try_sync(access_token)
    except BankProviderError:
        refresh_token = decrypt_token(connection.refresh_token_encrypted)
        if not refresh_token:
            connection.status = "error"
            connection.last_error = "Access expired and no refresh token is stored — reconnect the bank."
            db.session.commit()
            flash(connection.last_error, "error")
            return redirect(url_for("main.company_detail", company_id=company.id))
        try:
            tokens = provider.refresh_access_token(refresh_token)
        except BankProviderError as e:
            connection.status = "error"
            connection.last_error = str(e)
            db.session.commit()
            flash(f"Couldn't refresh the bank connection: {e}", "error")
            return redirect(url_for("main.company_detail", company_id=company.id))
        connection.access_token_encrypted = encrypt_token(tokens["access_token"])
        connection.refresh_token_encrypted = encrypt_token(tokens.get("refresh_token") or refresh_token)
        db.session.commit()
        try:
            created_accounts, created_txns = _try_sync(tokens["access_token"])
        except BankProviderError as e:
            connection.status = "error"
            connection.last_error = str(e)
            db.session.commit()
            flash(f"Bank sync failed: {e}", "error")
            return redirect(url_for("main.company_detail", company_id=company.id))

    connection.status = "connected"
    connection.last_synced_at = datetime.utcnow()
    connection.last_error = None
    db.session.commit()
    flash(f"Synced — {created_txns} new transaction(s).", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


def _sync_gocardless(company, connection):
    try:
        req = gocardless.get_requisition(connection.requisition_id)
    except GoCardlessError as e:
        connection.status = "error"
        connection.last_error = str(e)
        db.session.commit()
        flash(f"Bank sync failed: {e}", "error")
        return redirect(url_for("main.company_detail", company_id=company.id))

    if req.get("status") != "LN":  # "LN" = linked/active in GoCardless's status codes
        connection.status = "expired"
        connection.last_error = "Bank access has expired or was not completed — reconnect this bank."
        db.session.commit()
        flash(connection.last_error, "error")
        return redirect(url_for("main.company_detail", company_id=company.id))

    created_accounts = 0
    created_txns = 0
    for account_id in req.get("accounts", []):
        account = BankAccount.query.filter_by(connection_id=connection.id, provider_account_id=account_id).first()
        try:
            balance_minor, currency = gocardless.get_account_balance_minor(account_id)
        except GoCardlessError as e:
            connection.last_error = str(e)
            db.session.commit()
            flash(f"Bank sync failed: {e}", "error")
            return redirect(url_for("main.company_detail", company_id=company.id))

        if not account:
            try:
                details = gocardless.get_account_details(account_id)
            except GoCardlessError:
                details = {}
            account = BankAccount(
                connection_id=connection.id, company_id=company.id, provider_account_id=account_id,
                name=details.get("name") or details.get("product") or "Connected account",
                account_number=details.get("iban", "")[-8:] if details.get("iban") else None,
                currency=currency, balance_minor=balance_minor,
            )
            db.session.add(account)
            db.session.flush()
            created_accounts += 1
        else:
            account.balance_minor = balance_minor

        existing_ids = {
            t for (t,) in db.session.query(BankTransaction.external_transaction_id)
            .filter_by(account_id=account.id).filter(BankTransaction.external_transaction_id.isnot(None)).all()
        }
        try:
            remote_txns = gocardless.list_transactions(account_id)
        except GoCardlessError as e:
            connection.last_error = str(e)
            db.session.commit()
            flash(f"Bank sync failed: {e}", "error")
            return redirect(url_for("main.company_detail", company_id=company.id))
        for rt in remote_txns:
            if rt["external_transaction_id"] in existing_ids or not rt.get("date"):
                continue
            db.session.add(BankTransaction(
                account_id=account.id, company_id=company.id,
                date=datetime.strptime(rt["date"], "%Y-%m-%d").date(),
                description=rt["description"], amount_minor=rt["amount_minor"],
                currency=rt.get("currency", "GBP"), external_transaction_id=rt["external_transaction_id"],
            ))
            created_txns += 1

    connection.status = "connected"
    connection.last_synced_at = datetime.utcnow()
    connection.last_error = None
    db.session.commit()
    flash(f"Synced — {created_txns} new transaction(s).", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


@bank_bp.route("/companies/<company_id>/bank/disconnect", methods=["POST"])
@login_required
def disconnect(company_id):
    company = _owned_company_or_404(company_id)
    connection = BankConnection.query.filter_by(company_id=company.id).first()
    if connection:
        db.session.delete(connection)
        db.session.commit()
        flash("Bank disconnected.", "success")
    return redirect(url_for("main.company_detail", company_id=company.id))


# ---- GoCardless (Open Banking aggregator -- any other UK bank) ----

@bank_bp.route("/companies/<company_id>/bank/choose")
@login_required
def choose_bank(company_id):
    company = _owned_company_or_404(company_id)
    if not gocardless.is_configured():
        flash("Bank selection isn't configured on this server — sign up free at "
              "https://bankaccountdata.gocardless.com and set GOCARDLESS_SECRET_ID / "
              "GOCARDLESS_SECRET_KEY in .env.", "error")
        return redirect(url_for("main.company_detail", company_id=company.id))

    search = request.args.get("q", "").strip()
    try:
        institutions = gocardless.list_institutions(country="gb", search=search)
    except GoCardlessError as e:
        flash(str(e), "error")
        institutions = []
    return render_template("companies/choose_bank.html", company=company, institutions=institutions, search=search)


@bank_bp.route("/companies/<company_id>/bank/gocardless/connect")
@login_required
def gocardless_connect(company_id):
    company = _owned_company_or_404(company_id)
    institution_id = request.args.get("institution_id")
    institution_name = request.args.get("institution_name", "")
    if not institution_id:
        flash("Choose a bank first.", "error")
        return redirect(url_for("bank.choose_bank", company_id=company.id))

    base = os.environ.get("APP_BASE_URL", request.url_root.rstrip("/"))
    redirect_uri = f"{base}/bank/gocardless/callback"
    reference = secrets.token_urlsafe(24)

    try:
        req = gocardless.create_requisition(institution_id, redirect_uri, reference)
    except GoCardlessError as e:
        flash(str(e), "error")
        return redirect(url_for("bank.choose_bank", company_id=company.id))

    session["gc_reference"] = reference
    session["gc_requisition_id"] = req["id"]
    session["gc_company_id"] = company.id
    session["gc_institution_id"] = institution_id
    session["gc_institution_name"] = institution_name
    return redirect(req["link"])


@bank_bp.route("/bank/gocardless/callback")
@login_required
def gocardless_callback():
    ref = request.args.get("ref")
    expected_ref = session.pop("gc_reference", None)
    requisition_id = session.pop("gc_requisition_id", None)
    company_id = session.pop("gc_company_id", None)
    institution_id = session.pop("gc_institution_id", None)

    fallback = url_for("main.dashboard") if not company_id else url_for("main.company_detail", company_id=company_id)
    if not ref or not expected_ref or ref != expected_ref or not requisition_id or not company_id:
        flash("Bank sign-in couldn't be verified — please try connecting again.", "error")
        return redirect(fallback)

    company = _owned_company_or_404(company_id)

    try:
        req = gocardless.get_requisition(requisition_id)
    except GoCardlessError as e:
        flash(str(e), "error")
        return redirect(fallback)

    if req.get("status") != "LN" or not req.get("accounts"):
        flash("The bank connection wasn't completed — try again.", "warning")
        return redirect(fallback)

    connection = BankConnection(
        company_id=company.id, provider="gocardless", requisition_id=requisition_id,
        institution_id=institution_id, institution_name=session.pop("gc_institution_name", None),
        status="connected", last_synced_at=datetime.utcnow(),
    )
    db.session.add(connection)
    db.session.commit()

    return _sync_gocardless(company, connection)
