"""CSV bank statement import with column auto-detection, preview, and
duplicate detection. OFX/QFX and PDF import are listed in REMAINING_WORK.txt —
CSV covers the common export format from most UK banks and is implemented
fully here; the same preview/confirm/dedupe pipeline is designed to accept
additional parsers without changing the route logic.
"""
import csv
import hashlib
import io
from datetime import datetime

from .money import to_minor

CANDIDATE_DATE_FIELDS = ["date", "transaction date", "posted date", "value date"]
CANDIDATE_DESC_FIELDS = ["description", "merchant", "narrative", "details", "reference", "name"]
CANDIDATE_AMOUNT_FIELDS = ["amount", "value"]
CANDIDATE_DEBIT_FIELDS = ["debit", "money out", "paid out", "withdrawal"]
CANDIDATE_CREDIT_FIELDS = ["credit", "money in", "paid in", "deposit"]
CANDIDATE_BALANCE_FIELDS = ["balance", "running balance"]
CANDIDATE_ID_FIELDS = ["transaction id", "id", "reference number"]

DATE_FORMATS = ["%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y", "%m/%d/%Y", "%d %b %Y", "%d %B %Y"]


def _normalise_header(h):
    return (h or "").strip().lower()


def _find_field(headers_lower, candidates):
    for c in candidates:
        if c in headers_lower:
            return headers_lower[c]
    return None


def detect_columns(csv_text):
    reader = csv.reader(io.StringIO(csv_text))
    rows = list(reader)
    if not rows:
        return None, []
    headers = rows[0]
    headers_lower = {_normalise_header(h): h for h in headers}

    mapping = {
        "date": _find_field(headers_lower, CANDIDATE_DATE_FIELDS),
        "description": _find_field(headers_lower, CANDIDATE_DESC_FIELDS),
        "amount": _find_field(headers_lower, CANDIDATE_AMOUNT_FIELDS),
        "debit": _find_field(headers_lower, CANDIDATE_DEBIT_FIELDS),
        "credit": _find_field(headers_lower, CANDIDATE_CREDIT_FIELDS),
        "balance": _find_field(headers_lower, CANDIDATE_BALANCE_FIELDS),
        "transaction_id": _find_field(headers_lower, CANDIDATE_ID_FIELDS),
    }
    return mapping, headers


def _parse_date(value):
    value = (value or "").strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(value, fmt).date()
        except ValueError:
            continue
    return None


def _parse_amount_minor(row, mapping):
    if mapping.get("amount"):
        raw = row.get(mapping["amount"], "").replace(",", "").replace("£", "").strip()
        if raw:
            try:
                return to_minor(raw)
            except Exception:
                return None
    debit_val = row.get(mapping.get("debit") or "", "").replace(",", "").replace("£", "").strip()
    credit_val = row.get(mapping.get("credit") or "", "").replace(",", "").replace("£", "").strip()
    if debit_val:
        try:
            return -abs(to_minor(debit_val))
        except Exception:
            return None
    if credit_val:
        try:
            return abs(to_minor(credit_val))
        except Exception:
            return None
    return None


def dedupe_hash(account_id, date, amount_minor, description):
    key = f"{account_id}|{date}|{amount_minor}|{(description or '').strip().lower()}"
    return hashlib.sha256(key.encode()).hexdigest()


def parse_csv_preview(csv_text, account_id):
    """Returns list[dict] ready to preview/import, each with a computed dedupe_hash."""
    mapping, headers = detect_columns(csv_text)
    if not mapping or not mapping.get("date") or (not mapping.get("description")):
        raise ValueError(
            "Could not detect date/description columns automatically — "
            "check the file has header row(s) with recognisable names."
        )

    reader = csv.DictReader(io.StringIO(csv_text))
    parsed = []
    for row in reader:
        date = _parse_date(row.get(mapping["date"], ""))
        description = (row.get(mapping["description"], "") or "").strip()
        amount_minor = _parse_amount_minor(row, mapping)
        if date is None or amount_minor is None:
            continue

        external_id = row.get(mapping["transaction_id"], "").strip() if mapping.get("transaction_id") else None

        parsed.append({
            "date": date,
            "raw_description": description,
            "clean_description": description,
            "amount_minor": amount_minor,
            "direction": "credit" if amount_minor >= 0 else "debit",
            "external_transaction_id": external_id or None,
            "dedupe_hash": dedupe_hash(account_id, date, amount_minor, description),
        })
    return parsed
