"""Real integration against the UK Companies House public API
(https://api.company-information.service.gov.uk) — lets a director type in
just a company number and have everything else filled in automatically:
company profile, registered office, SIC codes, current officers (directors
+ PSC), and the actual confirmation-statement/accounts due dates Companies
House itself has on file.

Requires a free API key from
https://developer.company-information.service.gov.uk (self-serve, no
approval wait). Fully self-service, no server access needed: each
signed-up user sets their own key from Settings -> Integrations in the UI
(User.companies_house_api_key_encrypted), which every function here takes
as `api_key`. A COMPANIES_HOUSE_API_KEY in .env is only a deployment-wide
fallback for a user who hasn't set their own. Without either, this is a
documented "not configured" result rather than a silent failure or fake
data — same pattern used for the Monzo bank provider in this app.
"""
import os

import requests

API_BASE = "https://api.company-information.service.gov.uk"


class CompaniesHouseError(Exception):
    pass


def is_configured(api_key=None):
    return bool(api_key or os.environ.get("COMPANIES_HOUSE_API_KEY"))


def _get(path, api_key=None):
    api_key = api_key or os.environ.get("COMPANIES_HOUSE_API_KEY")
    if not api_key:
        raise CompaniesHouseError(
            "No Companies House API key configured — add your free key under "
            "Settings -> Integrations (get one at "
            "https://developer.company-information.service.gov.uk)."
        )
    resp = requests.get(f"{API_BASE}{path}", auth=(api_key, ""), timeout=15)
    if resp.status_code == 404:
        return None
    if not resp.ok:
        raise CompaniesHouseError(f"Companies House request failed: {resp.status_code} {resp.text[:300]}")
    return resp.json()


def _format_address(addr):
    if not addr:
        return ""
    parts = [addr.get(k) for k in ("premises", "address_line_1", "address_line_2", "locality", "region", "postal_code", "country")]
    return ", ".join(p for p in parts if p)


def lookup_company(company_number, api_key=None):
    """Returns a dict shaped for pre-filling the Company form + creating
    StatutoryDeadline rows, or None if the number doesn't exist. Raises
    CompaniesHouseError if not configured or the API call fails."""
    data = _get(f"/company/{company_number}", api_key=api_key)
    if not data:
        return None

    confirmation = data.get("confirmation_statement") or {}
    accounts = data.get("accounts") or {}
    next_accounts = accounts.get("next_accounts") or {}

    return {
        "company_name": data.get("company_name"),
        "company_number": data.get("company_number"),
        "company_status": data.get("company_status", "active"),
        "company_type": data.get("type", "ltd"),
        "incorporation_date": data.get("date_of_creation"),
        "registered_office_address": _format_address(data.get("registered_office_address")),
        "sic_codes": ", ".join(data.get("sic_codes", [])),
        "confirmation_statement_due": confirmation.get("next_due"),
        "accounts_due": next_accounts.get("period_end_on") and accounts.get("next_due"),
    }


def list_officers(company_number, api_key=None):
    """Returns [{name, role, appointed_on, resigned_on, nationality}, ...]
    for current + former officers, newest appointment first (as Companies
    House returns them)."""
    data = _get(f"/company/{company_number}/officers", api_key=api_key)
    if not data:
        return []
    officers = []
    for item in data.get("items", []):
        role = item.get("officer_role", "director")
        officers.append({
            "name": item.get("name", ""),
            "role": "psc" if "significant-control" in role else ("both" if role == "director" else "director"),
            "appointed_on": item.get("appointed_on"),
            "resigned_on": item.get("resigned_on"),
            "nationality": item.get("nationality", ""),
        })
    return officers
