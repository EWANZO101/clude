"""
StockTool Kiosk <-> stocktoolsetup.opslabsystems.cloud pairing.

This is the ONLY thing added to let the kiosk talk to the new setup/
backup website. Everything here is an OUTBOUND HTTPS call the kiosk
makes to the cloud -- nothing new is opened for inbound traffic, so
this doesn't change the kiosk's local-only bind-mode security model
(see app/settings.py) at all.

Flow, run by `StockToolKiosk.exe --cloud-setup` (invoked automatically
right after MSI install -- see installer/CloudSetupLaunch.ps1):

  1. Generate a short setup token.
  2. POST it to {setup_api_base}/api/kiosk/register.
  3. Open the user's browser to {setup_api_base}/?token=...
  4. Poll {setup_api_base}/api/kiosk/poll?token=... until the user has
     finished the form on that site (admin username/password + this
     kiosk's installation token).
  5. Create the local admin user via the same code path as
     `--create-user` (main.run_create_user), save the installation
     token to settings.json, and POST /api/kiosk/ack.

From then on, backup_loop.py uses the saved installation token to push
periodic DB backups -- this module isn't involved in that part.
"""
import json
import logging
import secrets
import socket
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from datetime import datetime, timezone

log = logging.getLogger("cloud_setup")

_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I -- may be hand-typed
_POLL_INTERVAL_SECONDS = 4
_POLL_TIMEOUT_SECONDS = 20 * 60  # give the user 20 minutes to fill the form in


def _generate_token() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(8))


def _post_json(url: str, payload: dict, timeout: int = 10) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _get_json(url: str, timeout: int = 10) -> dict:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def run_cloud_setup(role: str = "admin") -> int:
    """Returns a process exit code (0 = success)."""
    from app import _local_data_dir
    from app.settings import load_settings, save_settings
    from main import run_create_user_inprocess  # see main.py

    data_dir = _local_data_dir()
    settings = load_settings(data_dir)
    base = settings.get("setup_api_base", "https://stocktoolsetup.opslabsystems.cloud").rstrip("/")

    if settings.get("setup_installation_token"):
        print("This kiosk is already paired with StockTool Setup. Run --unpair first "
              "if you really want to replace the pairing.", file=sys.stderr)
        return 1

    token = _generate_token()
    hostname = socket.gethostname()

    try:
        _post_json(f"{base}/api/kiosk/register", {
            "token": token, "hostname": hostname, "kiosk_version": _kiosk_version(),
        })
    except (urllib.error.URLError, OSError) as exc:
        log.error("Could not register with %s: %s", base, exc)
        print(f"ERROR: couldn't reach {base} to start setup: {exc}", file=sys.stderr)
        return 1

    setup_url = f"{base}/?token={token}"
    print(f"Opening {setup_url}")
    print(f"If that doesn't open automatically, go there yourself and enter this code: {token}")
    try:
        webbrowser.open(setup_url)
    except Exception:
        pass

    print("Waiting for setup to be completed in the browser...")
    deadline = time.time() + _POLL_TIMEOUT_SECONDS
    result = None
    while time.time() < deadline:
        try:
            result = _get_json(f"{base}/api/kiosk/poll?token={token}")
        except (urllib.error.URLError, OSError) as exc:
            log.warning("Poll failed, retrying: %s", exc)
            time.sleep(_POLL_INTERVAL_SECONDS)
            continue

        status = result.get("status")
        if status == "completed":
            break
        if status == "expired":
            print("Setup code expired before the form was completed. Run "
                  "'StockTool Kiosk Setup' again to get a new one.")
            return 1
        if status in ("already_delivered",):
            print("That setup code was already used.")
            return 1
        time.sleep(_POLL_INTERVAL_SECONDS)
    else:
        print("Timed out waiting for setup to be completed in the browser. Run "
              "'StockTool Kiosk Setup' again when you're ready.")
        return 1

    username = result.get("username")
    badge_code = result.get("badge_code")
    installation_id = result.get("installation_id")
    installation_token = result.get("installation_token")

    if not (username or badge_code) or not installation_token:
        log.error("Incomplete pairing response: %r", {k: v for k, v in result.items() if k != "installation_token"})
        print("ERROR: setup site returned an incomplete response. Please try again.")
        return 1

    # Create the local admin account exactly the way --create-user does
    # (same ORM code path, so this can never drift out of sync with
    # models.py) -- run in-process rather than shelling out to itself.
    assigned_badge = run_create_user_inprocess(username=username, badge_code=badge_code, role=result.get("role", role))
    if not assigned_badge:
        print("ERROR: could not create the local admin account. Check the log for details.", file=sys.stderr)
        return 1

    settings["setup_installation_id"] = installation_id
    settings["setup_installation_token"] = installation_token
    settings["setup_paired_at"] = datetime.now(timezone.utc).isoformat()
    save_settings(data_dir, settings)

    try:
        _post_json(f"{base}/api/kiosk/ack", {"token": token})
    except (urllib.error.URLError, OSError) as exc:
        # Non-fatal: the kiosk already has everything it needs locally.
        # The server-side plaintext token just lingers until it expires
        # naturally instead of being cleared immediately.
        log.warning("Ack failed (non-fatal): %s", exc)

    print(f"Paired with StockTool Setup. Admin account '{username}' is ready, and this kiosk "
          f"will now back its database up to {base} automatically.")
    print()
    print("=" * 60)
    print(f"  BADGE CODE (scan or type this to log in): {assigned_badge}")
    print("  There is no password -- this is the only way to log in.")
    print("=" * 60)
    print()
    try:
        input("Press Enter to close this window...")
    except (EOFError, OSError):
        pass  # no stdin attached for some reason -- don't hang forever
    return 0


def _kiosk_version() -> str:
    try:
        from version import __version__
        return __version__
    except Exception:
        return "unknown"

