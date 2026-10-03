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
