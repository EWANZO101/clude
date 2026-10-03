"""Server side of the offline sync protocol.

Contract: every record an offline client queues carries a client_uuid it
generated itself, before it ever talked to the server. When connectivity
returns, the client POSTs its queue here. For each item we look up whether
that (business, client_uuid) pair already exists — if it does, the item was
already synced (e.g. the client retried after a dropped response) and we
report it as a no-op duplicate rather than creating a second transaction.
We never silently overwrite an existing record during sync.
"""
from datetime import datetime
from decimal import Decimal, InvalidOperation
from flask import Blueprint, request, jsonify
from flask_login import login_required, current_user
from app.extensions import db
from app.models.expense import Expense
from app.accounting.engine import post_journal_entry, UnbalancedEntryError, InvalidLineError
from app.businesses.decorators import require_current_business

sync_bp = Blueprint("sync", __name__)


@sync_bp.route("/ping")
@login_required
def ping():
    """Cheap connectivity + auth check the client can poll before flushing
    its queue, so it doesn't burn a sync attempt against a dead session."""
    business = current_user.current_business()
    return jsonify({
        "status": "ok",
        "server_time": datetime.utcnow().isoformat() + "Z",
        "business_id": business.id if business else None,
    })


@sync_bp.route("/expenses", methods=["POST"])
@login_required
@require_current_business
def sync_expenses(business):
    payload = request.get_json(silent=True) or {}
    items = payload.get("items", [])
    if not isinstance(items, list):
        return jsonify({"error": "items must be a list"}), 400

    results = []
    for item in items:
        client_uuid = item.get("client_uuid")
        if not client_uuid:
            results.append({"client_uuid": None, "status": "error", "message": "client_uuid is required"})
            continue

        existing = Expense.query.filter_by(business_id=business.id, client_uuid=client_uuid).first()
        if existing:
            results.append({"client_uuid": client_uuid, "status": "duplicate", "server_id": existing.id})
            continue

        try:
            amount = Decimal(str(item.get("amount", "0")))
            expense_date = (
                datetime.strptime(item["expense_date"], "%Y-%m-%d").date()
                if item.get("expense_date") else datetime.utcnow().date()
            )
        except (InvalidOperation, ValueError, KeyError):
            results.append({"client_uuid": client_uuid, "status": "error", "message": "Invalid amount or date."})
            continue

        description = (item.get("description") or "").strip()
        expense_account_id = item.get("expense_account_id")
        paid_from_account_id = item.get("paid_from_account_id")

        if not description or amount <= 0 or not expense_account_id or not paid_from_account_id:
            results.append({"client_uuid": client_uuid, "status": "error", "message": "Missing required fields."})
            continue

        try:
            entry = post_journal_entry(
                business_id=business.id,
                entry_date=expense_date,
                lines=[
                    {"account_id": expense_account_id, "debit": amount},
                    {"account_id": paid_from_account_id, "credit": amount},
                ],
                description=description,
                source_type="expense_offline_sync",
                created_by_id=current_user.id,
            )
        except (UnbalancedEntryError, InvalidLineError) as e:
            results.append({"client_uuid": client_uuid, "status": "error", "message": str(e)})
            continue

        expense = Expense(
            business_id=business.id,
            supplier_id=item.get("supplier_id") or None,
            expense_date=expense_date,
            description=description,
            amount=amount,
            expense_account_id=expense_account_id,
            paid_from_account_id=paid_from_account_id,
            is_reimbursable=bool(item.get("is_reimbursable")),
            journal_entry_id=entry.id,
            client_uuid=client_uuid,
        )
        db.session.add(expense)
        db.session.commit()
        results.append({"client_uuid": client_uuid, "status": "created", "server_id": expense.id})

    return jsonify({"results": results})
