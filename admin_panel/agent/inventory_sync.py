"""Two-way sync between the Admin Panel's Items & Tools / Local Kiosk
Users (app/blueprints/agent_api.py's equipment/local-users sync
endpoints) and the real Kiosk App's own Item/Tool/LocalUser tables
(kiosk_app/app/blueprints/sync_api.py) — this Agent is the only thing
with a network path to both: outbound HTTPS to the Admin Panel (same as
every other poll loop here), and outbound HTTP to the Kiosk App over
loopback, since it's running on this exact machine (see
kiosk_app/run.py — bound to 127.0.0.1 only).

Each pass: fetch both sides' current full state, then POST each side's
list to the OTHER side. Neither this module nor either receiving endpoint
decides "who wins" globally — every individual row is accepted or
rejected independently by whichever side receives it, based on its own
`updated_at` (see both sync_api.py's and agent_api.py's own
last-write-wins comparison). That keeps this loop simple: it doesn't need
to merge anything itself, just move both sides' current state to the
other side and let each side defend its own newer data.

A no-op (not an error) until an admin sets kiosk_inventory_sync_url via
the "Configure what starts the kiosk process" push — same convention as
kiosk_start_command being empty meaning "nothing to supervise yet".
"""
import logging

import requests

from agent.api_client import ApiClient, ApiError
from agent.config import AgentSettings

log = logging.getLogger("agent.inventory_sync")

KIOSK_REQUEST_TIMEOUT_SECONDS = 10


def sync_once(client: ApiClient, settings: AgentSettings) -> bool:
    """One sync pass. Returns True if a sync was attempted, False if
    kiosk_inventory_sync_url isn't configured yet (nothing to do)."""
    base_url = settings.kiosk_inventory_sync_url.rstrip("/") if settings.kiosk_inventory_sync_url else ""
    if not base_url:
        return False

    admin_equipment = client.get_equipment_sync()
    admin_local_users = client.get_local_users_sync()
    # Track 2 Phase B (see /root/.claude/plans/sprightly-meandering-whisper.md)
    # — additive, alongside items/tools/local_users above, not replacing
    # them yet (Phase D is the actual cutover).
    admin_item_types = client.get_item_types_sync()
    admin_inventory_items = client.get_inventory_items_sync()

    kiosk_state = requests.get(f"{base_url}/api/sync/state", timeout=KIOSK_REQUEST_TIMEOUT_SECONDS).json()

    # Admin Panel's current state -> Kiosk App.
    kiosk_apply_resp = requests.post(
        f"{base_url}/api/sync/apply",
        json={
            "items": admin_equipment.get("items", []),
            "tools": admin_equipment.get("tools", []),
            "local_users": admin_local_users.get("local_users", []),
            "item_types": admin_item_types.get("item_types", []),
            "inventory_items": admin_inventory_items.get("inventory_items", []),
        },
        timeout=KIOSK_REQUEST_TIMEOUT_SECONDS,
    )
    kiosk_apply_resp.raise_for_status()

    # Kiosk App's current state -> Admin Panel.
    client.push_equipment_sync(kiosk_state.get("items", []), kiosk_state.get("tools", []))
    client.push_local_users_sync(kiosk_state.get("local_users", []))
    client.push_item_types_sync(kiosk_state.get("item_types", []))
    client.push_inventory_items_sync(kiosk_state.get("inventory_items", []))

    # Roles and the nav/sidebar layout are both read-only caches on the
    # Admin Panel side (edited via the command channel instead — see
    # agent/commands.py's role_*/sidebar_reorder handlers), so these two
    # are one-way: just refresh what's currently on the kiosk.
    roles_resp = requests.get(f"{base_url}/api/sync/roles", timeout=KIOSK_REQUEST_TIMEOUT_SECONDS)
    roles_resp.raise_for_status()
    client.push_roles_sync(roles_resp.json().get("roles", []))

    sidebar_resp = requests.get(f"{base_url}/api/sync/sidebar", timeout=KIOSK_REQUEST_TIMEOUT_SECONDS)
    sidebar_resp.raise_for_status()
    client.push_nav_entries_sync(sidebar_resp.json().get("nav_entries", []))

    log.debug(
        "Inventory sync pass complete (applied %s to kiosk, pushed %s items/%s tools/%s local users/"
        "%s item types/%s inventory items up)",
        kiosk_apply_resp.json().get("applied"),
        len(kiosk_state.get("items", [])), len(kiosk_state.get("tools", [])), len(kiosk_state.get("local_users", [])),
        len(kiosk_state.get("item_types", [])), len(kiosk_state.get("inventory_items", [])),
    )
    return True


def run_inventory_sync_loop(client: ApiClient, settings: AgentSettings, interval_seconds: int, stop_event):
    while not stop_event.is_set():
        try:
            sync_once(client, settings)
        except ApiError as e:
            log.warning("Inventory sync failed talking to the Admin Panel: %s", e)
        except requests.RequestException as e:
            # Most common cause: no Kiosk App actually installed/running at
            # kiosk_inventory_sync_url yet — not worth escalating past a
            # warning, since plenty of instances never install one at all.
            log.warning("Inventory sync failed talking to the Kiosk App: %s", e)
        except Exception:
            log.exception("Unexpected error during inventory sync")
        stop_event.wait(interval_seconds)
