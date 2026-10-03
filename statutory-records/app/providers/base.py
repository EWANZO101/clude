"""Bank provider abstraction, same shape as /root/payments' finance module
so the same integration pattern is reused rather than reinvented. Concrete
providers implement this; real OAuth/sync logic lives in each provider.
"""
from abc import ABC, abstractmethod


class BankProviderError(Exception):
    pass


class BankProvider(ABC):
    key = "base"
    display_name = "Base Provider"

    @abstractmethod
    def is_configured(self):
        raise NotImplementedError

    @abstractmethod
    def get_auth_url(self, redirect_uri, state):
        raise NotImplementedError

    @abstractmethod
    def exchange_code(self, code, redirect_uri):
        raise NotImplementedError

    @abstractmethod
    def list_accounts(self, access_token):
        """Returns list[dict(provider_account_id, name, account_type, currency)]."""
        raise NotImplementedError

    @abstractmethod
    def get_balance(self, access_token, provider_account_id):
        """Returns dict(balance_minor, currency)."""
        raise NotImplementedError

    @abstractmethod
    def list_transactions(self, access_token, provider_account_id, since=None):
        """Returns list[dict(external_transaction_id, date, amount_minor, description, currency)]."""
        raise NotImplementedError

    @abstractmethod
    def refresh_access_token(self, refresh_token):
        raise NotImplementedError
