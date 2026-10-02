"""
One pass: refreshes balance + pulls new transactions for every connected
Monzo account, across all users. Reuses the same import/dedup logic as the
"Sync now" button (finance.routes._import_monzo_transactions) so behaviour
stays identical — this just runs it on a timer instead of a click.

Meant to be called repeatedly by monzo_auto_sync.sh, not run alone in a loop
itself.

IMPORTANT: finance/checklist/etc. are loaded by the app's own module loader
under their bare package name (e.g. `finance`, not `module_packages.finance`)
— it adds module_packages/ to sys.path itself. Importing them any other way
creates a second, separate copy of the same SQLAlchemy models against the
same metadata and crashes with "Table already defined". So: call
create_app() FIRST (which does that loading), and only import `finance.*`
by its bare name afterwards, never `module_packages.finance.*`.
"""
import sys
from datetime import datetime, timedelta

from app import create_app

app = create_app()

from finance.models import FinanceBankConnection, FinanceAccount  # noqa: E402
from finance.providers.monzo import get_provider  # noqa: E402
from finance.providers.base import BankProviderError  # noqa: E402
from finance.crypto import encrypt_token, decrypt_token  # noqa: E402
from finance.routes import _import_monzo_transactions  # noqa: E402
from app.extensions import db  # noqa: E402

provider = get_provider("monzo")


def sync_connection(connection):
    access_token = decrypt_token(connection.access_token_encrypted)
    accounts = FinanceAccount.query.filter_by(bank_connection_id=connection.id, active=True).all()
    if not accounts:
        return 0, 0

    def _run(token):
        remote_accounts = provider.list_accounts(token)
        total_imported = 0
        for account in accounts:
            match = next((a for a in remote_accounts if a["name"] == account.name), None)
            if not match:
                continue
            balance = provider.get_balance(token, match["provider_account_id"])
            account.balance_minor = balance["balance_minor"]

            since = None
            if connection.last_synced_at:
                since = (connection.last_synced_at - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
            total_imported += _import_monzo_transactions(
                connection.user_id, account, provider, token,
                match["provider_account_id"], since=since,
            )
        return total_imported

    try:
        imported = _run(access_token)
    except BankProviderError:
        refresh_token = decrypt_token(connection.refresh_token_encrypted)
        if not refresh_token:
            raise
        new_tokens = provider.refresh_access_token(refresh_token)
        connection.access_token_encrypted = encrypt_token(new_tokens["access_token"])
        connection.refresh_token_encrypted = encrypt_token(new_tokens.get("refresh_token"))
        db.session.commit()
        imported = _run(new_tokens["access_token"])

    connection.status = "connected"
    connection.last_synced_at = datetime.utcnow()
    connection.last_error = None
    return len(accounts), imported


def main():
    with app.app_context():
        connections = FinanceBankConnection.query.filter_by(provider="monzo", status="connected").all()
        if not connections:
            print(f"[{datetime.utcnow().isoformat()}] no connected Monzo accounts to sync")
            return

        for connection in connections:
            try:
                n_accounts, n_imported = sync_connection(connection)
                db.session.commit()
                print(f"[{datetime.utcnow().isoformat()}] connection {connection.id}: "
                      f"{n_accounts} account(s), {n_imported} new transaction(s)")
            except BankProviderError as e:
                connection.status = "error"
                connection.last_error = str(e)
                db.session.commit()
                print(f"[{datetime.utcnow().isoformat()}] connection {connection.id} FAILED: {e}",
                      file=sys.stderr)


if __name__ == "__main__":
    main()
