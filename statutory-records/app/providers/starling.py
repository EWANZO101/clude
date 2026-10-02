"""Starling Bank provider — real implementation against
https://api.starlingbank.com. A second *direct* option alongside Monzo
(both banks run their own free, self-serve developer program for
personal/small-business read access — no aggregator needed, unlike every
other UK bank, which is what GoCardless is for).

Docs: https://developer.starlingbank.com

Requires a client registered at https://developer.starlingbank.com, with
STARLING_CLIENT_ID / STARLING_CLIENT_SECRET set in .env and a redirect URI
registered there that exactly matches
"{APP_BASE_URL}/bank/oauth/starling/callback". Request scopes: at minimum
account:read, balance:read, transaction:read.
"""
import os

import requests

from .base import BankProvider, BankProviderError

STARLING_API_BASE = "https://api.starlingbank.com"
STARLING_AUTH_BASE = "https://oauth.starlingbank.com"
SCOPES = "account:read balance:read transaction:read"


class StarlingProvider(BankProvider):
    key = "starling"
    display_name = "Starling"

    def __init__(self):
        self.client_id = os.environ.get("STARLING_CLIENT_ID")
        self.client_secret = os.environ.get("STARLING_CLIENT_SECRET")

    def is_configured(self):
        return bool(self.client_id and self.client_secret)

    def get_auth_url(self, redirect_uri, state):
        if not self.client_id:
            raise BankProviderError(
                "STARLING_CLIENT_ID is not configured — register a client at "
                "https://developer.starlingbank.com and set STARLING_CLIENT_ID / "
                "STARLING_CLIENT_SECRET in .env."
            )
        return (
            f"{STARLING_AUTH_BASE}/?client_id={self.client_id}&redirect_uri={redirect_uri}"
            f"&response_type=code&scope={SCOPES.replace(' ', '+')}&state={state}"
        )

    def exchange_code(self, code, redirect_uri):
        if not self.is_configured():
            raise BankProviderError("Starling client credentials are not configured.")
        resp = requests.post(f"{STARLING_AUTH_BASE}/access-token", data={
            "grant_type": "authorization_code",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "redirect_uri": redirect_uri,
            "code": code,
        }, timeout=15)
        if not resp.ok:
            raise BankProviderError(f"Starling token exchange failed: {resp.status_code} {resp.text[:300]}")
        data = resp.json()
        return {
            "access_token": data["access_token"],
            "refresh_token": data.get("refresh_token"),
            "expires_in": data.get("expires_in"),
        }

    def refresh_access_token(self, refresh_token):
        if not self.is_configured():
            raise BankProviderError("Starling client credentials are not configured.")
        resp = requests.post(f"{STARLING_AUTH_BASE}/access-token", data={
            "grant_type": "refresh_token",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "refresh_token": refresh_token,
        }, timeout=15)
        if not resp.ok:
            raise BankProviderError(f"Starling token refresh failed: {resp.status_code} {resp.text[:300]}")
        data = resp.json()
        return {
            "access_token": data["access_token"],
            "refresh_token": data.get("refresh_token"),
            "expires_in": data.get("expires_in"),
        }

    def list_accounts(self, access_token):
        resp = requests.get(f"{STARLING_API_BASE}/api/v2/accounts",
                             headers={"Authorization": f"Bearer {access_token}"}, timeout=15)
        if not resp.ok:
            raise BankProviderError(f"Starling account list failed: {resp.status_code} {resp.text[:300]}")
        accounts = resp.json().get("accounts", [])
        results = []
        for a in accounts:
            results.append({
                "provider_account_id": a["accountUid"],
                "name": a.get("name") or a.get("defaultCategory") or "Starling account",
                "account_type": "current",
                "currency": a.get("currency", "GBP"),
                "_category_uid": a.get("defaultCategory"),  # needed for the transactions feed endpoint
            })
        return results

    def get_balance(self, access_token, provider_account_id):
        resp = requests.get(f"{STARLING_API_BASE}/api/v2/accounts/{provider_account_id}/balance",
                             headers={"Authorization": f"Bearer {access_token}"}, timeout=15)
        if not resp.ok:
            raise BankProviderError(f"Starling balance read failed: {resp.status_code} {resp.text[:300]}")
        data = resp.json()
        cleared = data.get("clearedBalance", {})
        return {"balance_minor": cleared.get("minorUnits", 0), "currency": cleared.get("currency", "GBP")}

    def list_transactions(self, access_token, provider_account_id, since=None, category_uid=None):
        """Starling's feed endpoint is scoped to a "category" (the default
        spending space), not just the account id -- list_accounts() stashes
        it as _category_uid; callers that don't have it re-fetch the
        account list first."""
        import datetime as _dt

        if not category_uid:
            accounts = self.list_accounts(access_token)
            match = next((a for a in accounts if a["provider_account_id"] == provider_account_id), None)
            category_uid = match["_category_uid"] if match else None
        if not category_uid:
            raise BankProviderError("Couldn't resolve this Starling account's category for transactions.")

        min_ts = since or (_dt.datetime.utcnow() - _dt.timedelta(days=365)).isoformat() + "Z"
        resp = requests.get(
            f"{STARLING_API_BASE}/api/v2/feed/account/{provider_account_id}/category/{category_uid}/transactions-between",
            headers={"Authorization": f"Bearer {access_token}"},
            params={"minTransactionTimestamp": min_ts, "maxTransactionTimestamp": _dt.datetime.utcnow().isoformat() + "Z"},
            timeout=20,
        )
        if not resp.ok:
            raise BankProviderError(f"Starling transaction list failed: {resp.status_code} {resp.text[:300]}")
        results = []
        for t in resp.json().get("feedItems", []):
            if t.get("status") == "DECLINED":
                continue
            amount = t.get("amount", {})
            minor = amount.get("minorUnits", 0)
            if t.get("direction") == "OUT":
                minor = -minor
            results.append({
                "external_transaction_id": t["feedItemUid"],
                "date": (t.get("transactionTime") or "")[:10],
                "amount_minor": minor,
                "description": t.get("counterPartyName") or t.get("reference") or "Transaction",
                "currency": amount.get("currency", "GBP"),
            })
        return results
