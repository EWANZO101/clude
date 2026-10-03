from flask import Blueprint, render_template, request, redirect, url_for, flash, jsonify
from flask_login import login_required, current_user
from app.extensions import db
from app.models.integration import IntegrationConfig, IntegrationLog
from app.models.banking import ImportedBankTransaction, STATUS_UNMATCHED, STATUS_MATCHED
from app.models.accounting import Account, ASSET, EXPENSE, REVENUE
from app.accounting.engine import post_journal_entry, UnbalancedEntryError, InvalidLineError
from app.businesses.decorators import require_current_business, require_permission
from app.integrations.dispatcher import run_integration, get_or_create_config
from app.integrations.bank_csv import import_bank_csv, BankCsvError
from app.integrations.stripe_like import handle_payment_succeeded_event, WebhookError

integrations_bp = Blueprint("integrations", __name__, template_folder="../templates/integrations")

PROVIDERS = ["bank_csv", "stripe"]


@integrations_bp.route("/")
@login_required
@require_current_business
@require_permission("view")
def list_integrations(business):
    configs = {c.provider: c for c in IntegrationConfig.query.filter_by(business_id=business.id).all()}
    for provider in PROVIDERS:
        if provider not in configs:
            configs[provider] = get_or_create_config(business.id, provider)
    logs = IntegrationLog.query.filter_by(business_id=business.id).order_by(IntegrationLog.created_at.desc()).limit(30).all()
    return render_template("integrations/list.html", configs=configs, logs=logs)


@integrations_bp.route("/<provider>/toggle", methods=["POST"])
@login_required
@require_current_business
@require_permission("manage_settings")
def toggle_integration(business, provider):
    config = get_or_create_config(business.id, provider)
    config.is_enabled = not config.is_enabled
    db.session.commit()
    flash(f"{provider} {'enabled' if config.is_enabled else 'disabled'}.", "success")
    return redirect(url_for("integrations.list_integrations"))


@integrations_bp.route("/bank-csv/import", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def bank_csv_import(business):
    accounts = Account.query.filter_by(business_id=business.id, account_type=ASSET, is_archived=False).all()

    if request.method == "POST":
        file = request.files.get("file")
        bank_account_id = request.form.get("bank_account_id")
        if not file or not bank_account_id:
            flash("Choose a bank account and a CSV file.", "error")
            return render_template("integrations/bank_csv_import.html", accounts=accounts)

        success, result = run_integration(
            "bank_csv", business.id, "import",
            import_bank_csv, business.id, bank_account_id, file.stream,
        )
        if success:
            flash(f"Imported {result['imported_count']} transactions.", "success")
            return redirect(url_for("integrations.bank_transactions"))
        else:
            flash(f"Import failed (logged): {result}", "error")
            return render_template("integrations/bank_csv_import.html", accounts=accounts)

    return render_template("integrations/bank_csv_import.html", accounts=accounts)


@integrations_bp.route("/bank-csv/transactions")
@login_required
@require_current_business
@require_permission("view")
def bank_transactions(business):
    txns = (
        ImportedBankTransaction.query.filter_by(business_id=business.id, status=STATUS_UNMATCHED)
        .order_by(ImportedBankTransaction.transaction_date.desc())
        .all()
    )
    categories = Account.query.filter(
        Account.business_id == business.id, Account.is_archived == False,  # noqa: E712
        Account.account_type.in_([EXPENSE, REVENUE]),
    ).all()
    return render_template("integrations/bank_transactions.html", transactions=txns, categories=categories)


@integrations_bp.route("/bank-csv/transactions/<transaction_id>/match", methods=["POST"])
@login_required
@require_current_business
@require_permission("edit")
def match_bank_transaction(business, transaction_id):
    txn = ImportedBankTransaction.query.filter_by(id=transaction_id, business_id=business.id).first_or_404()
    category_account_id = request.form.get("category_account_id")

    if txn.amount >= 0:
        lines = [
            {"account_id": txn.bank_account_id, "debit": txn.amount},
            {"account_id": category_account_id, "credit": txn.amount},
        ]
    else:
        lines = [
            {"account_id": category_account_id, "debit": -txn.amount},
            {"account_id": txn.bank_account_id, "credit": -txn.amount},
        ]

    try:
        entry = post_journal_entry(
            business_id=business.id,
            entry_date=txn.transaction_date,
            lines=lines,
            description=txn.description,
            source_type="bank_import",
            source_id=txn.id,
            created_by_id=current_user.id,
        )
    except (UnbalancedEntryError, InvalidLineError) as e:
        flash(f"Could not match transaction: {e}", "error")
        return redirect(url_for("integrations.bank_transactions"))

    txn.status = STATUS_MATCHED
    txn.matched_journal_entry_id = entry.id
    db.session.commit()
    flash("Transaction matched and posted to the ledger.", "success")
    return redirect(url_for("integrations.bank_transactions"))


@integrations_bp.route("/stripe/webhook", methods=["POST"])
def stripe_webhook():
    """No @login_required — this is called by an external service, not a
    logged-in user. Authenticity is checked via a shared secret instead."""
    payload = request.get_json(silent=True) or {}
    business_id = payload.get("business_id")
    provided_secret = request.headers.get("X-Webhook-Secret")

    config = IntegrationConfig.query.filter_by(business_id=business_id, provider="stripe").first()
    if config is None or not config.is_enabled:
        return jsonify({"error": "Stripe integration is not enabled for this business."}), 403
    if not config.secret or provided_secret != config.secret:
        return jsonify({"error": "Invalid webhook secret."}), 401

    success, result = run_integration(
        "stripe", business_id, payload.get("type", "payment_succeeded"),
        handle_payment_succeeded_event, payload,
    )
    if success:
        return jsonify({"status": "ok", "result": result})
    # Failure is logged (via run_integration) and isolated; we still return
    # a clear error to the caller rather than pretending it worked.
    return jsonify({"status": "error", "message": result}), 422
