"""Handles the 'backup_now' InstanceCommand (see the Admin Panel's
app/blueprints/agent_api.py::get_pending_command, which auto-queues one
when a schedule comes due, and app/blueprints/client_portal.py's
backup_now route, which queues one on demand) — this Agent is the only
thing with a network path to both: outbound HTTPS to the Admin Panel
(same as every other call here), and outbound HTTP to the Kiosk App over
loopback, since it's running on this exact machine (see
kiosk_app/run.py — bound to 127.0.0.1 only). Same shape as
inventory_sync.py for exactly that reason.

Reuses kiosk_inventory_sync_url as "the Kiosk App's own base URL" rather
than adding a second, separate URL setting for the exact same value —
that field's name is a historical accident of when it was introduced,
its actual meaning has always been "where the Kiosk App is", not
anything inventory-specific.
"""
import logging

import requests

from agent.api_client import ApiClient, ApiError

log = logging.getLogger("agent.backup_sync")

KIOSK_REQUEST_TIMEOUT_SECONDS = 60  # a real backup file, not a small JSON call


def run_backup_now(client: ApiClient, kiosk_base_url: str, source: str = "scheduled") -> tuple:
    """Returns (ok, message) — same shape agent/commands.py's other
    command handlers use, so check_and_execute can ack it directly.
    `source` ('scheduled' or 'manual') just travels through to the
    Admin Panel's upload endpoint for display — see InstanceBackup.source."""
    base_url = (kiosk_base_url or "").rstrip("/")
    if not base_url:
        return False, (
            "No Kiosk App base URL configured for this instance — nothing to back up. Set one under "
            "Kiosk & Updates -> Configure what starts the kiosk process (the field currently labeled "
            "'Kiosk App base URL' — despite the field's own name, kiosk_inventory_sync_url, this is "
            "required for Backups and Database reset too, not just inventory sync)."
        )

    try:
        resp = requests.post(f"{base_url}/api/sync/backup", timeout=KIOSK_REQUEST_TIMEOUT_SECONDS)
    except requests.RequestException as e:
        return False, f"Couldn't reach the Kiosk App to create a backup: {e}"

    if resp.status_code >= 400:
        return False, f"Kiosk App refused to create a backup (HTTP {resp.status_code}): {resp.text[:300]}"

    content_disposition = resp.headers.get("Content-Disposition", "")
    filename = "backup.db"
    if "filename=" in content_disposition:
        filename = content_disposition.split("filename=", 1)[1].strip('"')

    try:
        client.upload_backup(filename, resp.content, source)
    except ApiError as e:
        return False, f"Backup created locally but upload to the Admin Panel failed: {e}"

    return True, f"Backup created ({len(resp.content)} bytes) and uploaded as {filename}."


def run_db_reset(client: ApiClient, kiosk_base_url: str) -> tuple:
    """Handles the 'db_reset' InstanceCommand — a much more destructive
    sibling of run_backup_now above (see the Admin Panel's
    app/blueprints/instances.py::kiosk_reset_db, which queues it). Always
    takes a real backup FIRST, via the exact same path as a manual
    'backup_now' (source='pre_reset' just distinguishes it in the
    instance's backup history), so the wipe below is only ever attempted
    once there is already a restorable copy sitting in the Admin Panel.
    If that backup fails for any reason, the wipe is never attempted at
    all. Returns (ok, message), same shape as run_backup_now."""
    backup_ok, backup_message = run_backup_now(client, kiosk_base_url, source="pre_reset")
    if not backup_ok:
        return False, f"Aborted — safety backup before reset failed: {backup_message}"

    base_url = (kiosk_base_url or "").rstrip("/")
    try:
        resp = requests.post(f"{base_url}/api/sync/reset", timeout=KIOSK_REQUEST_TIMEOUT_SECONDS)
    except requests.RequestException as e:
        return False, f"Safety backup succeeded ({backup_message}) but the reset itself failed to reach the Kiosk App: {e}"

    if resp.status_code >= 400:
        return False, (
            f"Safety backup succeeded ({backup_message}) but the Kiosk App refused the reset "
            f"(HTTP {resp.status_code}): {resp.text[:300]}"
        )

    return True, f"Database reset. Pre-reset backup preserved ({backup_message})"
