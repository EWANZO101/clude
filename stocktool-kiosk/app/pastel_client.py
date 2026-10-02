"""
Thin HTTP client for the Sage Active Public API V2 (GraphQL), as used
by CloudSolve's Sage Pastel integration.

Kept deliberately separate from app/pastel_sync.py (which decides WHAT
to sync and WHEN) so this file only knows HOW to talk to Sage: OAuth2
token lifecycle (obtain / refresh) and firing a GraphQL request with
the right headers. Mirrors the separation already used elsewhere in
this codebase (audit_scheduler.py vs audit_engine.py).

Reference: https://developer.sage.com/sageactive/
  - Auth: https://developer.sage.com/sageactive/guides/authentication/authentication-webserver
  - GraphQL headers: Authorization (Bearer), X-OrganizationId, x-api-key
"""
from __future__ import annotations

import time
import logging
from dataclasses import dataclass

import requests

log = logging.getLogger("pastel")

TOKEN_REFRESH_MARGIN_SECONDS = 120  # refresh a bit before actual expiry


class PastelAuthError(RuntimeError):
    """Raised when we have no usable access token and can't silently
    get one (e.g. no refresh token yet -- the admin needs to complete
    the OAuth consent flow via app/routes_pastel.py)."""


class PastelAPIError(RuntimeError):
    """Raised when Sage Active returns a GraphQL `errors` array. Carries
    the raw errors list so callers can decide whether it's worth a
    retry (e.g. transient server_error) or a hard failure to log."""

    def __init__(self, message: str, errors: list | None = None):
        super().__init__(message)
        self.errors = errors or []


@dataclass
class PastelCredentials:
    """Snapshot of the bits of settings.json this client needs. Built
    fresh from load_settings() on every call site rather than cached,
    since an admin can update these from the Admin Panel at any time
    and the background sync loop should pick that up on its next pass."""

    api_base: str
    auth_url: str
    token_url: str
    client_id: str
    client_secret: str
    subscription_key: str
    redirect_uri: str
    organization_id: str | None
    access_token: str | None
    refresh_token: str | None
    token_expires_at: float | None

    @classmethod
    def from_settings(cls, settings: dict) -> "PastelCredentials":
        return cls(
            api_base=settings.get("pastel_api_base"),
            auth_url=settings.get("pastel_auth_url"),
            token_url=settings.get("pastel_token_url"),
            client_id=settings.get("pastel_client_id"),
            client_secret=settings.get("pastel_client_secret"),
            subscription_key=settings.get("pastel_subscription_key"),
            redirect_uri=settings.get("pastel_redirect_uri"),
            organization_id=settings.get("pastel_organization_id"),
            access_token=settings.get("pastel_access_token"),
            refresh_token=settings.get("pastel_refresh_token"),
            token_expires_at=settings.get("pastel_token_expires_at"),
        )

    def is_configured(self) -> bool:
        return bool(self.api_base and self.token_url and self.client_id and self.client_secret and self.subscription_key)


def build_authorize_url(creds: PastelCredentials, state: str, scopes: str = "RDSA WDSA offline_access") -> str:
    """Step 1 of the web-server OAuth2 flow -- the URL to send the admin's
    browser to so they can log in to Sage Active and grant consent."""
    from urllib.parse import urlencode

    params = {
        "client_id": creds.client_id,
        "response_type": "code",
        "scope": scopes,
        "redirect_uri": creds.redirect_uri,
        "state": state,
    }
    return f"{creds.auth_url}?{urlencode(params)}"


def exchange_code_for_token(creds: PastelCredentials, code: str) -> dict:
    """Step 2 -- swap the authorization code from the callback for an
    access_token/refresh_token pair. Returns the raw token response so
    the caller (routes_pastel.py) can persist it into settings.json."""
    resp = requests.post(
        creds.token_url,
        data={
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": creds.redirect_uri,
            "client_id": creds.client_id,
            "client_secret": creds.client_secret,
        },
        timeout=30,
    )
    if not resp.ok:
        raise PastelAuthError(f"Token exchange failed ({resp.status_code}): {resp.text[:500]}")
    return resp.json()


def refresh_access_token(creds: PastelCredentials) -> dict:
    """Step 3 -- use a stored refresh_token to get a new access_token
    without the admin having to log in again. Requires the original
    authorization to have included the offline_access scope."""
    if not creds.refresh_token:
        raise PastelAuthError(
            "No Pastel refresh token on file -- an admin needs to complete the "
            "Sage Active OAuth consent flow (see the Admin Panel's Accounting "
            "Integration page) before automatic sync can run."
        )
    resp = requests.post(
        creds.token_url,
        data={
            "grant_type": "refresh_token",
            "refresh_token": creds.refresh_token,
            "client_id": creds.client_id,
            "client_secret": creds.client_secret,
        },
        timeout=30,
    )
    if not resp.ok:
        raise PastelAuthError(f"Token refresh failed ({resp.status_code}): {resp.text[:500]}")
    return resp.json()


class PastelClient:
    """One instance per sync pass. Handles making sure the access token
    is fresh, then exposes a single `graphql()` call for queries and
    mutations alike (GraphQL has no separate verbs the way REST does)."""

    def __init__(self, creds: PastelCredentials, on_token_refreshed=None):
        self.creds = creds
        # Called with the new token dict whenever a refresh happens, so
        # the caller can persist it to settings.json immediately -- we
        # never want a freshly-minted token to be lost because the
        # process crashed before someone else wrote it back.
        self._on_token_refreshed = on_token_refreshed

    def _ensure_fresh_token(self):
        creds = self.creds
        if not creds.access_token:
            raise PastelAuthError("No Pastel access token on file yet -- complete the OAuth consent flow first.")
        expires_at = creds.token_expires_at or 0
        if time.time() < (expires_at - TOKEN_REFRESH_MARGIN_SECONDS):
            return  # still good
        token_data = refresh_access_token(creds)
        creds.access_token = token_data["access_token"]
        # Sage rotates the refresh token on some grants -- keep the old
        # one if a new one wasn't issued.
        creds.refresh_token = token_data.get("refresh_token", creds.refresh_token)
        creds.token_expires_at = time.time() + token_data.get("expires_in", 28800)
        if self._on_token_refreshed:
            self._on_token_refreshed(token_data, creds)

    def graphql(self, query: str, variables: dict | None = None, organization_id: str | None = None) -> dict:
        """Fires one GraphQL request and returns the `data` object.
        Raises PastelAPIError if Sage returns an `errors` array."""
        self._ensure_fresh_token()
        creds = self.creds
        org_id = organization_id or creds.organization_id
        headers = {
            "Authorization": f"Bearer {creds.access_token}",
            "x-api-key": creds.subscription_key,
            "Content-Type": "application/json",
        }
        if org_id:
            headers["X-OrganizationId"] = org_id

        url = creds.api_base.rstrip("/") + "/graphql"
        resp = requests.post(
            url,
            json={"query": query, "variables": variables or {}},
            headers=headers,
            timeout=30,
        )
        if not resp.ok:
            raise PastelAPIError(f"Sage Active HTTP {resp.status_code}: {resp.text[:800]}")
        payload = resp.json()
        if payload.get("errors"):
            first = payload["errors"][0].get("message", "Unknown Sage Active error")
            raise PastelAPIError(first, errors=payload["errors"])
        return payload.get("data", {})

    def list_organizations(self) -> list[dict]:
        data = self.graphql(
            """
            query {
              organizations {
                edges { node { id name legislationCode } }
              }
            }
            """
        )
        return [edge["node"] for edge in data.get("organizations", {}).get("edges", [])]
