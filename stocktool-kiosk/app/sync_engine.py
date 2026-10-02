"""
Sync engine — talks to the Part 2 cloud endpoints (/api/installations,
/api/config, /api/updates, /api/sync/*) to keep the local database in
sync with the cloud, while remaining fully usable offline.

Design choices worth knowing:
  - Registration happens once, automatically, on first successful
    contact with the cloud. The install token is stored locally in
    SyncState and used for every subsequent call.
  - Pull matches incoming rows to local rows by server_id first, then
    falls back to barcode_code, then sku/tool_number/name — because the
    very first pull for a fresh install has no server_id links yet.
  - A local row with dirty=True is NEVER overwritten by a pull. It's
    left alone until the next push resolves it (applied or conflict) —
    this is what prevents an incoming sync from silently discarding an
    offline change that hasn't reached the cloud yet.
  - All network calls are wrapped — any failure (offline, DNS, cloud
    down, timeout) is caught, logged to SyncLog, and the engine just
    tries again next cycle. It never crashes the app.
"""
import socket
import logging
from datetime import datetime, timezone

import requests

from app.models import db, Item, Tool, Project, Barcode, LocalUser, SyncState, SyncLog

log = logging.getLogger("sync")


def _device_name() -> str:
    try:
        return socket.gethostname()
    except Exception:
        return "Unknown Kiosk"


def _parse_dt(raw):
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        return dt.replace(tzinfo=None) if dt.tzinfo else dt
    except ValueError:
        return None


class SyncEngine:
    def __init__(self, app):
        self.app = app
        self.cloud_base = app.config["CLOUD_API_BASE"].rstrip("/")

    def _headers(self, state):
        return {"Authorization": f"Bearer {state.install_token}"}

    def _log(self, direction, entity_type, status, message):
        db.session.add(SyncLog(direction=direction, entity_type=entity_type, status=status, message=message))
        db.session.commit()

    # ── Registration ────────────────────────────────────────────────────

    def ensure_registered(self) -> bool:
        with self.app.app_context():
            state = SyncState.get()
            if state.is_registered:
                return True
            try:
                resp = requests.post(f"{self.cloud_base}/api/installations/register", json={
                    "device_name": _device_name(),
                    "app_version": self.app.config.get("KIOSK_VERSION", "2.0.0-dev"),
                }, timeout=10)
                resp.raise_for_status()
                data = resp.json()
                state.installation_id = data["installation_id"]
                state.install_token = data["token"]
                db.session.commit()
                self._log("push", None, "success", "Registered with cloud API.")
                log.info("Registered as installation %s", state.installation_id)
                return True
            except Exception as e:
                self._log("push", None, "error", f"Registration failed: {e}")
                return False

    # ── Heartbeat / config / update-check ──────────────────────────────

    def heartbeat(self):
        with self.app.app_context():
            state = SyncState.get()
            if not state.is_registered:
                return
            try:
                requests.post(f"{self.cloud_base}/api/installations/heartbeat",
                               headers=self._headers(state),
                               json={"app_version": self.app.config.get("KIOSK_VERSION", "2.0.0-dev")},
                               timeout=10).raise_for_status()
                state.last_heartbeat_at = datetime.now(timezone.utc)
                db.session.commit()
            except Exception as e:
                self._log("push", None, "error", f"Heartbeat failed: {e}")

    def fetch_config(self):
        """Pulls sync_interval_seconds etc. from the cloud and applies it
        locally. Safe to call even if unreachable — just keeps whatever
        interval was last known (or the default)."""
        with self.app.app_context():
            state = SyncState.get()
            if not state.is_registered:
                return
            try:
                resp = requests.get(f"{self.cloud_base}/api/config", headers=self._headers(state), timeout=10)
                resp.raise_for_status()
                cfg = resp.json()
                if cfg.get("sync_interval_seconds"):
                    state.sync_interval_seconds = cfg["sync_interval_seconds"]
                    db.session.commit()
            except Exception as e:
                self._log("pull", None, "error", f"Config fetch failed: {e}")

    def check_for_update(self) -> dict | None:
        with self.app.app_context():
            state = SyncState.get()
            if not state.is_registered:
                return None
            try:
                resp = requests.get(f"{self.cloud_base}/api/updates/latest",
                                     headers=self._headers(state), params={"channel": "stable"}, timeout=10)
                if resp.status_code == 404:
                    return None
                resp.raise_for_status()
                state.last_update_check_at = datetime.now(timezone.utc)
                db.session.commit()
                return resp.json()
            except Exception as e:
                self._log("pull", None, "error", f"Update check failed: {e}")
                return None

    # ── Pull ────────────────────────────────────────────────────────────

    def pull(self) -> bool:
        with self.app.app_context():
            state = SyncState.get()
            if not state.is_registered:
                return False
            try:
                params = {}
                if state.last_pull_cursor:
                    params["since"] = state.last_pull_cursor
                resp = requests.get(f"{self.cloud_base}/api/sync/pull", headers=self._headers(state),
                                     params=params, timeout=20)
                resp.raise_for_status()
                payload = resp.json()
                data = payload.get("data", {})

                applied = 0
                skipped_dirty = 0
                # Order matters: items/tools/projects first so barcodes
                # (which reference them by server_id) can resolve local rows.
                # _upsert_* returns 1 for an applied row, 0 for a row
                # skipped because the local row has unpushed changes.
                for row in data.get("items", []):
                    result = self._upsert_item(row)
                    applied += result
                    skipped_dirty += 1 - result
                for row in data.get("tools", []):
                    result = self._upsert_tool(row)
                    applied += result
                    skipped_dirty += 1 - result
                for row in data.get("projects", []):
                    result = self._upsert_project(row)
                    applied += result
                    skipped_dirty += 1 - result
                for row in data.get("barcodes", []):
                    result = self._upsert_barcode(row)
                    applied += result
                    skipped_dirty += 1 - result
                for row in data.get("users", []):
                    result = self._upsert_user(row)
                    applied += result
                    skipped_dirty += 1 - result

                state.last_pull_cursor = payload["server_time"]
                state.last_pull_at = datetime.now(timezone.utc)
                db.session.commit()
                msg = f"Applied {applied} row(s)."
                if skipped_dirty:
                    msg += f" Skipped {skipped_dirty} row(s) with unpushed local changes."
                self._log("pull", None, "success", msg)
                return True
            except Exception as e:
                self._log("pull", None, "error", str(e))
                return False

    def _upsert_item(self, row: dict) -> int:
        item = Item.query.filter_by(server_id=row["id"]).first()
        if not item and row.get("barcode_code"):
            item = Item.query.filter_by(barcode_code=row["barcode_code"]).first()
        if not item and row.get("sku"):
            item = Item.query.filter_by(sku=row["sku"]).first()
        if item and item.dirty:
            return 0  # unpushed local change — leave it, next push will reconcile
        is_new = item is None
        if is_new:
            item = Item()
            db.session.add(item)
        item.server_id = row["id"]
        item.name = row["name"]
        item.sku = row.get("sku")
        item.description = row.get("description")
        item.quantity = row["quantity"]
        item.unit = row.get("unit")
        item.barcode_code = row.get("barcode_code")
        item.dirty = False
        item.pending_delta = 0
        item.updated_at = _parse_dt(row.get("updated_at")) or datetime.utcnow()
        return 1

    def _upsert_tool(self, row: dict) -> int:
        tool = Tool.query.filter_by(server_id=row["id"]).first()
        if not tool and row.get("barcode_code"):
            tool = Tool.query.filter_by(barcode_code=row["barcode_code"]).first()
        if tool and tool.dirty:
            return 0
        if not tool:
            tool = Tool()
            db.session.add(tool)
        tool.server_id = row["id"]
        tool.name = row["name"]
        tool.description = row.get("description")
        tool.status = row.get("status", "available")
        tool.checked_out_by_name = row.get("checked_out_by")
        tool.barcode_code = row.get("barcode_code")
        tool.dirty = False
        tool.updated_at = _parse_dt(row.get("updated_at")) or datetime.utcnow()
        return 1

    def _upsert_project(self, row: dict) -> int:
        project = Project.query.filter_by(server_id=row["id"]).first()
        if not project and row.get("barcode_code"):
            project = Project.query.filter_by(barcode_code=row["barcode_code"]).first()
        if project and project.dirty:
            return 0
        if not project:
            project = Project()
            db.session.add(project)
        project.server_id = row["id"]
        project.name = row["name"]
        project.description = row.get("description")
        project.is_active = row.get("is_active", True)
        project.barcode_code = row.get("barcode_code")
        project.dirty = False
        project.updated_at = _parse_dt(row.get("updated_at")) or datetime.utcnow()
        return 1

    def _upsert_barcode(self, row: dict) -> int:
        code = row.get("code")
        if not code or Barcode.query.filter_by(code=code).first():
            return 0
        entity_type = row.get("entity_type")
        server_id = row.get(f"{entity_type}_id")
        model = {"item": Item, "tool": Tool, "project": Project}.get(entity_type)
        if not model or not server_id:
            return 0
        local_entity = model.query.filter_by(server_id=server_id).first()
        if not local_entity:
            return 0  # its parent row hasn't been pulled yet — will resolve on a later pull
        db.session.add(Barcode(code=code, entity_type=entity_type, entity_id=local_entity.id))
        local_entity.barcode_code = code
        return 1

    def _upsert_user(self, row: dict) -> int:
        user = LocalUser.query.filter_by(server_id=row["id"]).first()
        if not user:
            user = LocalUser(server_id=row["id"], username=row["username"])
            db.session.add(user)
        user.role = row.get("role", "stock_user")
        user.badge_code = row.get("badge_code")
        user.is_active = row.get("is_active", True)
        return 1

    # ── Push ────────────────────────────────────────────────────────────

    def push(self) -> bool:
        with self.app.app_context():
            state = SyncState.get()
            if not state.is_registered:
                return False

            dirty_items = (Item.query.filter_by(dirty=True)
                           .filter(Item.server_id.isnot(None))
                           .filter(Item.pending_delta != 0)
                           .all())
            dirty_tools = Tool.query.filter_by(dirty=True).filter(Tool.server_id.isnot(None)).all()

            if not dirty_items and not dirty_tools:
                return True  # nothing to push — not an error

            payload = {
                "items": [{
                    "server_id": i.server_id,
                    "delta": i.pending_delta,
                    "local_updated_at": i.updated_at.isoformat(),
                } for i in dirty_items],
                "tools": [],
            }
            # Tool pushes are action-based (checkout/checkin), inferred from
            # current local status rather than a delta.
            for t in dirty_tools:
                action = "checkout" if t.status == Tool.STATUS_CHECKED_OUT else "checkin"
                payload["tools"].append({
                    "server_id": t.server_id, "action": action,
                    "local_updated_at": t.updated_at.isoformat(),
                })

            try:
                resp = requests.post(f"{self.cloud_base}/api/sync/push", headers=self._headers(state),
                                      json=payload, timeout=20)
                resp.raise_for_status()
                results = resp.json()["results"]

                for i, result in zip(dirty_items, results.get("items", [])):
                    self._apply_push_result(i, result, "item")
                for t, result in zip(dirty_tools, results.get("tools", [])):
                    self._apply_push_result(t, result, "tool")

                state.last_push_at = datetime.now(timezone.utc)
                db.session.commit()
                self._log("push", None, "success", f"Pushed {len(dirty_items)} item(s), {len(dirty_tools)} tool(s).")
                return True
            except Exception as e:
                self._log("push", None, "error", str(e))
                return False

    def _apply_push_result(self, local_row, result: dict, entity_type: str):
        status = result.get("status")
        current = result.get("current")

        if status in ("applied", "conflict"):
            # Either way, the offline change is now resolved — sync local
            # fields from the server's authoritative post-push state.
            # "applied" does NOT guarantee the local value already matches
            # the server: if another kiosk pushed a change to this row
            # between this device's last pull and this push, the server's
            # pre-push base differed from what this device assumed, so the
            # resulting quantity can differ from a naive local calculation.
            if current:
                if entity_type == "item":
                    local_row.quantity = current["quantity"]
                elif entity_type == "tool":
                    local_row.status = current["status"]
                    local_row.checked_out_by_name = current.get("checked_out_by")
                local_row.updated_at = _parse_dt(current.get("updated_at")) or local_row.updated_at
            if entity_type == "item":
                local_row.pending_delta = 0
            local_row.dirty = False
            if status == "conflict":
                self._log("push", entity_type, "conflict",
                           f"server_id={result.get('server_id')} — {result.get('message', 'resolved: server value kept')}")
        else:
            # not_found / error — clear dirty to avoid an infinite retry
            # loop on a row that can never succeed; the failure is logged
            # for a human to look at.
            if entity_type == "item":
                local_row.pending_delta = 0
            local_row.dirty = False
            self._log("push", entity_type, "error",
                       f"server_id={result.get('server_id')} — {result.get('message', status)}")
