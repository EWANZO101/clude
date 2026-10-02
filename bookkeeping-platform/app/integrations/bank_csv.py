import csv
import io
import uuid
from datetime import datetime
from decimal import Decimal, InvalidOperation
from app.extensions import db
from app.models.banking import ImportedBankTransaction


class BankCsvError(Exception):
    pass


REQUIRED_COLUMNS = {"date", "description", "amount"}


def import_bank_csv(business_id, bank_account_id, file_stream):
    """Parses a CSV with columns: date, description, amount (positive =
    money in, negative = money out). Raises BankCsvError on malformed input
    — the dispatcher is what turns that into an isolated, logged failure
    rather than a crash."""
    text = file_stream.read().decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames is None or not REQUIRED_COLUMNS.issubset({c.strip().lower() for c in reader.fieldnames}):
        raise BankCsvError(f"CSV must have columns: {', '.join(sorted(REQUIRED_COLUMNS))}")

    batch_id = str(uuid.uuid4())
    count = 0
    for row in reader:
        row = {k.strip().lower(): v for k, v in row.items()}
        try:
            tx_date = datetime.strptime(row["date"].strip(), "%Y-%m-%d").date()
            amount = Decimal(row["amount"].strip())
        except (ValueError, InvalidOperation, KeyError, AttributeError) as e:
            raise BankCsvError(f"Could not parse row {row}: {e}")

        db.session.add(ImportedBankTransaction(
            business_id=business_id,
            bank_account_id=bank_account_id,
            transaction_date=tx_date,
            description=(row.get("description") or "").strip()[:500],
            amount=amount,
            import_batch_id=batch_id,
            raw_row=str(row),
        ))
        count += 1

    db.session.commit()
    return {"batch_id": batch_id, "imported_count": count}
