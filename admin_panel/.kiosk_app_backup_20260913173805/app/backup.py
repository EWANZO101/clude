"""Local backup creation for this kiosk's own sqlite database — used two
ways:

1. A background thread (see run.py) checks periodically whether today's
   scheduled local backup is due (per AGENT_CONFIG's backup_time/
   backup_timezone/backup_local_daily_enabled — pushed down the exact same
   applied-config channel as auto_logout_minutes) and, if so, calls
   create_backup_file() directly in-process. Entirely local — no Agent,
   no Admin Panel, no network involved at all for this half.
2. app/blueprints/sync_api.py's loopback /api/backup endpoint, which only
   the Instance Agent ever calls (see that module's own trust-model
   docstring), for the "also send to the cloud" half — the Agent asks for
   a fresh backup, gets the file back, and uploads it to the Admin Panel.
   That upload is what leaves a copy in the local backups/ folder too, as
   a side effect of always going through create_backup_file() below.

Deliberately no new database table for any of this (not even to remember
"when did we last back up") — this app's whole schema evolution story
(see run.py's _ensure_sync_columns) already has enough moving parts, and
"was there already a file created today" is answerable just by looking at
what's actually in the backups/ folder, so that's what
_local_backup_already_done_today does instead.
"""
import os
import sqlite3
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from flask import current_app

from app.config import BASEDIR

DEFAULT_LOCAL_KEEP = 14  # ~2 weeks of daily backups — no policy was specified for local-only ones


def default_backup_dir() -> str:
    return os.path.join(BASEDIR, "..", "backups")


def _sqlite_path_from_uri(uri: str) -> str:
    prefix = "sqlite:///"
    if not uri.startswith(prefix):
        raise ValueError(f"backups are only supported for a sqlite DATABASE_URL, got: {uri!r}")
    return uri[len(prefix):]


def _restrict_to_owner(path: str, *, is_dir: bool) -> None:
    """POPIA Condition 7 (security safeguards): a backup file is a full
    copy of every LocalUser/ActivityEvent/IssuanceEvent/etc. row, so it
    deserves at least the same access restriction as the live sqlite file
    itself, not whatever the process' default umask happens to leave it
    at. os.chmod is a no-op on Windows beyond the read-only bit, but this
    process's actual deployments (loopback kiosk, LAN client portal) run
    on Linux, so this is a real restriction there and harmless elsewhere."""
    try:
        os.chmod(path, 0o700 if is_dir else 0o600)
    except OSError:
        pass  # best-effort — never let a permissions quirk break a backup


def create_backup_file(dest_dir: str = None) -> str:
    """Snapshots the live database using SQLite's own online backup API
    (Connection.backup()) rather than a plain file copy — that produces a
    consistent snapshot even while the app is actively writing to it,
    where a raw file copy could grab a half-written page mid-transaction
    and silently produce a corrupt backup. Returns the new file's path."""
    dest_dir = dest_dir or default_backup_dir()
    os.makedirs(dest_dir, exist_ok=True)
    _restrict_to_owner(dest_dir, is_dir=True)

    src_path = _sqlite_path_from_uri(current_app.config["SQLALCHEMY_DATABASE_URI"])
    timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    dest_path = os.path.join(dest_dir, f"backup-{timestamp}.db")
    # Two backups within the same second (a real possibility — "Back up
    # now" clicked twice quickly, or a test loop) would otherwise collide
    # on this filename and the second create_backup_file() would silently
    # overwrite the first's file out from under it instead of producing a
    # second, distinct backup.
    if os.path.exists(dest_path):
        import secrets
        dest_path = os.path.join(dest_dir, f"backup-{timestamp}-{secrets.token_hex(3)}.db")

    src_conn = sqlite3.connect(src_path)
    dest_conn = sqlite3.connect(dest_path)
    try:
        src_conn.backup(dest_conn)
    finally:
        dest_conn.close()
        src_conn.close()
    _restrict_to_owner(dest_path, is_dir=False)
    return dest_path


def prune_local_backups(dest_dir: str = None, keep: int = DEFAULT_LOCAL_KEEP):
    dest_dir = dest_dir or default_backup_dir()
    if not os.path.isdir(dest_dir):
        return
    files = sorted(
        (os.path.join(dest_dir, f) for f in os.listdir(dest_dir) if f.startswith("backup-") and f.endswith(".db")),
        key=os.path.getmtime, reverse=True,
    )
    for old in files[keep:]:
        try:
            os.remove(old)
        except OSError:
            pass


def _local_backup_already_done_today(dest_dir: str, tz: ZoneInfo) -> bool:
    if not os.path.isdir(dest_dir):
        return False
    today_local = datetime.now(tz).date()
    for f in os.listdir(dest_dir):
        if not (f.startswith("backup-") and f.endswith(".db")):
            continue
        mtime = os.path.getmtime(os.path.join(dest_dir, f))
        if datetime.fromtimestamp(mtime, tz).date() == today_local:
            return True
    return False


def run_scheduled_local_backup_if_due(config: dict) -> bool:
    """Called periodically by the background thread in run.py. `config` is
    AGENT_CONFIG (or an equivalently-shaped dict) — reads backup_time
    ("HH:MM"), backup_timezone (an IANA name), backup_local_daily_enabled.
    Returns True if a backup was actually created this call."""
    if not config.get("backup_local_daily_enabled"):
        return False
    time_str = (config.get("backup_time") or "").strip()
    tz_name = (config.get("backup_timezone") or "").strip()
    if not time_str or not tz_name:
        return False

    try:
        hour, minute = (int(p) for p in time_str.split(":", 1))
    except ValueError:
        return False
    try:
        tz = ZoneInfo(tz_name)
    except (ZoneInfoNotFoundError, ValueError):
        return False

    now_local = datetime.now(tz)
    scheduled_today = now_local.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if now_local < scheduled_today:
        return False

    dest_dir = default_backup_dir()
    if _local_backup_already_done_today(dest_dir, tz):
        return False

    create_backup_file(dest_dir)
    prune_local_backups(dest_dir)
    return True
