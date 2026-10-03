from flask import Blueprint, render_template, redirect, url_for, flash, request
from flask_login import login_required, current_user

from app.extensions import db
from app.core.events.bus import emit, on
from app.core.search.registry import register_search_provider, SearchResult
from app.core.export.registry import register_exporter

from .models import (
    Merchant, MerchantAlias, MerchantCategory, MerchantCompany,
    MerchantUserMapping, MerchantTransactionLink,
)
from .seed_data import seed_merchants
from .matching import match_description, remember_user_mapping, invalidate_merchant_cache
from .companies_house import local_company_search, sync_companies, is_configured
from . import stats

bp = Blueprint("merchant", __name__, url_prefix="/merchants", template_folder="templates")


def install_seed_data():
    """Runs the merchant directory seed. Called once at module enable time
    (loader calls any `on_enable` hook if present) and defensively from the
    blueprint's before_request, so seed data exists even for requests that
    reach this module via an event handler rather than a page load."""
    seed_merchants()


install_seed_data()


@bp.before_request
def _ensure_seed():
    seed_merchants()


def money(amount_minor, currency="GBP"):
    symbols = {"GBP": "£", "USD": "$", "EUR": "€"}
    symbol = symbols.get(currency, currency + " ")
    sign = "-" if amount_minor < 0 else ""
    return f"{sign}{symbol}{abs(amount_minor) / 100:,.2f}"


bp.add_app_template_filter(money, "money")


def _finance_transaction_model():
    try:
        import importlib
        from app.core.modules.models import ModuleRecord
        finance_record = ModuleRecord.query.filter_by(id="finance", status="enabled").first()
        if not finance_record:
            return None
        return importlib.import_module("finance.models").FinanceTransaction
    except Exception:
        return None


# ---- Directory ----

@bp.route("/")
@login_required
def index():
    search = request.args.get("q", "").strip()
    query = Merchant.query.filter_by(active=True)
    if search:
        query = query.filter(Merchant.display_name.ilike(f"%{search}%"))
    merchants = query.order_by(Merchant.display_name).all()
    categories = MerchantCategory.query.order_by(MerchantCategory.name).all()

    finance_installed = _finance_transaction_model() is not None
    top = stats.top_merchants(current_user.id, "this_month") if finance_installed else []

    return render_template("merchant/index.html", merchants=merchants, search=search,
                            categories=categories, top=top, finance_installed=finance_installed)


@bp.route("/top")
@login_required
def top():
    period = request.args.get("period", "this_month")
    results = stats.top_merchants(current_user.id, period)
    return render_template("merchant/top.html", results=results, period=period)


@bp.route("/<merchant_id>")
@login_required
def detail(merchant_id):
    merchant = Merchant.query.get_or_404(merchant_id)
    summary = stats.merchant_spending_summary(current_user.id, merchant_id)
    history = stats.merchant_monthly_history(current_user.id, merchant_id)
    return render_template("merchant/detail.html", merchant=merchant, summary=summary, history=history)


@bp.route("/<merchant_id>/aliases/new", methods=["POST"])
@login_required
def add_alias(merchant_id):
    merchant = Merchant.query.get_or_404(merchant_id)
    alias_text = request.form.get("alias_text", "").strip().upper()
    if alias_text:
        existing = MerchantAlias.query.filter_by(merchant_id=merchant_id, alias_text=alias_text).first()
        if not existing:
            db.session.add(MerchantAlias(merchant_id=merchant_id, alias_text=alias_text))
            db.session.commit()
            invalidate_merchant_cache()
    return redirect(url_for("merchant.detail", merchant_id=merchant_id))


# ---- UK companies ----

@bp.route("/companies")
@login_required
def companies():
    search = request.args.get("q", "").strip()
    results = local_company_search(search) if search else MerchantCompany.query.limit(20).all()
    return render_template("merchant/companies.html", companies=results, search=search,
                            live_configured=is_configured())


@bp.route("/companies/sync", methods=["POST"])
@login_required
def sync_companies_route():
    result = sync_companies()
    flash(result.get("message", "Sync attempted."), "success" if result.get("status") != "not_configured" else "warning")
    return redirect(url_for("merchant.companies"))


# ---- Matching / corrections ----

@bp.route("/rematch", methods=["POST"])
@login_required
def rematch():
    FinanceTransaction = _finance_transaction_model()
    if FinanceTransaction is None:
        flash("The Finance module isn't installed — nothing to match against.", "error")
        return redirect(url_for("merchant.index"))

    already_linked = {
        row.transaction_id for row in MerchantTransactionLink.query.filter_by(user_id=current_user.id).all()
    }
    transactions = FinanceTransaction.query.filter_by(user_id=current_user.id).all()

    matched_count = 0
    for txn in transactions:
        if txn.id in already_linked:
            continue
        description = txn.clean_description or txn.raw_description
        merchant, stage = match_description(current_user.id, description)
        if merchant:
            db.session.add(MerchantTransactionLink(
                user_id=current_user.id, transaction_id=txn.id, merchant_id=merchant.id, match_stage=stage,
            ))
            matched_count += 1
            emit("merchant.matched", transaction_id=txn.id, merchant_id=merchant.id, stage=stage)

    db.session.commit()
    flash(f"Matched {matched_count} transactions to merchants.", "success")
    return redirect(url_for("merchant.index"))


@bp.route("/correct/<transaction_id>", methods=["POST"])
@login_required
def correct_match(transaction_id):
    """Lets the user say 'always map this description to merchant X'."""
    merchant_id = request.form.get("merchant_id")
    FinanceTransaction = _finance_transaction_model()
    if not merchant_id or FinanceTransaction is None:
        return redirect(url_for("merchant.index"))

    txn = FinanceTransaction.query.filter_by(id=transaction_id, user_id=current_user.id).first_or_404()
    description = txn.clean_description or txn.raw_description
    remember_user_mapping(current_user.id, description, merchant_id)

    link = MerchantTransactionLink.query.filter_by(transaction_id=transaction_id).first()
    if link:
        link.merchant_id = merchant_id
        link.match_stage = "user_mapping"
    else:
        db.session.add(MerchantTransactionLink(
            user_id=current_user.id, transaction_id=transaction_id, merchant_id=merchant_id,
            match_stage="user_mapping",
        ))
    db.session.commit()
    flash("Correction saved — future transactions with this description will match automatically.", "success")
    return redirect(request.referrer or url_for("merchant.index"))


# ---- Search provider registration ----

def _search_provider(query, user):
    results = []
    for m in Merchant.query.filter(Merchant.display_name.ilike(f"%{query}%")).limit(10).all():
        results.append(SearchResult(title=m.display_name, url=f"/merchants/{m.id}",
                                     category="Merchant", snippet=m.merchant_type or ""))
    return results


register_search_provider("merchant", _search_provider)


# ---- Automatic matching on transaction import ----

@on("transaction.imported")
def _on_transaction_imported(**payload):
    """Best-effort automatic matching right after an import. Wrapped
    defensively since event handlers must never break the request that
    triggered them."""
    FinanceTransaction = _finance_transaction_model()
    if FinanceTransaction is None:
        return
    batch_id = payload.get("batch_id")
    if not batch_id:
        return
    try:
        transactions = FinanceTransaction.query.filter_by(import_batch_id=batch_id).all()
        already_linked = {
            row.transaction_id for row in MerchantTransactionLink.query.filter(
                MerchantTransactionLink.transaction_id.in_([t.id for t in transactions])
            ).all()
        }
        for txn in transactions:
            if txn.id in already_linked:
                continue
            description = txn.clean_description or txn.raw_description
            merchant, stage = match_description(txn.user_id, description)
            if merchant:
                db.session.add(MerchantTransactionLink(
                    user_id=txn.user_id, transaction_id=txn.id, merchant_id=merchant.id, match_stage=stage,
                ))
        db.session.commit()
    except Exception:
        db.session.rollback()


@on("transaction.deleted")
def _on_transaction_deleted(**payload):
    """A finance transaction was deleted (manually, or by the dedupe sweep)
    -- drop our loose (non-FK) link to it so it doesn't dangle. Best-effort,
    same convention as every other handler here."""
    transaction_id = payload.get("transaction_id")
    if not transaction_id:
        return
    try:
        MerchantTransactionLink.query.filter_by(transaction_id=transaction_id).delete()
        db.session.commit()
    except Exception:
        db.session.rollback()


# ---- Full-system export registration (Part 10) ----

def _export_merchant(user):
    import json as _json
    mappings = MerchantUserMapping.query.filter_by(user_id=user.id).all()
    links = MerchantTransactionLink.query.filter_by(user_id=user.id).all()

    payload = {
        "user_corrections": [
            {"description": m.description_text, "merchant": (db.session.get(Merchant, m.merchant_id) or {}).display_name
             if db.session.get(Merchant, m.merchant_id) else None}
            for m in mappings
        ],
        "matched_transactions": len(links),
    }
    return {"merchant_corrections.json": (_json.dumps(payload, indent=2, default=str), "application/json")}


register_exporter("merchant", "Merchant corrections", _export_merchant)
