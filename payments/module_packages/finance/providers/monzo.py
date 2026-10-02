"""Monzo provider — real implementation against https://api.monzo.com.

Docs: https://docs.monzo.com

Requires a client registered at https://developers.monzo.com, with
MONZO_CLIENT_ID / MONZO_CLIENT_SECRET set in the environment and a
redirect URI registered there that exactly matches
"{APP_BASE_URL}/finance/oauth/monzo/callback".

Per Monzo's own docs: "The Monzo Developer API is not suitable for
building public applications. You may only connect to your own account
or those of a small set of users you explicitly allow." This matches a
single-user personal deployment; it is not a general "connect any bank
account" integration for arbitrary third parties.

Strong Customer Authentication: the access token has zero permissions
until the account owner approves access inside the Monzo app (push
notification after the OAuth redirect). Calls made before that approval
will get a 403. After approval, full transaction history is available for
the first 5 minutes of the session; after that, only the last 90 days are
readable without the user re-approving.
"""
import os

import requests

from .base import BankProvider, BankProviderError

MONZO_API_BASE = "https://api.monzo.com"
MONZO_AUTH_BASE = "https://auth.monzo.com"


class MonzoProvider(BankProvider):
    key = "monzo"
    display_name = "Monzo"

    def __init__(self):
        self.client_id = os.environ.get("MONZO_CLIENT_ID")
        self.client_secret = os.environ.get("MONZO_CLIENT_SECRET")

    def is_configured(self):
        return bool(self.client_id and self.client_secret)

    def get_auth_url(self, redirect_uri, state):
        if not self.client_id:
            raise BankProviderError(
                "MONZO_CLIENT_ID is not configured — register a client at "
                "https://developers.monzo.com and set MONZO_CLIENT_ID / "
                "MONZO_CLIENT_SECRET in .env."
            )
        return (
            f"{MONZO_AUTH_BASE}/?client_id={self.client_id}&redirect_uri={redirect_uri}"
            f"&response_type=code&state={state}"
        )

    def exchange_code(self, code, redirect_uri):
        if not self.is_configured():
            raise BankProviderError("Monzo client credentials are not configured.")
        resp = requests.post(f"{MONZO_API_BASE}/oauth2/token", data={
            "grant_type": "authorization_code",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "redirect_uri": redirect_uri,
            "code": code,
        }, timeout=15)
        if not resp.ok:
            raise BankProviderError(f"Monzo token exchange failed: {resp.status_code} {resp.text[:300]}")
        data = resp.json()
        return {
            "access_token": data["access_token"],
            "refresh_token": data.get("refresh_token"),
            "expires_in": data.get("expires_in"),
            "user_id": data.get("user_id"),
        }

    def refresh_access_token(self, refresh_token):
        if not self.is_configured():
            raise BankProviderError("Monzo client credentials are not configured.")
        resp = requests.post(f"{MONZO_API_BASE}/oauth2/token", data={
            "grant_type": "refresh_token",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "refresh_token": refresh_token,
        }, timeout=15)
        if not resp.ok:
            raise BankProviderError(f"Monzo token refresh failed: {resp.status_code} {resp.text[:300]}")
        data = resp.json()
        return {
            "access_token": data["access_token"],
            "refresh_token": data.get("refresh_token"),
            "expires_in": data.get("expires_in"),
        }

    def whoami(self, access_token):
        resp = requests.get(f"{MONZO_API_BASE}/ping/whoami",
                             headers={"Authorization": f"Bearer {access_token}"}, timeout=15)
        if not resp.ok:
            raise BankProviderError(f"Monzo auth check failed: {resp.status_code} {resp.text[:300]}")
        return resp.json()

    def list_accounts(self, access_token):
        resp = requests.get(f"{MONZO_API_BASE}/accounts",
                             headers={"Authorization": f"Bearer {access_token}"},
                             params={"account_type": "uk_retail"}, timeout=15)
        if resp.status_code == 403:
            raise BankProviderError(
                "Monzo hasn't granted access yet — check your Monzo app for a push "
                "notification asking you to approve this connection (Strong Customer "
                "Authentication), then try again."
            )
        if not resp.ok:
            raise BankProviderError(f"Monzo account list failed: {resp.status_code} {resp.text[:300]}")
        accounts = resp.json().get("accounts", [])
        results = []
        for a in accounts:
            if a.get("closed"):
                continue
            results.append({
                "provider_account_id": a["id"],
                "name": a.get("description") or "Monzo account",
                "account_type": "current",
                "currency": "GBP",
                # Present on uk_retail accounts once the token has full permissions;
                # absent otherwise (e.g. before the user approves in-app).
                "account_number": a.get("account_number"),
                "sort_code": a.get("sort_code"),
            })
        return results

    def get_balance(self, access_token, provider_account_id):
        resp = requests.get(f"{MONZO_API_BASE}/balance",
                             headers={"Authorization": f"Bearer {access_token}"},
                             params={"account_id": provider_account_id}, timeout=15)
        if not resp.ok:
            raise BankProviderError(f"Monzo balance read failed: {resp.status_code} {resp.text[:300]}")
        data = resp.json()
        return {"balance_minor": data["balance"], "currency": data.get("currency", "GBP")}

    def list_transactions(self, access_token, provider_account_id, since=None):
        """Paginates through Monzo's /transactions endpoint. Monzo defaults
        to returning only 30 transactions per request — without this loop,
        callers silently only ever got the most recent 30, no matter how
        much history was actually available. Uses the `since` cursor form
        (an object id, not a date) once a page returns a full batch, per
        Monzo's own pagination pattern, and stops once a short page confirms
        there's nothing left."""
        results = []
        page_since = since
        limit = 100  # Monzo's documented max per page

        while True:
            params = {"account_id": provider_account_id, "expand[]": "merchant", "limit": limit}
            if page_since:
                params["since"] = page_since
            resp = requests.get(f"{MONZO_API_BASE}/transactions",
                                 headers={"Authorization": f"Bearer {access_token}"}, params=params, timeout=20)
            if not resp.ok:
                raise BankProviderError(f"Monzo transaction list failed: {resp.status_code} {resp.text[:300]}")

            page = resp.json().get("transactions", [])
            for t in page:
                if t.get("decline_reason"):
                    continue  # declined transactions never actually moved money
                merchant = t.get("merchant") if isinstance(t.get("merchant"), dict) else None
                results.append({
                    "external_transaction_id": t["id"],
                    "date": t["created"][:10],
                    "amount_minor": t["amount"],
                    "description": (merchant or {}).get("name") or t.get("description", ""),
                    "raw_description": t.get("description", ""),
                    "currency": t.get("currency", "GBP"),
                })

            if len(page) < limit:
                break  # short page — that was the last one
            page_since = page[-1]["id"]  # Monzo's cursor form: next page starts after this transaction's id

        return results

    def logout(self, access_token):
        requests.post(f"{MONZO_API_BASE}/oauth2/logout",
                       headers={"Authorization": f"Bearer {access_token}"}, timeout=10)


PROVIDERS = {
    "monzo": MonzoProvider(),
}


def get_provider(key):
    provider = PROVIDERS.get(key)
    if not provider:
        raise BankProviderError(f"Unknown bank provider: {key}")
    return provider
