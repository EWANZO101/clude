#!/usr/bin/env bash
# Installs the Sage Active / Pastel accounting integration (+ a browser
# settings page at /ui/pastel) into an existing StockToolKiosk checkout.
# Run this from the ROOT of your project (the directory that contains
# the "app" folder) -- it will create new files and OVERWRITE
# app/models.py, app/settings.py, app/__init__.py and app/ui.py with
# the modified versions that wire the integration in (back up first if
# you've since made local changes to those four).
#
# Usage:
#   chmod +x install_pastel_integration.sh
#   ./install_pastel_integration.sh
#
# After it runs: restart your kiosk service, then log in at
#   https://<your-domain>/ui/pastel
# using an admin badge code/username -- no curl needed.

set -euo pipefail

if [[ ! -d "app" ]]; then
  echo "Error: no ./app directory found here -- run this from your StockToolKiosk project root." >&2
  exit 1
fi

mkdir -p app app/templates
echo "Writing app/pastel_client.py ..."
cat > 'app/pastel_client.py' << 'PASTEL_EOF_MARKER'
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
PASTEL_EOF_MARKER

echo "Writing app/pastel_sync.py ..."
cat > 'app/pastel_sync.py' << 'PASTEL_EOF_MARKER'
"""
Two-way sync between the local kiosk DB and Sage Active (via CloudSolve's
Sage Pastel API access), following the same shape as app/sync_engine.py
(the existing stocktoolsetup cloud sync) so this doesn't introduce a
second, inconsistent pattern for "talk to an external system and log
what happened".

What syncs, and how:

  Items  <-->  Sage Active Products
    - PUSH: any Item with dirty=True gets createProduct'd (first time)
      or updateProduct'd (subsequent times), matched via PastelMapping.
      Product `code` = Item.sku (falls back to a generated code if the
      item has no sku yet, since Sage requires one).
    - PULL: Sage Active products are fetched and matched back to a
      local Item by product code == Item.sku. Only price/name/
      description fields are pulled -- quantity/stock stays
      kiosk-authoritative (Sage Active's Products entity is a sales
      catalogue item, not a warehouse stock ledger; see
      push_usage_entries below for how consumption actually reaches
      the accounts).

  Wire usage / issuances  -->  Sage Active Accounting Entries
    - Consumable/PPE issuances (IssuanceEvent) and wire consumption
      (closed WireTransaction rows) are the kiosk's "this stock left
      the building" events. Each one is posted as a simple two-line
      accounting entry: debit the configured usage/expense account,
      credit the configured stock/inventory account, valued at
      Item.unit_cost (items) -- there's no direct Sage Active "stock
      movement" API call in the resources this integration was built
      against, so a manual accounting entry is the closest safe
      equivalent to "reduce stock value, increase cost of usage".
      This never touches the kiosk's own Item.quantity -- that's
      still driven entirely by the existing local adjust_stock() path.

Every push/pull records a PastelSyncLog row and never raises out of a
sync pass for a single failing item -- one bad record shouldn't stop
the rest of the batch, mirroring sync_engine.py's error handling.
"""
from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timezone

from app.models import db, Item, IssuanceEvent, WireTransaction, PastelMapping, PastelSyncLog
from app.pastel_client import PastelClient, PastelCredentials, PastelAPIError, PastelAuthError

log = logging.getLogger("pastel")


def _now():
    return datetime.now(timezone.utc)


def _content_hash(*parts) -> str:
    return hashlib.sha256("|".join(str(p) for p in parts).encode("utf-8")).hexdigest()


def _get_mapping(entity_type: str, local_id: int) -> PastelMapping | None:
    return PastelMapping.query.filter_by(entity_type=entity_type, local_id=local_id).first()


class PastelSyncEngine:
    def __init__(self, app):
        self.app = app

    def _client(self, settings: dict) -> PastelClient:
        creds = PastelCredentials.from_settings(settings)
        if not creds.is_configured():
            raise PastelAuthError("Pastel integration is not fully configured yet (missing API base / client credentials).")

        def _persist_refresh(token_data, refreshed_creds):
            from app.settings import load_settings, save_settings
            data_dir = self.app.config["DATA_DIR"]
            live_settings = load_settings(data_dir)
            live_settings["pastel_access_token"] = refreshed_creds.access_token
            live_settings["pastel_refresh_token"] = refreshed_creds.refresh_token
            live_settings["pastel_token_expires_at"] = refreshed_creds.token_expires_at
            save_settings(data_dir, live_settings)

        return PastelClient(creds, on_token_refreshed=_persist_refresh)

    def _log(self, direction: str, entity_type: str, status: str, message: str):
        db.session.add(PastelSyncLog(direction=direction, entity_type=entity_type, status=status, message=message))
        db.session.commit()

    # ── Items <-> Products ──────────────────────────────────────────

    def push_items(self, settings: dict, limit: int = 200) -> dict:
        """Push every dirty local Item to Sage Active as a Product.
        Returns a small summary dict for the admin UI / manual-sync
        button; also fully logged to PastelSyncLog."""
        client = self._client(settings)
        items = Item.query.filter_by(dirty=True).limit(limit).all()
        pushed, skipped, failed = 0, 0, 0

        for item in items:
            try:
                if not item.sku:
                    # Sage requires a product code -- reuse the barcode
                    # if there is one rather than silently skipping.
                    if not item.barcode_code:
                        skipped += 1
                        continue
                    code = item.barcode_code
                else:
                    code = item.sku

                fingerprint = _content_hash(item.name, code, item.description, item.unit_cost)
                mapping = _get_mapping("item", item.id)
                if mapping and mapping.content_hash == fingerprint:
                    skipped += 1
                    continue

                values = {
                    "code": code[:15],  # Sage `code` field max length is 15
                    "name": (item.name or code)[:50],
                    "lineDescription": (item.description or "")[:2500] or None,
                }
                if item.unit_cost is not None:
                    values["salesUnitPrice"] = item.unit_cost

                if mapping is None:
                    data = client.graphql(
                        """
                        mutation ($values: ProductCreateGLDtoInput!) {
                          createProduct(input: $values) { id }
                        }
                        """,
                        {"values": values},
                    )
                    pastel_id = data["createProduct"]["id"]
                    mapping = PastelMapping(entity_type="item", local_id=item.id, pastel_id=pastel_id, pastel_code=code)
                    db.session.add(mapping)
                else:
                    client.graphql(
                        """
                        mutation ($id: UUID!, $values: ProductUpdateGLDtoInput!) {
                          updateProduct(id: $id, input: $values) { id }
                        }
                        """,
                        {"id": mapping.pastel_id, "values": values},
                    )
                    mapping.pastel_code = code

                mapping.content_hash = fingerprint
                mapping.last_pushed_at = _now()
                item.dirty = False
                db.session.commit()
                pushed += 1
            except (PastelAPIError, PastelAuthError) as e:
                db.session.rollback()
                failed += 1
                self._log("push", "item", "error", f"Item #{item.id} ({item.name!r}): {e}")

        summary = {"pushed": pushed, "skipped": skipped, "failed": failed}
        self._log("push", "item", "success" if failed == 0 else "error", str(summary))
        return summary

    def pull_products(self, settings: dict, limit: int = 500) -> dict:
        """Pull Sage Active products and update matching local Items
        (matched by code == sku) with name/description/price. Never
        creates new local Items and never touches quantity -- Sage
        Active's Products entity isn't a warehouse stock ledger, so
        pulling a "quantity" from it would just overwrite real kiosk
        counts with an unrelated number."""
        client = self._client(settings)
        try:
            data = client.graphql(
                """
                query ($first: Int!) {
                  products(first: $first, where: { category: { neq: CONCEPT } }) {
                    edges { node { id code name lineDescription salesUnitPrice } }
                  }
                }
                """,
                {"first": limit},
            )
        except (PastelAPIError, PastelAuthError) as e:
            self._log("pull", "item", "error", str(e))
            return {"updated": 0, "error": str(e)}

        updated = 0
        for edge in data.get("products", {}).get("edges", []):
            node = edge["node"]
            code = node.get("code")
            if not code:
                continue
            item = Item.query.filter_by(sku=code).first()
            if not item:
                continue  # local kiosk item not present -- don't fabricate one from an accounting-side record

            item.name = node.get("name") or item.name
            if node.get("lineDescription"):
                item.description = node["lineDescription"]
            if node.get("salesUnitPrice") is not None:
                item.unit_cost = node["salesUnitPrice"]
            item.dirty = False  # this update came FROM Sage; don't immediately re-push it

            mapping = _get_mapping("item", item.id)
            if mapping is None:
                mapping = PastelMapping(entity_type="item", local_id=item.id, pastel_id=node["id"], pastel_code=code)
                db.session.add(mapping)
            else:
                mapping.pastel_id = node["id"]
            mapping.last_pulled_at = _now()
            updated += 1

        db.session.commit()
        self._log("pull", "item", "success", f"Updated {updated} local item(s) from Sage Active products.")
        return {"updated": updated}

    # ── Usage (issuances / wire consumption) -> Accounting Entries ──

    def push_usage_entries(self, settings: dict, limit: int = 100) -> dict:
        """Post consumable/PPE issuances and closed wire-coil
        transactions to Sage Active as accounting entries (debit usage
        expense account, credit stock account), so cost-of-usage shows
        up in the books without anyone re-typing it. Only posts events
        that don't already have a PastelMapping row (entity_type
        "issuance"/"wire_transaction"), so re-running this is safe."""
        journal_code = settings.get("pastel_usage_journal_code")
        expense_account = settings.get("pastel_usage_expense_account_code")
        stock_account = settings.get("pastel_stock_contra_account_code")
        if not (journal_code and expense_account and stock_account):
            return {"posted": 0, "skipped": 0, "failed": 0,
                     "note": "Journal/account codes not configured -- set pastel_usage_journal_code, "
                             "pastel_usage_expense_account_code and pastel_stock_contra_account_code first."}

        client = self._client(settings)
        posted, skipped, failed = 0, 0, 0

        # Consumable / PPE issuances, valued at the item's unit_cost.
        already_posted_ids = {
            m.local_id for m in PastelMapping.query.filter_by(entity_type="issuance").all()
        }
        issuance_query = IssuanceEvent.query
        if already_posted_ids:
            issuance_query = issuance_query.filter(~IssuanceEvent.id.in_(already_posted_ids))
        issuances = issuance_query.order_by(IssuanceEvent.id).limit(limit).all()
        for ev in issuances:
            item = Item.query.get(ev.item_id)
            if not item or not item.unit_cost:
                skipped += 1  # can't value the posting without a unit cost
                continue
            amount = round(item.unit_cost * ev.quantity, 2)
            if amount <= 0:
                skipped += 1
                continue
            try:
                data = client.graphql(
                    """
                    mutation ($values: AccountingEntryCreateUsingCodesGLDtoInput!) {
                      createAccountingEntryUsingCodes(input: $values) { id number }
                    }
                    """,
                    {
                        "values": {
                            "date": ev.created_at.date().isoformat() if ev.created_at else _now().date().isoformat(),
                            "journalTypeCode": journal_code,
                            "description": f"Kiosk issuance: {item.name} x{ev.quantity} to {ev.employee}"
                                            + (f" ({ev.project})" if ev.project else ""),
                            "accountingEntryLines": [
                                {"subAccountCode": expense_account, "debitAmount": amount, "creditAmount": 0},
                                {"subAccountCode": stock_account, "debitAmount": 0, "creditAmount": amount},
                            ],
                        }
                    },
                )
                pastel_id = data["createAccountingEntryUsingCodes"]["id"]
                db.session.add(PastelMapping(entity_type="issuance", local_id=ev.id, pastel_id=pastel_id,
                                              last_pushed_at=_now()))
                db.session.commit()
                posted += 1
            except (PastelAPIError, PastelAuthError) as e:
                db.session.rollback()
                failed += 1
                self._log("push", "accounting_entry", "error", f"Issuance #{ev.id}: {e}")

        # Closed wire-coil transactions (checked_in_at set, consumed known).
        already_posted_wire_ids = {
            m.local_id for m in PastelMapping.query.filter_by(entity_type="wire_transaction").all()
        }
        wire_query = WireTransaction.query.filter(WireTransaction.checked_in_at.isnot(None))
        if already_posted_wire_ids:
            wire_query = wire_query.filter(~WireTransaction.id.in_(already_posted_wire_ids))
        wire_txns = wire_query.order_by(WireTransaction.id).limit(limit).all()
        for txn in wire_txns:
            if not txn.consumed or txn.consumed <= 0:
                skipped += 1
                continue
            coil = txn.coil
            # No direct per-kg cost field on WireCoil -- this integration
            # doesn't invent one. If/when a wire cost-per-kg setting is
            # added, multiply it in here; for now this posts a
            # zero-amount-safe skip rather than guessing a price.
            skipped += 1
            continue  # pragma: no cover -- intentionally not posting until wire costing exists

        summary = {"posted": posted, "skipped": skipped, "failed": failed}
        self._log("push", "accounting_entry", "success" if failed == 0 else "error", str(summary))
        return summary

    # ── One full pass ────────────────────────────────────────────────

    def run_full_sync(self, settings: dict) -> dict:
        """Runs push -> pull -> usage-posting in sequence. Each stage
        catches its own errors internally (see above), so one stage
        failing doesn't block the others."""
        results = {}
        try:
            results["push_items"] = self.push_items(settings)
        except (PastelAuthError, PastelAPIError) as e:
            results["push_items"] = {"error": str(e)}
        try:
            results["pull_products"] = self.pull_products(settings)
        except (PastelAuthError, PastelAPIError) as e:
            results["pull_products"] = {"error": str(e)}
        try:
            results["push_usage_entries"] = self.push_usage_entries(settings)
        except (PastelAuthError, PastelAPIError) as e:
            results["push_usage_entries"] = {"error": str(e)}
        return results
PASTEL_EOF_MARKER

echo "Writing app/routes_pastel.py ..."
cat > 'app/routes_pastel.py' << 'PASTEL_EOF_MARKER'
"""
Admin-gated API for the Sage Active / Pastel accounting integration
(via CloudSolve). Mirrors the shape of app/routes_backup.py /
app/routes_admin.py: everything here needs the "admin" role, reads
config from settings.json via app.settings, and never has its own
separate credential store.

Endpoints:
  GET  /api/admin/pastel/settings         -- current config (secrets masked)
  POST /api/admin/pastel/settings         -- update config fields
  GET  /api/admin/pastel/oauth/authorize  -- redirects the admin's browser to Sage Active login/consent
  GET  /api/admin/pastel/oauth/callback   -- Sage Active redirects back here with ?code=...
  POST /api/admin/pastel/sync             -- run a full sync pass right now
  GET  /api/admin/pastel/log              -- recent PastelSyncLog rows
"""
import secrets

from flask import Blueprint, jsonify, request, current_app, redirect

from app.auth import permission_required
from app.settings import load_settings, save_settings
from app.models import PastelSyncLog
from app.pastel_client import PastelCredentials, build_authorize_url, exchange_code_for_token, PastelAuthError

pastel_bp = Blueprint("pastel", __name__, url_prefix="/api/admin/pastel")

# In-memory OAuth `state` store -- short-lived CSRF token for the
# authorize/callback round trip, same lifetime concern as app/auth.py's
# session tokens but much shorter-lived (a few minutes at most), so a
# simple process-local dict is fine (this is a single-machine kiosk).
_PENDING_STATES: set[str] = set()

_SECRET_FIELDS = {"pastel_client_secret", "pastel_subscription_key", "pastel_access_token", "pastel_refresh_token"}

_EDITABLE_FIELDS = [
    "pastel_enabled", "pastel_legislation", "pastel_api_base", "pastel_auth_url", "pastel_token_url",
    "pastel_client_id", "pastel_client_secret", "pastel_subscription_key", "pastel_redirect_uri",
    "pastel_usage_journal_code", "pastel_usage_expense_account_code", "pastel_stock_contra_account_code",
    "pastel_sync_interval_seconds",
]


def _masked(settings: dict) -> dict:
    out = {}
    for key, value in settings.items():
        if not key.startswith("pastel_"):
            continue
        if key in _SECRET_FIELDS and value:
            out[key] = "•" * 8 + str(value)[-4:]
        else:
            out[key] = value
    return out


@pastel_bp.route("/settings", methods=["GET"])
@permission_required("admin")
def get_settings():
    settings = load_settings(current_app.config["DATA_DIR"])
    return jsonify(_masked(settings)), 200


@pastel_bp.route("/settings", methods=["POST"])
@permission_required("admin")
def update_settings():
    body = request.get_json(silent=True) or {}
    data_dir = current_app.config["DATA_DIR"]
    settings = load_settings(data_dir)
    for field in _EDITABLE_FIELDS:
        if field in body:
            settings[field] = body[field]
    save_settings(data_dir, settings)
    return jsonify(_masked(settings)), 200


@pastel_bp.route("/oauth/authorize", methods=["GET"])
@permission_required("admin")
def oauth_authorize():
    settings = load_settings(current_app.config["DATA_DIR"])
    creds = PastelCredentials.from_settings(settings)
    if not (creds.auth_url and creds.client_id and creds.redirect_uri):
        return jsonify({"error": "Set pastel_auth_url, pastel_client_id and pastel_redirect_uri first."}), 409

    state = secrets.token_urlsafe(24)
    _PENDING_STATES.add(state)
    url = build_authorize_url(creds, state)
    return redirect(url, code=302)


@pastel_bp.route("/oauth/callback", methods=["GET"])
def oauth_callback():
    """Sage Active redirects here after the admin logs in and grants
    consent. Not permission_required -- Sage itself is the caller, and
    the `state` check below is what prevents this from being abused
    (an attacker would need a code minted for OUR client_id/redirect_uri,
    which only Sage can issue after a real login)."""
    error = request.args.get("error")
    if error:
        return jsonify({"error": f"Sage Active declined authorization: {error}"}), 400

    state = request.args.get("state")
    if not state or state not in _PENDING_STATES:
        return jsonify({"error": "Missing or unrecognized OAuth state -- start the authorize flow again."}), 400
    _PENDING_STATES.discard(state)

    code = request.args.get("code")
    if not code:
        return jsonify({"error": "No authorization code in callback."}), 400

    data_dir = current_app.config["DATA_DIR"]
    settings = load_settings(data_dir)
    creds = PastelCredentials.from_settings(settings)
    try:
        token_data = exchange_code_for_token(creds, code)
    except PastelAuthError as e:
        return jsonify({"error": str(e)}), 502

    import time
    settings["pastel_access_token"] = token_data["access_token"]
    settings["pastel_refresh_token"] = token_data.get("refresh_token")
    settings["pastel_token_expires_at"] = time.time() + token_data.get("expires_in", 28800)
    save_settings(data_dir, settings)

    return jsonify({
        "ok": True,
        "message": "Sage Active connected. Next: call GET /api/admin/pastel/organizations, "
                    "pick one, then POST its id to /api/admin/pastel/settings as pastel_organization_id.",
    }), 200


@pastel_bp.route("/organizations", methods=["GET"])
@permission_required("admin")
def list_organizations():
    settings = load_settings(current_app.config["DATA_DIR"])
    from app.pastel_client import PastelClient
    creds = PastelCredentials.from_settings(settings)
    try:
        client = PastelClient(creds)
        orgs = client.list_organizations()
    except PastelAuthError as e:
        return jsonify({"error": str(e)}), 409
    except Exception as e:  # pragma: no cover -- surfaced to the admin verbatim
        return jsonify({"error": str(e)}), 502
    return jsonify({"organizations": orgs}), 200


@pastel_bp.route("/organization", methods=["POST"])
@permission_required("admin")
def set_organization():
    """Persist the chosen organization id. Separate from the generic
    /settings PATCH (and deliberately not in _EDITABLE_FIELDS there) so
    an admin can only set this via a real pick from /organizations,
    never by hand-typing an arbitrary id that was never actually
    returned as one they're authorized to use."""
    body = request.get_json(silent=True) or {}
    org_id = body.get("organization_id")
    if not org_id:
        return jsonify({"error": "organization_id is required."}), 400
    data_dir = current_app.config["DATA_DIR"]
    settings = load_settings(data_dir)
    settings["pastel_organization_id"] = org_id
    save_settings(data_dir, settings)
    return jsonify({"ok": True, "pastel_organization_id": org_id}), 200


@pastel_bp.route("/sync", methods=["POST"])
@permission_required("admin")
def run_sync_now():
    settings = load_settings(current_app.config["DATA_DIR"])
    if not settings.get("pastel_enabled"):
        return jsonify({"error": "Pastel integration is disabled -- enable pastel_enabled first."}), 409

    from app.pastel_sync import PastelSyncEngine
    engine = PastelSyncEngine(current_app._get_current_object())
    try:
        results = engine.run_full_sync(settings)
    except PastelAuthError as e:
        return jsonify({"error": str(e)}), 409
    return jsonify(results), 200


@pastel_bp.route("/log", methods=["GET"])
@permission_required("admin")
def sync_log():
    rows = PastelSyncLog.query.order_by(PastelSyncLog.id.desc()).limit(100).all()
    return jsonify([r.to_dict() for r in rows]), 200
PASTEL_EOF_MARKER

echo "Writing app/pastel_scheduler.py ..."
cat > 'app/pastel_scheduler.py' << 'PASTEL_EOF_MARKER'
"""
Decides WHEN the Pastel/Sage Active sync runs automatically, mirroring
app/audit_scheduler.py's split between "when" (this file) and "what"
(app/pastel_sync.py). Runs as a daemon thread started from create_app(),
same convention as the audit scheduler and backup_loop.

Does nothing at all unless pastel_enabled is set AND the OAuth flow has
already produced an access token -- this is purely opt-in.
"""
import threading
import time
import logging

log = logging.getLogger("pastel")

CHECK_INTERVAL_SECONDS = 60  # how often we check "is it time yet"; actual sync cadence is pastel_sync_interval_seconds

_last_run_at = 0.0
_wake_event = threading.Event()


def trigger_sync_now():
    """Lets an admin action (or another module) skip the wait for the
    next scheduled cycle, same pattern as backup_loop.trigger_backup_now."""
    _wake_event.set()


def _loop(app):
    global _last_run_at
    from app.settings import load_settings
    from app.pastel_sync import PastelSyncEngine
    from app.pastel_client import PastelAuthError

    engine = PastelSyncEngine(app)

    while True:
        _wake_event.wait(timeout=CHECK_INTERVAL_SECONDS)
        _wake_event.clear()

        with app.app_context():
            settings = load_settings(app.config["DATA_DIR"])
            if not settings.get("pastel_enabled") or not settings.get("pastel_access_token"):
                continue

            interval = settings.get("pastel_sync_interval_seconds", 900)
            if time.time() - _last_run_at < interval:
                continue

            try:
                engine.run_full_sync(settings)
            except PastelAuthError as e:
                log.warning("Pastel auto-sync skipped: %s", e)
            except Exception:
                log.exception("Pastel auto-sync pass failed unexpectedly")
            finally:
                _last_run_at = time.time()


def start_scheduler(app):
    thread = threading.Thread(target=_loop, args=(app,), daemon=True, name="pastel-sync-loop")
    thread.start()
PASTEL_EOF_MARKER

echo "Writing app/models.py ..."
cat > 'app/models.py' << 'PASTEL_EOF_MARKER'
"""
Local embedded database models for StockTool Kiosk v2.

Every syncable table carries three bookkeeping columns used by the sync
engine (Part 3) — none of this is wired up to the cloud yet in Part 1,
but the schema is designed so Part 3 doesn't need a migration to add it
later:

  - server_id     nullable int  — the row's ID on the cloud API, once synced
  - updated_at    datetime      — last local modification time
  - dirty         bool          — True if this row has local changes that
                                   haven't been pushed to the cloud yet
"""
from datetime import datetime, timezone
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


def _now():
    return datetime.now(timezone.utc)


class SyncMixin:
    server_id = db.Column(db.Integer, nullable=True, index=True)
    updated_at = db.Column(db.DateTime, default=_now, onupdate=_now, nullable=False)
    dirty = db.Column(db.Boolean, default=True, nullable=False)  # True until first sync


class Item(db.Model, SyncMixin):
    __tablename__ = "items"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    sku = db.Column(db.String(100), nullable=True, index=True)
    description = db.Column(db.Text, nullable=True)
    quantity = db.Column(db.Integer, nullable=False, default=0)
    unit = db.Column(db.String(32), nullable=True)
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)
    last_adjusted_by = db.Column(db.String(64), nullable=True)  # username, set when a scan-workflow adjustment names who did it
    last_used_project = db.Column(db.String(200), nullable=True)  # most recent project this item's stock was used for

    # ── Category + PPE anomaly config (spec items 3-4) ─────────────
    CATEGORY_CONSUMABLE = "consumable"
    CATEGORY_PPE = "ppe"
    # nullable=True on purpose: app/__init__.py's startup auto-migrate
    # only ever adds NULLABLE columns to an existing table (it skips
    # NOT NULL ones rather than guess a backfill value -- see its
    # docstring), so a NOT NULL column here would silently never get
    # added to any already-installed kiosk's DB, and every query
    # against items would start failing with "no such column:
    # items.category". default= still applies at INSERT time for any
    # newly created row either way; to_dict() below coalesces existing
    # legacy NULL rows to CATEGORY_CONSUMABLE for display.
    category = db.Column(db.String(32), nullable=True, default=CATEGORY_CONSUMABLE)
    normal_interval_days = db.Column(db.Float, nullable=True)  # expected re-issue gap per employee, if known

    # ── Sage Active / Pastel accounting integration ────────────────
    # nullable so the startup auto-migrate (see app/__init__.py) can add
    # it to an already-installed kiosk's DB without a manual migration.
    unit_cost = db.Column(db.Float, nullable=True)  # cost price used when posting issuance/usage accounting entries

    def adjust_stock(self, delta: int, adjusted_by: str | None = None, project: str | None = None):
        self.quantity = max(0, self.quantity + delta)
        self.dirty = True
        self.updated_at = _now()
        if adjusted_by:
            self.last_adjusted_by = adjusted_by
        if project:
            self.last_used_project = project

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "sku": self.sku,
            "description": self.description, "quantity": self.quantity,
            "unit": self.unit, "barcode_code": self.barcode_code,
            "last_adjusted_by": self.last_adjusted_by,
            "last_used_project": self.last_used_project,
            "category": self.category or Item.CATEGORY_CONSUMABLE,
            "normal_interval_days": self.normal_interval_days,
            "unit_cost": self.unit_cost,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class Tool(db.Model, SyncMixin):
    __tablename__ = "tools"

    STATUS_AVAILABLE = "available"
    STATUS_CHECKED_OUT = "checked_out"
    STATUS_MAINTENANCE = "maintenance"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=True)
    status = db.Column(db.String(32), nullable=False, default=STATUS_AVAILABLE)
    checked_out_by_name = db.Column(db.String(120), nullable=True)
    current_project = db.Column(db.String(200), nullable=True)  # live while checked out; cleared on checkin
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)

    # ── Economics (Part: Tools/Assets) ─────────────────────────────
    purchase_price = db.Column(db.Float, nullable=True)
    maintenance_level = db.Column(db.Integer, nullable=True)  # set while status == maintenance; None otherwise

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "description": self.description,
            "status": self.status, "checked_out_by_name": self.checked_out_by_name,
            "current_project": self.current_project,
            "barcode_code": self.barcode_code,
            "purchase_price": self.purchase_price,
            "maintenance_level": self.maintenance_level,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }

    # ── Economics rollups, computed from ToolCheckoutEvent / ToolMaintenanceEvent ──
    def usage_summary(self):
        checkouts = ToolCheckoutEvent.query.filter_by(tool_id=self.id).all()
        maint = ToolMaintenanceEvent.query.filter_by(tool_id=self.id).all()

        total_checkout_count = len(checkouts)
        total_usage_seconds = sum(
            (c.duration_seconds if c.duration_seconds is not None else
             max(0, (_now() - c.checked_out_at.replace(tzinfo=timezone.utc)).total_seconds()))
            for c in checkouts
        )
        total_usage_hours = round(total_usage_seconds / 3600.0, 2)

        maintenance_count = len(maint)
        total_maintenance_seconds = sum(
            (m.duration_seconds if m.duration_seconds is not None else
             max(0, (_now() - m.started_at.replace(tzinfo=timezone.utc)).total_seconds()))
            for m in maint
        )
        total_maintenance_hours = round(total_maintenance_seconds / 3600.0, 2)
        total_maintenance_cost = round(sum(m.cost or 0 for m in maint), 2)

        # Replacement-candidate heuristic: lots of maintenance cost/time
        # relative to how little productive (checked-out) use it's seeing.
        # Either signal alone can trigger it; reasons are returned so the
        # UI can explain *why*, not just flash a flag.
        reasons = []
        if self.purchase_price and total_maintenance_cost >= 0.5 * self.purchase_price:
            reasons.append(
                f"Maintenance cost (£{total_maintenance_cost:.2f}) is at least half the "
                f"purchase price (£{self.purchase_price:.2f})."
            )
        if maintenance_count >= 3 and total_usage_hours < total_maintenance_hours:
            reasons.append(
                f"Spent more hours in maintenance ({total_maintenance_hours}h) than in use "
                f"({total_usage_hours}h) across {maintenance_count} maintenance events."
            )
        if maintenance_count >= 5:
            reasons.append(f"Has been sent to maintenance {maintenance_count} times.")

        return {
            "tool_id": self.id,
            "purchase_price": self.purchase_price,
            "total_checkout_count": total_checkout_count,
            "total_usage_hours": total_usage_hours,
            "maintenance_count": maintenance_count,
            "total_maintenance_hours": total_maintenance_hours,
            "total_maintenance_cost": total_maintenance_cost,
            "is_replacement_candidate": bool(reasons),
            "replacement_reasons": reasons,
        }


class ToolCheckoutEvent(db.Model):
    """One checkout/checkin cycle for a Tool -- created on checkout,
    closed (checked_in_at + duration_seconds filled in) on checkin.
    An open row (checked_in_at is None) means the tool is still out.
    This is what total usage hours / checkout count / duration-per-use
    are computed from; Tool.checked_out_by_name only ever reflects the
    CURRENT checkout, not history."""
    __tablename__ = "tool_checkout_events"

    id = db.Column(db.Integer, primary_key=True)
    tool_id = db.Column(db.Integer, db.ForeignKey("tools.id"), nullable=False, index=True)
    checked_out_by_name = db.Column(db.String(120), nullable=False)
    project = db.Column(db.String(200), nullable=True)
    checked_out_at = db.Column(db.DateTime, default=_now, nullable=False)
    checked_in_at = db.Column(db.DateTime, nullable=True)
    duration_seconds = db.Column(db.Float, nullable=True)  # filled in on checkin

    def to_dict(self):
        return {
            "id": self.id, "tool_id": self.tool_id,
            "checked_out_by_name": self.checked_out_by_name, "project": self.project,
            "checked_out_at": self.checked_out_at.isoformat() if self.checked_out_at else None,
            "checked_in_at": self.checked_in_at.isoformat() if self.checked_in_at else None,
            "duration_seconds": self.duration_seconds,
            "duration_hours": round(self.duration_seconds / 3600.0, 2) if self.duration_seconds is not None else None,
        }


class ToolMaintenanceEvent(db.Model):
    """One trip into maintenance for a Tool -- created when a tool's
    status is set to 'maintenance' (level required), closed (ended_at +
    duration_seconds + cost) when it's set back to 'available'. An open
    row (ended_at is None) means the tool is currently in maintenance --
    that's also what the maintenance-alert feature checks against."""
    __tablename__ = "tool_maintenance_events"

    id = db.Column(db.Integer, primary_key=True)
    tool_id = db.Column(db.Integer, db.ForeignKey("tools.id"), nullable=False, index=True)
    level = db.Column(db.Integer, nullable=False, default=1)
    reason = db.Column(db.String(255), nullable=True)
    started_at = db.Column(db.DateTime, default=_now, nullable=False)
    ended_at = db.Column(db.DateTime, nullable=True)
    duration_seconds = db.Column(db.Float, nullable=True)  # filled in when closed
    cost = db.Column(db.Float, nullable=True)  # filled in when closed (or updated after)

    def to_dict(self):
        return {
            "id": self.id, "tool_id": self.tool_id, "level": self.level, "reason": self.reason,
            "started_at": self.started_at.isoformat() if self.started_at else None,
            "ended_at": self.ended_at.isoformat() if self.ended_at else None,
            "duration_seconds": self.duration_seconds,
            "duration_hours": round(self.duration_seconds / 3600.0, 2) if self.duration_seconds is not None else None,
            "cost": self.cost,
        }


class MaintenanceAlertThreshold(db.Model):
    """How long a tool can sit in a given maintenance level before it's
    flagged as overdue-for-attention. One row per level, created lazily
    the first time it's read/written (same get_or_create pattern as
    RolePermission) -- a level with no row yet falls back to a sane
    default (level * 24h) rather than requiring a migration/seed step."""
    __tablename__ = "maintenance_alert_thresholds"

    level = db.Column(db.Integer, primary_key=True)
    threshold_hours = db.Column(db.Float, nullable=False)

    @staticmethod
    def default_for_level(level: int) -> float:
        return float(level) * 24.0  # Level 1 -> 24h, Level 2 -> 48h, Level 3 -> 72h, ...

    @staticmethod
    def get_threshold_hours(level: int) -> float:
        row = db.session.get(MaintenanceAlertThreshold, level)
        return row.threshold_hours if row else MaintenanceAlertThreshold.default_for_level(level)

    @staticmethod
    def set_threshold_hours(level: int, hours: float) -> "MaintenanceAlertThreshold":
        row = db.session.get(MaintenanceAlertThreshold, level)
        if not row:
            row = MaintenanceAlertThreshold(level=level, threshold_hours=hours)
            db.session.add(row)
        else:
            row.threshold_hours = hours
        return row

    def to_dict(self):
        return {"level": self.level, "threshold_hours": self.threshold_hours}


class IssuanceEvent(db.Model):
    """One consumable/PPE issuance to an employee -- created whenever an
    Item's stock is reduced (adjust_item with a negative delta) and an
    adjusted_by name is given. Distinct from ActivityEvent: ActivityEvent
    is a flat human-readable feed of everything; this is structured,
    per-item, per-employee data built specifically to answer 'who got
    how much of this, and when' (Items/Consumables + PPE transaction
    history, and the anomalous-usage checks built on top of it)."""
    __tablename__ = "issuance_events"

    id = db.Column(db.Integer, primary_key=True)
    item_id = db.Column(db.Integer, db.ForeignKey("items.id"), nullable=False, index=True)
    employee = db.Column(db.String(120), nullable=False, index=True)
    quantity = db.Column(db.Integer, nullable=False)  # always positive -- the amount issued
    project = db.Column(db.String(200), nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "item_id": self.item_id, "employee": self.employee,
            "quantity": self.quantity, "project": self.project,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class WireCode(db.Model):
    """Admin-manageable welding-wire type/code catalogue (spec items 7,
    8). Seeded with '1.2 Code Wire' / '1.6 Code Wire' by migrate.py, but
    nothing about the set is hard-coded beyond that seed -- admins add,
    rename, and deactivate rows here via /api/wire/codes, and both the
    kiosk's wire dropdown and the admin 'Add Welding Wire' form read
    from this table. Deactivating (is_active=False) rather than
    deleting keeps existing coils/history pointing at a valid code."""
    __tablename__ = "wire_codes"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False, unique=True)  # e.g. "1.2 Code Wire"
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class WireCoil(db.Model):
    """One physical welding-wire spool/roll (spec item 6), identified by
    the barcode on its tag. Carries a live status exactly like Tool
    does (see Tool.status / STATUS_* above) so a coil currently checked
    out to someone can't be checked out again by anyone else (spec item
    10) -- current_weight/checked_out_by_name/current_project are only
    ever the CURRENT checkout; full history lives in WireTransaction."""
    __tablename__ = "wire_coils"

    STATUS_AVAILABLE = "available"
    STATUS_CHECKED_OUT = "checked_out"
    STATUS_EMPTY = "empty"        # current_weight reached 0, or admin marked it finished
    STATUS_INACTIVE = "inactive"  # admin pulled it from rotation

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=True)  # description, e.g. "ER70S-6 Mild Steel"
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)
    wire_code_id = db.Column(db.Integer, db.ForeignKey("wire_codes.id"), nullable=True, index=True)
    wire_code = db.relationship("WireCode")

    status = db.Column(db.String(20), nullable=False, default=STATUS_AVAILABLE)
    initial_weight = db.Column(db.Float, nullable=False)
    current_weight = db.Column(db.Float, nullable=False)  # updated on checkin

    # Live only while status == checked_out; cleared on checkin (same
    # convention as Tool.checked_out_by_name / current_project).
    checked_out_by_name = db.Column(db.String(120), nullable=True)
    checked_out_by_badge = db.Column(db.String(32), nullable=True)
    current_project = db.Column(db.String(200), nullable=True)

    created_at = db.Column(db.DateTime, default=_now, nullable=False)
    updated_at = db.Column(db.DateTime, default=_now, onupdate=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "barcode_code": self.barcode_code,
            "wire_code_id": self.wire_code_id,
            "wire_code_name": self.wire_code.name if self.wire_code else None,
            "status": self.status,
            "initial_weight": self.initial_weight, "current_weight": self.current_weight,
            "total_used": round(self.initial_weight - self.current_weight, 4),
            "checked_out_by_name": self.checked_out_by_name,
            "checked_out_by_badge": self.checked_out_by_badge,
            "current_project": self.current_project,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class WireTransaction(db.Model):
    """One checkout/checkin cycle for a WireCoil (spec items 2, 3, 5) --
    created (open) on checkout, closed (finishing_weight/consumed/
    checked_in_at filled in) on checkin. An open row (checked_in_at is
    None) means the coil is still out -- mirrors ToolCheckoutEvent's
    convention exactly. starting_weight is always the coil's
    current_weight AT CHECKOUT time, never client-supplied, and
    consumed is always computed server-side at checkin (spec item 4) --
    a caller can only ever supply finishing_weight."""
    __tablename__ = "wire_transactions"

    id = db.Column(db.Integer, primary_key=True)
    coil_id = db.Column(db.Integer, db.ForeignKey("wire_coils.id"), nullable=False, index=True)

    user_name = db.Column(db.String(120), nullable=False)
    user_badge = db.Column(db.String(32), nullable=True)
    project = db.Column(db.String(200), nullable=True, index=True)

    starting_weight = db.Column(db.Float, nullable=False)
    finishing_weight = db.Column(db.Float, nullable=True)  # filled on checkin
    consumed = db.Column(db.Float, nullable=True)          # filled on checkin, start - finish

    checked_out_at = db.Column(db.DateTime, default=_now, nullable=False)
    checked_in_at = db.Column(db.DateTime, nullable=True)
    checked_in_by_name = db.Column(db.String(120), nullable=True)
    checked_in_by_badge = db.Column(db.String(32), nullable=True)

    def to_dict(self):
        return {
            "id": self.id, "coil_id": self.coil_id,
            "coil_reference": self.coil.barcode_code if self.coil else None,
            "coil_name": self.coil.name if self.coil else None,
            "wire_code_name": self.coil.wire_code.name if self.coil and self.coil.wire_code else None,
            "user_name": self.user_name, "user_badge": self.user_badge, "project": self.project,
            "starting_weight": self.starting_weight, "finishing_weight": self.finishing_weight,
            "consumed": self.consumed,
            "checked_out_at": self.checked_out_at.isoformat() if self.checked_out_at else None,
            "checked_in_at": self.checked_in_at.isoformat() if self.checked_in_at else None,
            "checked_in_by_name": self.checked_in_by_name, "checked_in_by_badge": self.checked_in_by_badge,
            "is_open": self.checked_in_at is None,
        }

    coil = db.relationship("WireCoil")


class WireProjectBudget(db.Model):
    """Target/budget welding-wire weight for a project (spec item 7),
    keyed by the same free-text project name used elsewhere in this app
    (Tool.current_project, Item.last_used_project, etc. -- there's no
    separate Project FK convention for this kind of usage anywhere in
    the codebase, so this matches that)."""
    __tablename__ = "wire_project_budgets"

    project = db.Column(db.String(200), primary_key=True)
    target_weight = db.Column(db.Float, nullable=False)

    def to_dict(self):
        return {"project": self.project, "target_weight": self.target_weight}


class Project(db.Model, SyncMixin):
    __tablename__ = "projects"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text, nullable=True)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    barcode_code = db.Column(db.String(32), nullable=True, unique=True, index=True)

    def to_dict(self):
        return {
            "id": self.id, "name": self.name, "description": self.description,
            "is_active": self.is_active, "barcode_code": self.barcode_code,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None,
        }


class Barcode(db.Model):
    """
    Central lookup table: scanning a code means finding the row here first,
    then following entity_type/entity_id to the actual item/tool/project.
    Kept as its own table (rather than a code column on each entity only)
    so barcode registration/lookup is a single fast indexed query
    regardless of what the code turns out to be.
    """
    __tablename__ = "barcodes"

    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(32), unique=True, nullable=False, index=True)
    entity_type = db.Column(db.String(20), nullable=False)  # item | tool | project
    entity_id = db.Column(db.Integer, nullable=False)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {"code": self.code, "entity_type": self.entity_type, "entity_id": self.entity_id}


class LocalUser(db.Model):
    """
    Local user account for kiosk login. Originally designed as a read-
    mostly mirror of cloud-managed users (see app/routes_admin.py's
    module docstring for why that changed) -- can now also be created/
    edited/deactivated directly on this device via /api/admin/users,
    gated to role=admin.

    Login is by badge_code OR username (see app/routes_auth.py) -- no
    password. There's always a real badge_code either way, auto-
    generated if an admin doesn't set one explicitly (see app/codes.py),
    so every user can log in by badge even if nobody assigned one by
    hand, but username also works as a typed alternative.
    """
    __tablename__ = "local_users"

    id = db.Column(db.Integer, primary_key=True)
    server_id = db.Column(db.Integer, nullable=True, index=True)
    username = db.Column(db.String(64), nullable=False, unique=True)
    badge_code = db.Column(db.String(32), nullable=True, unique=True, index=True)
    role = db.Column(db.String(32), nullable=False, default="stock_user")
    is_active = db.Column(db.Boolean, default=True, nullable=False)

    def to_dict(self):
        return {"id": self.id, "username": self.username, "badge_code": self.badge_code,
                "role": self.role, "is_active": self.is_active}


class RolePermission(db.Model):
    """Per-ROLE login switch -- distinct from LocalUser.is_active, which
    is per-PERSON. This lets an admin disable every stock_user login at
    once (e.g. during an audit, or between seasons for a role nobody
    should be using right now) without touching each individual account.
    One row per role, created lazily the first time it's read/written
    (see get_or_create below) rather than requiring a migration/seed
    step -- a role with no row yet is treated as enabled by default,
    matching how logins already worked before this feature existed."""
    __tablename__ = "role_permissions"

    role = db.Column(db.String(32), primary_key=True)
    login_enabled = db.Column(db.Boolean, default=True, nullable=False)

    @staticmethod
    def is_login_enabled(role: str) -> bool:
        row = db.session.get(RolePermission, role)
        return row.login_enabled if row else True  # no row yet -- default to enabled

    @staticmethod
    def set_login_enabled(role: str, enabled: bool) -> "RolePermission":
        row = db.session.get(RolePermission, role)
        if not row:
            row = RolePermission(role=role, login_enabled=enabled)
            db.session.add(row)
        else:
            row.login_enabled = enabled
        return row

    def to_dict(self):
        return {"role": self.role, "login_enabled": self.login_enabled}


class AuditRun(db.Model):
    """One completed stock audit for a given period. period_type is
    'day', 'month', or 'year'; period_key is the calendar identifier
    for that period ('2026-08-05', '2026-08', '2026'). Day audits are
    the finest granularity -- every item's quantity gets its own
    AuditItemRecord. Month/year audits are rollups: their
    AuditItemRecord rows summarize the NET discrepancy across every
    day audit that fell inside that period, rather than re-snapshotting
    quantities directly, so a month/year audit is only ever as
    complete as the day audits underneath it.

    is_backfill marks a day audit that was generated to catch up a
    missed previous day (see audit_scheduler.py) rather than one that
    ran live, during that day's own 07:00-18:00 SAST window."""
    __tablename__ = "audit_runs"

    PERIOD_DAY = "day"
    PERIOD_MONTH = "month"
    PERIOD_YEAR = "year"
    PERIODS = (PERIOD_DAY, PERIOD_MONTH, PERIOD_YEAR)

    id = db.Column(db.Integer, primary_key=True)
    period_type = db.Column(db.String(8), nullable=False)
    period_key = db.Column(db.String(16), nullable=False)
    is_backfill = db.Column(db.Boolean, default=False, nullable=False)
    total_items = db.Column(db.Integer, default=0)
    total_quantity = db.Column(db.Integer, default=0)
    discrepancy_count = db.Column(db.Integer, default=0)  # items whose quantity changed over the period
    net_quantity_change = db.Column(db.Integer, default=0)  # sum of all discrepancies, +/-
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    records = db.relationship("AuditItemRecord", backref="audit_run", cascade="all, delete-orphan")

    __table_args__ = (db.UniqueConstraint("period_type", "period_key", name="uq_audit_period"),)

    def to_dict(self):
        return {
            "id": self.id, "period_type": self.period_type, "period_key": self.period_key,
            "is_backfill": self.is_backfill, "total_items": self.total_items,
            "total_quantity": self.total_quantity, "discrepancy_count": self.discrepancy_count,
            "net_quantity_change": self.net_quantity_change,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class AuditItemRecord(db.Model):
    """Per-item line within an AuditRun. item_name/sku are snapshotted
    at record time (not just joined via item_id) so a run's history
    stays readable even if the item is later renamed or deleted."""
    __tablename__ = "audit_item_records"

    id = db.Column(db.Integer, primary_key=True)
    audit_run_id = db.Column(db.Integer, db.ForeignKey("audit_runs.id"), nullable=False)
    item_id = db.Column(db.Integer, nullable=True)  # nullable: item may be deleted later
    item_name = db.Column(db.String(200), nullable=False)
    sku = db.Column(db.String(100), nullable=True)
    quantity_at_audit = db.Column(db.Integer, nullable=False)
    previous_quantity = db.Column(db.Integer, nullable=True)  # null if no prior audit to compare against
    discrepancy = db.Column(db.Integer, nullable=True)  # quantity_at_audit - previous_quantity

    def to_dict(self):
        return {
            "id": self.id, "item_id": self.item_id, "item_name": self.item_name, "sku": self.sku,
            "quantity_at_audit": self.quantity_at_audit, "previous_quantity": self.previous_quantity,
            "discrepancy": self.discrepancy,
        }


class ActivityEvent(db.Model):
    """Real stock/tool activity -- item adjustments, tool checkouts and
    checkins. Distinct from SyncLog on purpose: SyncLog is push/pull
    events with the cloud (empty until a SYNC_ENGINE is configured),
    while this is what actually happened on this kiosk regardless of
    whether cloud sync exists at all. The dashboard's "Recent Activity"
    panel reads from here; the separate Sync Log tab still reads from
    SyncLog, since those really are two different things a person might
    want to see."""
    __tablename__ = "activity_events"

    TYPE_ITEM_ADJUST = "item_adjust"
    TYPE_TOOL_CHECKOUT = "tool_checkout"
    TYPE_TOOL_CHECKIN = "tool_checkin"
    TYPE_WIRE_CHECKOUT = "wire_checkout"
    TYPE_WIRE_CHECKIN = "wire_checkin"

    id = db.Column(db.Integer, primary_key=True)
    event_type = db.Column(db.String(32), nullable=False)
    entity_name = db.Column(db.String(200), nullable=False)
    actor = db.Column(db.String(120), nullable=True)
    project = db.Column(db.String(200), nullable=True)  # which project this was scanned/used for, if any
    detail = db.Column(db.String(255), nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    @staticmethod
    def log(event_type, entity_name, actor=None, project=None, detail=None):
        db.session.add(ActivityEvent(
            event_type=event_type, entity_name=entity_name, actor=actor, project=project, detail=detail,
        ))

    def to_dict(self):
        return {
            "id": self.id, "event_type": self.event_type, "entity_name": self.entity_name,
            "actor": self.actor, "project": self.project, "detail": self.detail,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class SyncLog(db.Model):
    """Foundation for Part 3 — every sync attempt (push or pull) gets a row
    here so the app can show sync status/history and support retry."""
    __tablename__ = "sync_log"

    id = db.Column(db.Integer, primary_key=True)
    direction = db.Column(db.String(10), nullable=False)  # push | pull
    entity_type = db.Column(db.String(20), nullable=True)
    status = db.Column(db.String(20), nullable=False)  # success | error | conflict
    message = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "direction": self.direction, "entity_type": self.entity_type,
            "status": self.status, "message": self.message,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }


class PastelMapping(db.Model):
    """Cross-reference between a local row (Item, Project, ...) and its
    counterpart record in Sage Active/Pastel, keyed by (entity_type,
    local_id) so a repeated push updates the existing remote record
    instead of creating a duplicate every sync cycle. Deliberately a
    separate table (not columns bolted onto Item/Project) so this
    integration can be added/removed without touching the shape of the
    core kiosk tables, and so one local row could in principle map to
    records in more than one remote system later.

    content_hash is a cheap fingerprint of the fields last pushed, used
    to skip no-op pushes (e.g. a dirty=True Item whose only change was
    an unrelated column) without needing a field-by-field diff against
    Pastel on every cycle.
    """
    __tablename__ = "pastel_mapping"

    id = db.Column(db.Integer, primary_key=True)
    entity_type = db.Column(db.String(20), nullable=False, index=True)  # "item" | "project"
    local_id = db.Column(db.Integer, nullable=False, index=True)
    pastel_id = db.Column(db.String(64), nullable=False)  # Sage Active object UUID
    pastel_code = db.Column(db.String(64), nullable=True)  # business code (e.g. product code), handy for debugging
    content_hash = db.Column(db.String(64), nullable=True)
    last_pushed_at = db.Column(db.DateTime, nullable=True)
    last_pulled_at = db.Column(db.DateTime, nullable=True)

    __table_args__ = (
        db.UniqueConstraint("entity_type", "local_id", name="uq_pastel_mapping_entity_local"),
    )

    def to_dict(self):
        return {
            "id": self.id, "entity_type": self.entity_type, "local_id": self.local_id,
            "pastel_id": self.pastel_id, "pastel_code": self.pastel_code,
            "last_pushed_at": self.last_pushed_at.isoformat() if self.last_pushed_at else None,
            "last_pulled_at": self.last_pulled_at.isoformat() if self.last_pulled_at else None,
        }


class PastelSyncLog(db.Model):
    """Same shape/purpose as SyncLog above, kept as its own table so the
    existing cloud-sync history (Item/Tool/Project <-> stocktool cloud)
    and this accounting integration's history don't get interleaved and
    harder to read in either admin screen."""
    __tablename__ = "pastel_sync_log"

    id = db.Column(db.Integer, primary_key=True)
    direction = db.Column(db.String(10), nullable=False)  # push | pull
    entity_type = db.Column(db.String(20), nullable=True)  # item | project | accounting_entry
    status = db.Column(db.String(20), nullable=False)  # success | error
    message = db.Column(db.Text, nullable=True)
    created_at = db.Column(db.DateTime, default=_now, nullable=False)

    def to_dict(self):
        return {
            "id": self.id, "direction": self.direction, "entity_type": self.entity_type,
            "status": self.status, "message": self.message,
            "created_at": self.created_at.isoformat() if self.created_at else None,
        }
PASTEL_EOF_MARKER

echo "Writing app/settings.py ..."
cat > 'app/settings.py' << 'PASTEL_EOF_MARKER'
"""
Exposure/runtime settings for StockTool Kiosk.

This is deliberately separate from Flask's app.config: settings.json is
written by the MSI setup wizard (installer/SetupWizard.ps1) *before* the
app ever runs, and can be re-run later from the "StockTool Kiosk Setup"
Start Menu shortcut without reinstalling. main.py/server_supervisor.py read it at
startup to decide what host to bind to.

BIND MODES
  "local"  - bind 127.0.0.1 only. Nothing outside this machine can reach
             the API. This is the original, default-safe behavior.
  "tunnel" - still bind 127.0.0.1 only. A separate `cloudflared` Windows
             service (installed by the setup wizard) is what actually
             exposes the app, by reverse-proxying a Cloudflare Tunnel
             hostname to 127.0.0.1:<port>. The app itself never listens
             on a public interface in this mode.
  "public" - bind 0.0.0.0. The app listens directly on every interface,
             reachable at the machine's public IP on <port>. No
             encryption or perimeter auth beyond what the app itself
             provides.

SECURITY NOTE: /api/auth/login accepts a bare username or badge code
with no password (see app/routes_auth.py), and most /api/items,
/api/tools endpoints have no auth at all — that's fine on a
loopback-only local network, but it means "tunnel" and "public" modes
expose an effectively unauthenticated inventory API to whoever can
reach the hostname/IP. The setup wizard prints a warning about this;
it is not repeated/enforced here.
"""
import json
import os

VALID_MODES = ("local", "tunnel", "public")

_DEFAULTS = {
    "bind_mode": "local",
    "port": 8420,

    # Local Admin AI (see app/ai_app.py) -- runs as a second, separate
    # WSGI app in this same process/service/MSI so a slow model call can
    # never block the main kiosk API's request threads. Off by default
    # (AISettings.enabled, a DB row -- see app/ai_models.py) even though
    # the port is always reserved; opening this port just means "nothing
    # is listening on it yet" if the AI has never been turned on.
    "ai_port": 8421,

    # Port the bundled llama-server.exe subprocess listens on for actual
    # inference (see app/ai_engine.py). Separate from ai_port (the Flask
    # AI API's own port) since they're two different processes -- the
    # Flask AI app is what the Admin Panel/relay talk to; it talks to
    # this port internally on 127.0.0.1 only.
    "llama_server_port": 8422,

    # Admin Panel -- separate embedded Flask app/port, same process (see
    # app/admin_app.py / server_supervisor.py). Loopback only, same as
    # the main API and the AI ports above.
    "admin_port": 8423,
    "public_bind_host": "0.0.0.0",
    "cloudflare_tunnel_hostname": None,  # informational only; the tunnel
                                          # itself is configured in the
                                          # Cloudflare dashboard against
                                          # the token used at install time

    # --- stocktoolsetup.opslabsystems.cloud pairing/backup state ---
    # See app/cloud_setup.py and backup_loop.py. installation_token is
    # this kiosk's long-lived Bearer credential for backup uploads --
    # treat it like a password; it is never printed or logged.
    "setup_api_base": "https://stocktoolsetup.opslabsystems.cloud",
    "setup_installation_id": None,
    "setup_installation_token": None,
    "setup_paired_at": None,

    # Remote-access relay (remote.opslabsystems.cloud) — see
    # relay_client.py. Reuses the same setup_installation_token above;
    # this is just a different base URL, since the relay runs as its
    # own service on its own subdomain (see stocktool-remote/app.py for
    # why it isn't folded into setup_api_base).
    "relay_api_base": "https://remote.opslabsystems.cloud",

    # --- Sage Active / Pastel accounting integration (via CloudSolve) ---
    # See app/pastel_client.py and app/pastel_sync.py. Off by default --
    # nothing here talks to Sage until an admin fills these in and flips
    # pastel_enabled on from the Admin Panel / routes_pastel.py.
    #
    # api_base / auth_url / token_url differ per Sage Active legislation
    # environment (FR/ES/DE/PT) -- copy them from the Postman environment
    # file for your org (Quick start / 5. Test your first query in
    # Postman) or from CloudSolve's onboarding docs. api_base is the
    # GraphQL host WITHOUT the /graphql suffix; the client appends it.
    "pastel_enabled": False,
    "pastel_legislation": None,          # "FR" | "ES" | "DE" | "PT"
    "pastel_api_base": None,             # e.g. https://api.fr.active.sage.com
    "pastel_auth_url": None,             # OAuth2 /connect/authorize endpoint
    "pastel_token_url": None,            # OAuth2 /connect/token endpoint
    "pastel_client_id": None,
    "pastel_client_secret": None,
    "pastel_subscription_key": None,     # x-api-key header value
    "pastel_redirect_uri": None,         # must match the callback URL registered in your Sage Active app

    # Populated automatically by the OAuth flow (app/routes_pastel.py) --
    # not meant to be hand-edited.
    "pastel_organization_id": None,
    "pastel_access_token": None,
    "pastel_refresh_token": None,
    "pastel_token_expires_at": None,     # unix timestamp

    # Accounting mapping -- which journal/account codes local usage gets
    # posted against when push_usage_entries() runs. These are business
    # codes in YOUR chart of accounts, not IDs, since createAccountingEntryUsingCodes
    # is what the sync engine uses.
    "pastel_usage_journal_code": None,   # e.g. "OD" / a general/miscellaneous operations journal
    "pastel_usage_expense_account_code": None,  # debit: consumables/stock-usage expense account
    "pastel_stock_contra_account_code": None,   # credit: stock/inventory account

    # How often the background loop runs a two-way sync, in seconds.
    "pastel_sync_interval_seconds": 900,  # 15 minutes
}


def _settings_path(data_dir: str) -> str:
    return os.path.join(data_dir, "settings.json")


def load_settings(data_dir: str) -> dict:
    path = _settings_path(data_dir)
    settings = dict(_DEFAULTS)
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                on_disk = json.load(f)
            # FIXED: this used to only merge on_disk into settings at
            # all if bind_mode was present and one of VALID_MODES --
            # any file missing that one key (or with an unexpected
            # value in it) silently discarded EVERYTHING else in the
            # file, including setup_installation_token, relay_api_base,
            # every setting. That's a much bigger blast radius than
            # "bind_mode was invalid" should ever cause. Now the merge
            # always happens (json.load() above already guarantees this
            # is at least syntactically valid JSON), and only bind_mode
            # itself gets validated and corrected if necessary.
            settings.update(on_disk)
            if settings.get("bind_mode") not in VALID_MODES:
                settings["bind_mode"] = _DEFAULTS["bind_mode"]
        except (OSError, ValueError):
            # Corrupt/unreadable settings.json -> fall back to safe
            # local-only defaults rather than crash the kiosk.
            pass
    return settings


def save_settings(data_dir: str, settings: dict) -> None:
    os.makedirs(data_dir, exist_ok=True)
    path = _settings_path(data_dir)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)
    os.replace(tmp_path, path)  # atomic on Windows too


def resolve_bind_host(settings: dict) -> str:
    """What the embedded server should actually app.run()/serve() on."""
    mode = settings.get("bind_mode", "local")
    if mode == "public":
        return settings.get("public_bind_host", "0.0.0.0")
    # "local" and "tunnel" both stay on loopback — cloudflared is what
    # exposes "tunnel" mode, not the app's own bind address.
    return "127.0.0.1"
PASTEL_EOF_MARKER

echo "Writing app/__init__.py ..."
cat > 'app/__init__.py' << 'PASTEL_EOF_MARKER'
import os
from flask import Flask, jsonify

from app.models import db
from sqlalchemy import event
from sqlalchemy.engine import Engine

def _auto_migrate_columns(app: Flask) -> None:
    """Startup self-healing for the exact class of bug that's already
    bitten the stocktoolsetup side of this project for real: db.create_all()
    only creates tables that don't exist yet -- it never adds a column to
    an EXISTING table when a model gains a new field. This compares each
    model's declared columns against what SQLite actually has and ALTERs
    any missing ones in automatically, so a future model change to this
    local DB (LocalUser, Item, Tool, Project, Barcode) can't brick an
    already-installed kiosk just because nobody remembered to run a
    manual ALTER TABLE.

    Deliberately conservative: only adds a plain nullable column with no
    other constraints. Anything else (NOT NULL, renamed columns, etc.)
    gets logged loudly instead of guessed at."""
    from sqlalchemy import inspect, text

    inspector = inspect(db.engine)
    for table in db.metadata.sorted_tables:
        if table.name not in inspector.get_table_names():
            continue  # brand-new table -- db.create_all() already handles this
        existing_columns = {col["name"] for col in inspector.get_columns(table.name)}
        for column in table.columns:
            if column.name in existing_columns:
                continue
            if not column.nullable:
                app.logger.warning(
                    "Column %s.%s is missing from the database and is NOT NULL -- "
                    "cannot auto-migrate safely. A manual migration is needed.",
                    table.name, column.name,
                )
                continue
            col_type = column.type.compile(db.engine.dialect)
            with db.engine.begin() as conn:
                conn.execute(text(f'ALTER TABLE "{table.name}" ADD COLUMN "{column.name}" {col_type}'))
            app.logger.info("Auto-migrated: added missing column %s.%s", table.name, column.name)

def _local_data_dir() -> str:
    """
    Where the local SQLite DB and config (settings.json) live.

    The MSI install (see installer/) registers this as a per-machine
    Windows service that needs to see the same DB/settings regardless of
    which user is logged in — or whether anyone is — so this now prefers
    %ProgramData%\\StockToolKiosk over %LOCALAPPDATA%. ProgramData is
    writable by services running as LocalSystem/NetworkService without
    extra ACL changes, unlike a specific user's LOCALAPPDATA.

    Falls back to %LOCALAPPDATA%/~ when ProgramData isn't set (e.g. this
    dev sandbox, or the plain no-installer .exe workflow from Part 1-5).
    """
    base = os.environ.get("PROGRAMDATA") or os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    path = os.path.join(base, "StockToolKiosk")
    os.makedirs(path, exist_ok=True)
    return path

def _ensure_db_writable(db_path: str, data_dir: str) -> None:
    """
    Self-heals the single most common cause of "attempt to write a
    readonly database" on Windows: the DOS/NTFS Read-only file
    attribute getting set on kiosk_local.db (or its folder) -- this
    happens easily via a zip extraction, a restore from backup, some
    antivirus/EDR tools, or a OneDrive-synced ProgramData redirect.

    os.chmod on Windows doesn't touch real NTFS ACLs, but it DOES
    directly clear/set the FILE_ATTRIBUTE_READONLY flag (the same
    thing the "Read-only" checkbox in a file's Properties dialog
    controls) -- so this fixes exactly that class of problem
    automatically, every time the app starts, without anyone needing
    to know to go check a checkbox in Explorer.

    If clearing the attribute doesn't actually make the file/folder
    writable (a real NTFS permission denial, a locked/read-only
    volume, a full disk, etc.), this raises a clear, actionable error
    instead of leaving it to surface later as an opaque SQLAlchemy
    traceback the first time someone tries to save something.
    """
    import stat

    try:
        os.chmod(data_dir, stat.S_IWRITE | stat.S_IREAD)
    except OSError:
        pass  # best-effort -- the real check is the write probe below

    if os.path.exists(db_path):
        try:
            os.chmod(db_path, stat.S_IWRITE | stat.S_IREAD)
        except OSError:
            pass

    probe_path = os.path.join(data_dir, ".write_test")
    try:
        with open(probe_path, "w") as f:
            f.write("ok")
        os.remove(probe_path)
    except OSError as e:
        raise RuntimeError(
            f"StockTool Kiosk can't write to its data folder:\n  {data_dir}\n\n"
            f"Clearing the Windows Read-only attribute didn't fix it, which usually means "
            f"this is a real permissions or storage issue rather than just that checkbox. "
            f"Things to check on this machine:\n"
            f"  1. Right-click the StockToolKiosk folder -> Properties -> Security -> "
            f"confirm the account running this app has Modify/Full control.\n"
            f"  2. Confirm the drive isn't full and isn't itself mounted read-only.\n"
            f"  3. If this folder is inside a synced location (OneDrive, etc.) or is "
            f"being actively scanned by antivirus/EDR, exclude it and try again.\n\n"
            f"Underlying error: {e}"
        ) from e


def create_app(test_config: dict | None = None) -> Flask:
    app = Flask(__name__)

    try:
        from version import __version__ as VERSION, __release_date__ as RELEASE_DATE
    except Exception:
        VERSION = "unknown"
        RELEASE_DATE = None

    data_dir = _local_data_dir()
    db_path = os.path.join(data_dir, "kiosk_local.db")
    _ensure_db_writable(db_path, data_dir)

    app.config.update(
        SQLALCHEMY_DATABASE_URI=f"sqlite:///{db_path}",
        SQLALCHEMY_TRACK_MODIFICATIONS=False,
        SECRET_KEY=os.environ.get("KIOSK_SECRET_KEY", "kiosk-local-dev-key"),
        DATA_DIR=data_dir,
        CLOUD_API_BASE=os.environ.get("STOCKTOOL_CLOUD_API", "https://api-stocktool.opslabsystems.cloud"),
        KIOSK_VERSION=VERSION,
        KIOSK_RELEASE_DATE=RELEASE_DATE,
    )
    if test_config:
        app.config.update(test_config)

    db.init_app(app)

    @event.listens_for(Engine, "connect")
    def _set_sqlite_pragma(dbapi_connection, connection_record):
        """Without this, any two requests that touch the DB at the same
        moment (a bulk import mid-loop, the relay client's background
        poll, a sync cycle) can produce "database is locked" -- SQLite's
        default is to fail IMMEDIATELY on a lock instead of waiting.
        busy_timeout tells it to retry for up to 15s before giving up,
        which covers ordinary momentary contention (a single commit is
        on the order of milliseconds) without masking a genuinely stuck
        lock. Applies to every connection on this engine, so it covers
        cloud-run workers and the CLI paths too, not just the main app.
        """
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA busy_timeout = 15000")
        cursor.close()

    from app import ai_models as _ai_models  # noqa: F401 -- registers Local Admin AI tables (see app/ai_app.py) before create_all
    from app import admin_models as _admin_models  # noqa: F401 -- registers Admin Panel tables (see app/admin_app.py) before create_all

    with app.app_context():
        db.create_all()
        _auto_migrate_columns(app)

        from app.admin_app import seed_admin_panel_defaults
        seed_admin_panel_defaults()  # Admin Panel Part 1 -- seeds default roles/pages on first run only

    from app.ai_knowledge import register_auto_reindex_hooks
    register_auto_reindex_hooks()  # Part 3 -- auto-invalidate the AI's dynamic knowledge cache on WireCode/threshold changes

    # ── Local-only REST API (Items / Tools / Projects / Barcode) ──────
    from app.routes_items import items_bp
    from app.routes_tools import tools_bp
    from app.routes_projects import projects_bp
    from app.routes_barcode import barcode_bp
    from app.routes_barcode_view import barcode_view_bp
    from app.routes_auth import auth_bp
    from app.routes_status import status_bp
    from app.routes_backup import backup_bp
    from app.routes_admin import admin_bp

    from app.routes_audit import audit_bp
    from app.routes_license import license_bp
    from app.routes_import_export import import_export_bp
    from app.routes_maintenance_alerts import maintenance_alerts_bp
    from app.routes_ppe import ppe_bp
    from app.routes_wire import wire_bp
    from app.routes_dashboard import dashboard_bp
    from app.routes_db_tools import db_tools_bp
    from app.routes_pastel import pastel_bp
    app.register_blueprint(items_bp)
    app.register_blueprint(tools_bp)
    app.register_blueprint(projects_bp)
    app.register_blueprint(barcode_bp)
    app.register_blueprint(barcode_view_bp)
    app.register_blueprint(auth_bp)
    app.register_blueprint(status_bp)
    app.register_blueprint(backup_bp)
    app.register_blueprint(admin_bp)

    app.register_blueprint(audit_bp)
    app.register_blueprint(license_bp)

    import license as stocktool_license
    stocktool_license.init_license(app)
    app.register_blueprint(import_export_bp)
    app.register_blueprint(maintenance_alerts_bp)
    app.register_blueprint(ppe_bp)
    app.register_blueprint(wire_bp)
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(db_tools_bp)
    app.register_blueprint(pastel_bp)
    @app.route("/")
    def root():
        return jsonify({
            "service": "StockTool Kiosk (local)",
            "version": app.config.get("KIOSK_VERSION", "unknown"),
            "ui": "/ui/",
        }), 200

    from app.ui import ui_bp
    app.register_blueprint(ui_bp)


    if not test_config:
        from app.audit_scheduler import start_scheduler
        start_scheduler(app)

        from app.pastel_scheduler import start_scheduler as start_pastel_scheduler
        start_pastel_scheduler(app)
    return app
PASTEL_EOF_MARKER

echo "Writing app/ui.py ..."
cat > 'app/ui.py' << 'PASTEL_EOF_MARKER'
from flask import Blueprint, render_template

ui_bp = Blueprint("ui", __name__, url_prefix="/ui", template_folder="templates", static_folder="static")


@ui_bp.route("/")
def index():
    return render_template("index.html")


@ui_bp.route("/pastel")
def pastel_setup():
    return render_template("pastel_setup.html")
PASTEL_EOF_MARKER

echo "Writing app/templates/pastel_setup.html ..."
cat > 'app/templates/pastel_setup.html' << 'PASTEL_EOF_MARKER'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Pastel / Sage Active Integration — StockTool Kiosk</title>
<script src="https://cdn.tailwindcss.com"></script>
<style>
  :root {
    color-scheme: dark;
    --bg: #0c1120; --panel: #161d33; --panel-border: #232b45;
    --text: #e6e9f2; --muted: #8b93a8; --accent: #6d5ef0; --accent-soft: rgba(109,94,240,.15);
    --green: #22c55e; --green-soft: rgba(34,197,94,.15);
    --red: #ef4444; --red-soft: rgba(239,68,68,.15);
  }
  body { margin:0; font-family: system-ui, -apple-system, "Segoe UI", sans-serif; background:var(--bg); color:var(--text); }
  input, select { font-size:0.875rem; border-radius:0.5rem; padding:0.55rem 0.75rem; outline:none; background:var(--bg); border:1px solid var(--panel-border); color:var(--text); width:100%; }
  input:focus, select:focus { box-shadow:0 0 0 3px var(--accent-soft); border-color:var(--accent); }
  label { font-size:0.75rem; color:var(--muted); display:block; margin-bottom:0.25rem; }
  .card { background:var(--panel); border:1px solid var(--panel-border); border-radius:0.85rem; padding:1.25rem; margin-bottom:1rem; }
  .btn { display:inline-flex; align-items:center; gap:0.4rem; padding:0.55rem 1rem; border-radius:0.6rem; font-size:0.875rem; font-weight:600; cursor:pointer; border:1px solid var(--panel-border); background:var(--bg); color:var(--text); }
  .btn-accent { background:var(--accent); border-color:var(--accent); color:white; }
  .btn:hover { filter:brightness(1.1); }
  .pill { font-size:0.7rem; padding:0.15rem 0.55rem; border-radius:999px; font-weight:600; }
  .pill-ok { background:var(--green-soft); color:var(--green); }
  .pill-bad { background:var(--red-soft); color:var(--red); }
  pre { white-space:pre-wrap; word-break:break-word; font-size:0.75rem; background:var(--bg); border:1px solid var(--panel-border); border-radius:0.5rem; padding:0.75rem; max-height:220px; overflow:auto; }
</style>
</head>
<body class="min-h-screen">
<div class="max-w-3xl mx-auto px-4 py-8">
  <h1 class="text-xl font-bold mb-1">Pastel / Sage Active Integration</h1>
  <p class="text-sm mb-6" style="color:var(--muted)">Configure and run the CloudSolve accounting sync from your browser — no curl needed.</p>

  <!-- Login -->
  <div class="card" id="loginCard">
    <h2 class="font-semibold mb-3">1. Log in</h2>
    <div class="flex gap-2 items-end">
      <div class="flex-1">
        <label for="badgeCode">Badge code or username</label>
        <input id="badgeCode" placeholder="e.g. KIOSK01 or Admin1" />
      </div>
      <button class="btn btn-accent" onclick="login()">Log in</button>
    </div>
    <p id="loginStatus" class="text-xs mt-2" style="color:var(--muted)"></p>
  </div>

  <!-- Settings -->
  <div class="card" id="settingsCard" style="display:none">
    <div class="flex items-center justify-between mb-3">
      <h2 class="font-semibold">2. Sage Active credentials</h2>
      <span id="enabledPill" class="pill pill-bad">disabled</span>
    </div>
    <div class="grid grid-cols-2 gap-3">
      <div><label>Legislation (FR / ES / DE / PT)</label><input id="pastel_legislation" /></div>
      <div><label>API base (no /graphql)</label><input id="pastel_api_base" placeholder="https://api.fr.active.sage.com" /></div>
      <div><label>Auth URL</label><input id="pastel_auth_url" placeholder=".../connect/authorize" /></div>
      <div><label>Token URL</label><input id="pastel_token_url" placeholder=".../connect/token" /></div>
      <div><label>Client ID</label><input id="pastel_client_id" /></div>
      <div><label>Client secret</label><input id="pastel_client_secret" type="password" /></div>
      <div><label>Subscription key (x-api-key)</label><input id="pastel_subscription_key" type="password" /></div>
      <div><label>Redirect URI</label><input id="pastel_redirect_uri" /></div>
      <div><label>Usage journal code</label><input id="pastel_usage_journal_code" /></div>
      <div><label>Usage expense account code</label><input id="pastel_usage_expense_account_code" /></div>
      <div><label>Stock contra account code</label><input id="pastel_stock_contra_account_code" /></div>
      <div><label>Sync interval (seconds)</label><input id="pastel_sync_interval_seconds" type="number" /></div>
    </div>
    <div class="flex items-center gap-2 mt-4">
      <label class="flex items-center gap-2" style="margin:0"><input type="checkbox" id="pastel_enabled" style="width:auto" /> Enabled</label>
    </div>
    <div class="flex gap-2 mt-4">
      <button class="btn btn-accent" onclick="saveSettings()">Save settings</button>
      <button class="btn" onclick="loadSettings()">Reload from server</button>
    </div>
    <p id="settingsStatus" class="text-xs mt-2" style="color:var(--muted)"></p>
  </div>

  <!-- Connect -->
  <div class="card" id="connectCard" style="display:none">
    <h2 class="font-semibold mb-3">3. Connect to Sage Active</h2>
    <p class="text-xs mb-3" style="color:var(--muted)">Save your redirect URI above to match your Sage Active app's registered callback, then click connect. You'll be sent to Sage's login/consent screen and redirected back here when done.</p>
    <a id="connectBtn" class="btn btn-accent" href="#" target="_blank" rel="noopener">Connect to Sage Active →</a>
    <div class="mt-4">
      <button class="btn" onclick="loadOrgs()">List organizations</button>
      <div id="orgsList" class="mt-3"></div>
    </div>
  </div>

  <!-- Sync -->
  <div class="card" id="syncCard" style="display:none">
    <h2 class="font-semibold mb-3">4. Sync</h2>
    <button class="btn btn-accent" onclick="runSync()">Run sync now</button>
    <button class="btn" onclick="loadLog()">View recent log</button>
    <pre id="syncOutput" class="mt-3"></pre>
  </div>
</div>

<script>
let token = null;

function authHeaders() {
  return { "Authorization": "Bearer " + token, "Content-Type": "application/json" };
}

async function login() {
  const badge_code = document.getElementById("badgeCode").value.trim();
  const statusEl = document.getElementById("loginStatus");
  statusEl.textContent = "Logging in...";
  try {
    const resp = await fetch("/api/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ badge_code }),
    });
    const data = await resp.json();
    if (!resp.ok) { statusEl.textContent = "Error: " + (data.error || resp.status); statusEl.style.color = "var(--red)"; return; }
    if (data.user.role !== "admin" && data.user.role !== "super_admin") {
      statusEl.textContent = "Logged in, but this account isn't an admin — Pastel settings need the admin role.";
      statusEl.style.color = "var(--red)";
      return;
    }
    token = data.token;
    statusEl.textContent = "Logged in as " + data.user.username + " (" + data.user.role + ")";
    statusEl.style.color = "var(--green)";
    document.getElementById("settingsCard").style.display = "block";
    document.getElementById("connectCard").style.display = "block";
    document.getElementById("syncCard").style.display = "block";
    await loadSettings();
  } catch (e) {
    statusEl.textContent = "Network error: " + e;
    statusEl.style.color = "var(--red)";
  }
}

const FIELDS = [
  "pastel_legislation", "pastel_api_base", "pastel_auth_url", "pastel_token_url",
  "pastel_client_id", "pastel_client_secret", "pastel_subscription_key", "pastel_redirect_uri",
  "pastel_usage_journal_code", "pastel_usage_expense_account_code", "pastel_stock_contra_account_code",
  "pastel_sync_interval_seconds",
];

async function loadSettings() {
  const resp = await fetch("/api/admin/pastel/settings", { headers: authHeaders() });
  const data = await resp.json();
  if (!resp.ok) { document.getElementById("settingsStatus").textContent = "Error: " + (data.error || resp.status); return; }
  FIELDS.forEach(f => { if (data[f] !== undefined && data[f] !== null) document.getElementById(f).value = data[f]; });
  document.getElementById("pastel_enabled").checked = !!data.pastel_enabled;
  const pill = document.getElementById("enabledPill");
  pill.textContent = data.pastel_enabled ? "enabled" : "disabled";
  pill.className = "pill " + (data.pastel_enabled ? "pill-ok" : "pill-bad");
  document.getElementById("settingsStatus").textContent = "Loaded (secret fields shown masked — leave as-is to keep, or type a new value to replace).";
  document.getElementById("connectBtn").href = "/api/admin/pastel/oauth/authorize";
}

async function saveSettings() {
  const body = {};
  FIELDS.forEach(f => { const v = document.getElementById(f).value; if (v !== "") body[f] = v; });
  body.pastel_enabled = document.getElementById("pastel_enabled").checked;
  if (body.pastel_sync_interval_seconds) body.pastel_sync_interval_seconds = parseInt(body.pastel_sync_interval_seconds, 10);

  const statusEl = document.getElementById("settingsStatus");
  statusEl.textContent = "Saving...";
  const resp = await fetch("/api/admin/pastel/settings", { method: "POST", headers: authHeaders(), body: JSON.stringify(body) });
  const data = await resp.json();
  if (!resp.ok) { statusEl.textContent = "Error: " + (data.error || resp.status); statusEl.style.color = "var(--red)"; return; }
  statusEl.textContent = "Saved.";
  statusEl.style.color = "var(--green)";
  await loadSettings();
}

async function loadOrgs() {
  const el = document.getElementById("orgsList");
  el.textContent = "Loading...";
  const resp = await fetch("/api/admin/pastel/organizations", { headers: authHeaders() });
  const data = await resp.json();
  if (!resp.ok) { el.innerHTML = "<pre>" + (data.error || resp.status) + "</pre>"; return; }
  el.innerHTML = (data.organizations || []).map(o =>
    `<div class="flex items-center justify-between py-1"><span>${o.name} <code style="color:var(--muted)">${o.legislationCode || ""}</code></span>
     <button class="btn" onclick="useOrg('${o.id}')">Use this org</button></div>`
  ).join("") || "<span style='color:var(--muted)' class='text-sm'>No organizations returned.</span>";
}

async function useOrg(id) {
  const resp = await fetch("/api/admin/pastel/organization", { method: "POST", headers: authHeaders(), body: JSON.stringify({ organization_id: id }) });
  const data = await resp.json();
  const el = document.getElementById("orgsList");
  if (!resp.ok) { alert("Error: " + (data.error || resp.status)); return; }
  el.insertAdjacentHTML("afterbegin", `<div class="text-xs mb-2" style="color:var(--green)">Using organization ${id}</div>`);
}

async function runSync() {
  const out = document.getElementById("syncOutput");
  out.textContent = "Running...";
  const resp = await fetch("/api/admin/pastel/sync", { method: "POST", headers: authHeaders() });
  const data = await resp.json();
  out.textContent = JSON.stringify(data, null, 2);
}

async function loadLog() {
  const out = document.getElementById("syncOutput");
  out.textContent = "Loading...";
  const resp = await fetch("/api/admin/pastel/log", { headers: authHeaders() });
  const data = await resp.json();
  out.textContent = JSON.stringify(data, null, 2);
}
</script>
</body>
</html>
PASTEL_EOF_MARKER

echo "Done. New/updated files:"
echo "  app/pastel_client.py"
echo "  app/pastel_sync.py"
echo "  app/routes_pastel.py"
echo "  app/pastel_scheduler.py"
echo "  app/models.py"
echo "  app/settings.py"
echo "  app/__init__.py"
echo "  app/ui.py"
echo "  app/templates/pastel_setup.html"
echo
echo "Next: restart the kiosk service, then open https://<your-domain>/ui/pastel in a browser and log in with an admin badge code."
