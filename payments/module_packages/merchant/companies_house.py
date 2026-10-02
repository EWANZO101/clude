"""UK company data sync. Companies House provides both a REST API and bulk
data products (see developer.company-information.service.gov.uk) — this is
a structural sync interface, not a live integration, since it needs a real
registered API key at deployment time. Local search runs against whatever
is in merchant_companies (seed data by default; live-synced data once
COMPANIES_HOUSE_API_KEY is configured and sync_companies() is wired to a
real HTTP client).
"""
import os

from app.extensions import db
from .models import MerchantCompany


class CompaniesHouseError(Exception):
    pass


def is_configured():
    return bool(os.environ.get("COMPANIES_HOUSE_API_KEY"))


def sync_companies(search_terms=None):
    """Background-job entry point (register_job('merchant.sync_companies')).
    Without a configured API key this is a documented no-op rather than a
    silent failure, matching the pattern used for the Monzo bank provider."""
    if not is_configured():
        return {
            "status": "not_configured",
            "message": "Set COMPANIES_HOUSE_API_KEY to enable live company sync. "
                       "Using seed data only.",
        }
    # Real implementation: paginate the Companies House search/advanced-search
    # API for search_terms (or the bulk snapshot product for a full sync),
    # upsert into MerchantCompany by company_number, and update last_updated.
    raise CompaniesHouseError("Live Companies House sync requires wiring a real HTTP client — not implemented.")


def local_company_search(query, limit=10):
    query = (query or "").strip()
    if not query:
        return []
    return MerchantCompany.query.filter(
        MerchantCompany.company_name.ilike(f"%{query}%")
    ).limit(limit).all()
