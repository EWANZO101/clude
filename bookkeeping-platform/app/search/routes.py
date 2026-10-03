from flask import Blueprint, render_template, request
from flask_login import login_required
from app.models.party import Customer, Supplier
from app.models.invoice import Invoice
from app.models.bill import Bill
from app.models.accounting import Account, JournalEntry
from app.businesses.decorators import require_current_business, require_permission

search_bp = Blueprint("search", __name__, template_folder="../templates/search")


@search_bp.route("/")
@login_required
@require_current_business
@require_permission("view")
def search(business):
    query = (request.args.get("q") or "").strip()
    results = {"customers": [], "suppliers": [], "invoices": [], "bills": [], "accounts": [], "journal_entries": []}

    if query:
        like = f"%{query}%"
        results["customers"] = Customer.query.filter(
            Customer.business_id == business.id,
            (Customer.name.ilike(like)) | (Customer.email.ilike(like)),
        ).limit(20).all()
        results["suppliers"] = Supplier.query.filter(
            Supplier.business_id == business.id,
            (Supplier.name.ilike(like)) | (Supplier.email.ilike(like)),
        ).limit(20).all()
        results["invoices"] = Invoice.query.filter(
            Invoice.business_id == business.id, Invoice.invoice_number.ilike(like),
        ).limit(20).all()
        results["bills"] = Bill.query.filter(
            Bill.business_id == business.id, Bill.bill_number.ilike(like),
        ).limit(20).all()
        results["accounts"] = Account.query.filter(
            Account.business_id == business.id,
            (Account.name.ilike(like)) | (Account.code.ilike(like)),
        ).limit(20).all()
        results["journal_entries"] = JournalEntry.query.filter(
            JournalEntry.business_id == business.id, JournalEntry.description.ilike(like),
        ).limit(20).all()

    total = sum(len(v) for v in results.values())
    return render_template("search/results.html", query=query, results=results, total=total)
