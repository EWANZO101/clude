"""GoCardless Bank Account Data (formerly Nordigen) — an Open Banking
aggregator, not a direct bank integration: GoCardless is itself the
FCA-authorised (AISP) party, and exposes one API covering 2000+ European
banks including every major UK high-street and business bank (Barclays,
HSBC, Lloyds, NatWest, Santander, TSB, Nationwide, Revolut, Starling, ...).
This is the realistic way for this app to reach "any UK bank" without this
app itself needing FCA authorisation, which direct integration with each
bank's own Open Banking API would require.

Docs: https://developer.gocardless.com/bank-account-data/overview

Free self-serve signup at https://bankaccountdata.gocardless.com — no sales
process. Set GOCARDLESS_SECRET_ID / GOCARDLESS_SECRET_KEY in .env.

Auth shape is different from Monzo's OAuth: a short-lived app-level access
token (from the secret id/key, not tied to any one end user) authenticates
every API call; per-connection consent is a "requisition" the end user
completes at their own bank, valid for a bank-defined period (commonly ~90
days) with no refresh -- reconnecting just creates a new requisition.
"""
import os
import time

import requests

API_BASE = "https://bankaccountdata.gocardless.com/api/v2"

_token_cache = {"access_token": None, "expires_at": 0}


class GoCardlessError(Exception):
    pass


def is_configured():
    return bool(os.environ.get("GOCARDLESS_SECRET_ID") and os.environ.get("GOCARDLESS_SECRET_KEY"))


def _access_token():
    if _token_cache["access_token"] and _token_cache["expires_at"] > time.time() + 30:
        return _token_cache["access_token"]

    secret_id = os.environ.get("GOCARDLESS_SECRET_ID")
    secret_key = os.environ.get("GOCARDLESS_SECRET_KEY")
    if not secret_id or not secret_key:
        raise GoCardlessError(
            "GoCardless isn't configured — sign up free at "
            "https://bankaccountdata.gocardless.com and set GOCARDLESS_SECRET_ID / "
            "GOCARDLESS_SECRET_KEY in .env."
        )
    resp = requests.post(f"{API_BASE}/token/new/", json={"secret_id": secret_id, "secret_key": secret_key}, timeout=15)
    if not resp.ok:
        raise GoCardlessError(f"GoCardless auth failed: {resp.status_code} {resp.text[:300]}")
    data = resp.json()
    _token_cache["access_token"] = data["access"]
    _token_cache["expires_at"] = time.time() + data.get("access_expires", 3600)
    return _token_cache["access_token"]


def _headers():
    return {"Authorization": f"Bearer {_access_token()}", "Accept": "application/json"}


def list_institutions(country="gb", search=""):
    """Every bank GoCardless supports for this country -- this IS the "all
    UK business banks" bank picker."""
    resp = requests.get(f"{API_BASE}/institutions/", headers=_headers(), params={"country": country}, timeout=15)
    if not resp.ok:
        raise GoCardlessError(f"Couldn't list banks: {resp.status_code} {resp.text[:300]}")
    institutions = resp.json()
    if search:
        s = search.lower()
        institutions = [i for i in institutions if s in i.get("name", "").lower()]
    return sorted(institutions, key=lambda i: i.get("name", ""))


def create_requisition(institution_id, redirect_uri, reference):
    resp = requests.post(f"{API_BASE}/requisitions/", headers=_headers(), json={
        "institution_id": institution_id,
        "redirect": redirect_uri,
        "reference": reference,
        "user_language": "EN",
    }, timeout=15)
    if not resp.ok:
        raise GoCardlessError(f"Couldn't start bank connection: {resp.status_code} {resp.text[:300]}")
    return resp.json()  # {id, link, ...}


def get_requisition(requisition_id):
    resp = requests.get(f"{API_BASE}/requisitions/{requisition_id}/", headers=_headers(), timeout=15)
    if not resp.ok:
        raise GoCardlessError(f"Couldn't check bank connection: {resp.status_code} {resp.text[:300]}")
    return resp.json()  # {status, accounts: [account_id, ...], ...}


def get_account_details(account_id):
    resp = requests.get(f"{API_BASE}/accounts/{account_id}/details/", headers=_headers(), timeout=15)
    if not resp.ok:
        raise GoCardlessError(f"Couldn't read account details: {resp.status_code} {resp.text[:300]}")
    return resp.json().get("account", {})


def get_account_balance_minor(account_id):
    resp = requests.get(f"{API_BASE}/accounts/{account_id}/balances/", headers=_headers(), timeout=15)
    if not resp.ok:
        raise GoCardlessError(f"Couldn't read balance: {resp.status_code} {resp.text[:300]}")
    balances = resp.json().get("balances", [])
    if not balances:
        return 0, "GBP"
    # Prefer "interimAvailable"/"expected" if present, otherwise the first one.
    chosen = next((b for b in balances if b.get("balanceType") in ("interimAvailable", "expected")), balances[0])
    amt = chosen.get("balanceAmount", {})
    return round(float(amt.get("amount", 0)) * 100), amt.get("currency", "GBP")


def list_transactions(account_id):
    resp = requests.get(f"{API_BASE}/accounts/{account_id}/transactions/", headers=_headers(), timeout=20)
    if not resp.ok:
        raise GoCardlessError(f"Couldn't read transactions: {resp.status_code} {resp.text[:300]}")
    data = resp.json().get("transactions", {})
    results = []
    for t in data.get("booked", []):
        amt = t.get("transactionAmount", {})
        description = (
            t.get("remittanceInformationUnstructured")
            or t.get("creditorName") or t.get("debtorName") or "Transaction"
        )
        ext_id = t.get("transactionId") or t.get("internalTransactionId")
        if not ext_id:
            continue
        results.append({
            "external_transaction_id": ext_id,
            "date": t.get("bookingDate") or t.get("valueDate"),
            "amount_minor": round(float(amt.get("amount", 0)) * 100),
            "description": description,
            "currency": amt.get("currency", "GBP"),
        })
    return results
