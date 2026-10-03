from datetime import datetime, date
from decimal import Decimal
from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app.extensions import db
from app.models.party import Customer
from app.models.accounting import Account, REVENUE, ASSET
from app.models.invoice import Invoice, InvoiceLine, Payment, STATUS_DRAFT, STATUS_SENT, STATUS_PAID, STATUS_PARTIALLY_PAID
from app.accounting.engine import post_journal_entry, UnbalancedEntryError, InvalidLineError
from app.invoices.services import record_invoice_payment, InvoicePaymentError
from app.businesses.decorators import require_current_business, require_permission

invoices_bp = Blueprint("invoices", __name__, template_folder="../templates/invoices")


def _receivable_account(business):
    return Account.query.filter_by(business_id=business.id, code="1100").first()


@invoices_bp.route("/")
@login_required
@require_current_business
@require_permission("view")
def list_invoices(business):
    invoices = Invoice.query.filter_by(business_id=business.id).order_by(Invoice.issue_date.desc()).all()
    return render_template("invoices/list.html", invoices=invoices)


@invoices_bp.route("/new", methods=["GET", "POST"])
@login_required
@require_current_business
@require_permission("create")
def new_invoice(business):
    customers = Customer.query.filter_by(business_id=business.id, is_archived=False).order_by(Customer.name).all()
    revenue_accounts = Account.query.filter_by(business_id=business.id, account_type=REVENUE, is_archived=False).all()

    if request.method == "POST":
        customer_id = request.form.get("customer_id")
        invoice_number = request.form.get("invoice_number", "").strip()
        issue_date_str = request.form.get("issue_date")
        due_date_str = request.form.get("due_date")

        if not customer_id or not invoice_number:
            flash("Customer and invoice number are required.", "error")
            return render_template("invoices/new.html", customers=customers, revenue_accounts=revenue_accounts)

        invoice = Invoice(
            business_id=business.id,
            customer_id=customer_id,
            invoice_number=invoice_number,
            issue_date=datetime.strptime(issue_date_str, "%Y-%m-%d").date() if issue_date_str else date.today(),
            due_date=datetime.strptime(due_date_str, "%Y-%m-%d").date() if due_date_str else None,
            currency=business.base_currency,
            status=STATUS_DRAFT,
        )
        db.session.add(invoice)
        db.session.flush()

        descriptions = request.form.getlist("line_description")
        quantities = request.form.getlist("line_quantity")
        prices = request.form.getlist("line_unit_price")
        tax_rates = request.form.getlist("line_tax_rate")
        account_ids = request.form.getlist("line_account_id")

        for desc, qty, price, tax, acc_id in zip(descriptions, quantities, prices, tax_rates, account_ids):
            if not desc:
                continue
            db.session.add(InvoiceLine(
                invoice_id=invoice.id,
                account_id=acc_id,
                description=desc,
                quantity=Decimal(qty or "1"),
                unit_price=Decimal(price or "0"),
                tax_rate=Decimal(tax or "0"),
            ))

        db.session.commit()
        flash("Invoice created as draft.", "success")
        return redirect(url_for("invoices.view_invoice", invoice_id=invoice.id))

    return render_template("invoices/new.html", customers=customers, revenue_accounts=revenue_accounts)


@invoices_bp.route("/<invoice_id>")
@login_required
@require_current_business
@require_permission("view")
def view_invoice(business, invoice_id):
    invoice = Invoice.query.filter_by(id=invoice_id, business_id=business.id).first_or_404()
    accounts = Account.query.filter_by(business_id=business.id, account_type=ASSET, is_archived=False).all()
    return render_template("invoices/view.html", invoice=invoice, accounts=accounts)


@invoices_bp.route("/<invoice_id>/send", methods=["POST"])
@login_required
@require_current_business
@require_permission("edit")
def send_invoice(business, invoice_id):
    invoice = Invoice.query.filter_by(id=invoice_id, business_id=business.id).first_or_404()
    if invoice.status != STATUS_DRAFT:
        flash("Only draft invoices can be sent.", "error")
        return redirect(url_for("invoices.view_invoice", invoice_id=invoice.id))

    receivable = _receivable_account(business)
    lines = [{"account_id": receivable.id, "debit": invoice.total()}]
    for line in invoice.lines:
        line_total = line.quantity * line.unit_price
        lines.append({"account_id": line.account_id, "credit": line_total})
        tax_amount = line_total * (line.tax_rate / 100)
        if tax_amount:
            tax_account = Account.query.filter_by(business_id=business.id, code="2200").first()
            lines.append({"account_id": tax_account.id, "credit": tax_amount})

    try:
        entry = post_journal_entry(
            business_id=business.id,
            entry_date=invoice.issue_date,
            lines=lines,
            description=f"Invoice {invoice.invoice_number}",
            source_type="invoice",
            source_id=invoice.id,
            created_by_id=current_user.id,
        )
    except (UnbalancedEntryError, InvalidLineError) as e:
        flash(f"Could not send invoice: {e}", "error")
        return redirect(url_for("invoices.view_invoice", invoice_id=invoice.id))

    invoice.journal_entry_id = entry.id
    invoice.status = STATUS_SENT
    db.session.commit()
    flash("Invoice sent and posted to the ledger.", "success")
    return redirect(url_for("invoices.view_invoice", invoice_id=invoice.id))


@invoices_bp.route("/<invoice_id>/record-payment", methods=["POST"])
@login_required
@require_current_business
@require_permission("edit")
def record_payment(business, invoice_id):
    invoice = Invoice.query.filter_by(id=invoice_id, business_id=business.id).first_or_404()
    if invoice.status not in (STATUS_SENT, STATUS_PARTIALLY_PAID, "overdue"):
        flash("This invoice cannot receive payments in its current status.", "error")
        return redirect(url_for("invoices.view_invoice", invoice_id=invoice.id))

    amount = request.form.get("amount") or "0"
    deposit_account_id = request.form.get("deposit_account_id")
    payment_date_str = request.form.get("payment_date")
    payment_date = datetime.strptime(payment_date_str, "%Y-%m-%d").date() if payment_date_str else None

    try:
        record_invoice_payment(
            business=business, invoice=invoice, amount=amount,
            deposit_account_id=deposit_account_id, payment_date=payment_date,
            created_by_id=current_user.id,
        )
    except (InvoicePaymentError, UnbalancedEntryError, InvalidLineError) as e:
        flash(f"Could not record payment: {e}", "error")
        return redirect(url_for("invoices.view_invoice", invoice_id=invoice.id))

    flash("Payment recorded.", "success")
    return redirect(url_for("invoices.view_invoice", invoice_id=invoice.id))
