"""Registry of direct (OAuth, no aggregator) bank providers -- banks that
run their own free developer program for personal/small-business read
access. Every other UK bank goes through app/providers/gocardless.py
instead (an Open Banking aggregator), since most banks don't offer this."""
from .base import BankProviderError
from .monzo import MonzoProvider
from .starling import StarlingProvider

DIRECT_PROVIDERS = {
    "monzo": MonzoProvider(),
    "starling": StarlingProvider(),
}


def get_direct_provider(key):
    provider = DIRECT_PROVIDERS.get(key)
    if not provider:
        raise BankProviderError(f"Unknown bank provider: {key}")
    return provider
