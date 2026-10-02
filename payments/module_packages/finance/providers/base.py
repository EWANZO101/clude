"""Bank provider abstraction. Concrete providers (Monzo, other Open Banking
providers) implement this interface. Real OAuth/token exchange and live sync
are stubbed here — wiring a specific provider's API is a deployment-time
integration step, not something to hardcode with real credentials.
"""
from abc import ABC, abstractmethod


class BankProviderError(Exception):
    pass


class BankProvider(ABC):
    key = "base"
    display_name = "Base Provider"

    @abstractmethod
    def get_auth_url(self, redirect_uri, state):
        """Returns the URL to send the user to for Open Banking consent."""
        raise NotImplementedError

    @abstractmethod
    def exchange_code(self, code, redirect_uri):
        """Exchanges an OAuth code for access/refresh tokens. Never returns raw bank passwords."""
        raise NotImplementedError

    @abstractmethod
    def list_accounts(self, access_token):
        """Returns list[dict(provider_account_id, name, account_type, currency,
        account_number, sort_code)]."""
        raise NotImplementedError

    @abstractmethod
    def get_balance(self, access_token, provider_account_id):
        """Returns dict(balance_minor, currency)."""
        raise NotImplementedError

    @abstractmethod
    def list_transactions(self, access_token, provider_account_id, since=None):
        """Returns list[dict(external_transaction_id, date, amount_minor, description, ...)]."""
        raise NotImplementedError

    @abstractmethod
    def refresh_access_token(self, refresh_token):
        raise NotImplementedError
