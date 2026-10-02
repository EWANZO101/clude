"""Monzo provider — real implementation against https://api.monzo.com.

Docs: https://docs.monzo.com

Requires a client registered at https://developers.monzo.com — a SEPARATE
registration from any other app on this box, since Monzo ties a client to
one redirect URI. MONZO_CLIENT_ID / MONZO_CLIENT_SECRET must be set in
.env, with a redirect URI registered there that exactly matches
"https://records.opslabsystems.cloud/companies/<company_id>/bank/oauth/callback"
-- wait, Monzo doesn't support path templates, so the registered redirect
URI is the fixed "{APP_BASE_URL}/bank/oauth/callback" and the company being
connected travels in OAuth `state` instead (see routes.py).

Per Monzo's own docs: "The Monzo Developer API is not suitable for
building public applications. You may only connect to your own account or
those of a small set of users you explicitly allow." Every signed-up user
of this app connecting their own business account fits that model the same
way the payments app's single-user deployment does.

Strong Customer Authentication: the access token has zero permissions
until the account owner approves access inside the Monzo app (push
notification after the OAuth redirect). Calls made before that approval
get a 403. After approval, full transaction history is available for the
first 5 minutes of the session; after that, only the last 90 days are
readable without re-approving.
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

    def list_accounts(self, access_token):
        resp = requests.get(f"{MONZO_API_BASE}/accounts",
                             headers={"Authorization": f"Bearer {access_token}"},
                             params={"account_type": "uk_business"}, timeout=15)
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
                "name": a.get("description") or "Monzo business account",
                "account_type": "current",
                "currency": "GBP",
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
        """Paginates through Monzo's /transactions endpoint (defaults to 30
        per call) until a short page confirms there's nothing left."""
        results = []
        page_since = since
        limit = 100

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
                    continue
                merchant = t.get("merchant") if isinstance(t.get("merchant"), dict) else None
                results.append({
                    "external_transaction_id": t["id"],
                    "date": t["created"][:10],
                    "amount_minor": t["amount"],
                    "description": (merchant or {}).get("name") or t.get("description", ""),
                    "currency": t.get("currency", "GBP"),
                })

            if len(page) < limit:
                break
            page_since = page[-1]["id"]

        return results


PROVIDERS = {"monzo": MonzoProvider()}


def get_provider(key):
    provider = PROVIDERS.get(key)
    if not provider:
        raise BankProviderError(f"Unknown bank provider: {key}")
    return provider
