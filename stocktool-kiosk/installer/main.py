"""
StockTool Kiosk (v2) — entry point.

This is what PyInstaller bundles into StockToolKiosk.exe. Three ways it
gets run:

  1. Interactive (double-clicked, or the "StockTool Kiosk" Start Menu
     shortcut the MSI installs): waits for the server, opens the UI in
     the default browser, blocks in a console loop. Closing this window
     stops the server. This is the kiosk-terminal experience.

  2. `--service` (how the MSI-registered "StockToolKioskAPI" Windows
     service invokes it, via NSSM — see installer/SetupWizard.ps1):
     headless. No browser, no console — logs to a rotating file under
     the data dir instead, since a Windows service has no console to
     print to. This is what keeps the admin API up permanently, at
     whatever bind mode Setup Wizard configured (local/tunnel/public —
     see app/settings.py), independent of anyone being logged into a
     kiosk terminal at all.

  3. `--create-user --username X [--badge-code Y] [--role admin]`:
     creates (or updates, if the username/badge already exists) a
     LocalUser row directly in the local SQLite DB, then exits. This is
     what the Setup Wizard calls so the admin account can be created as
     part of MSI setup. (There's also a browser-based admin panel for
     day-to-day user management once the kiosk is running -- see
     app/routes_admin.py -- this CLI path is specifically for the very
     first account, before anyone could have logged in to use it.)
     Idempotent on purpose, so re-running the Setup Wizard later to
     change exposure mode doesn't fail or create duplicate accounts.

  4. `--provision --installation-token X --username Y [--badge-code Z]`:
     fully non-interactive pairing with stocktoolsetup.opslabsystems.cloud,
     for a machine whose admin details were already decided on the
     website BEFORE this exe ever ran (see stocktoolsetup's /provision
     route, which builds a personalized MSI with these values baked in
     as WiX properties). Unlike `--cloud-setup` below, this never opens
     a browser or polls anything -- everything needed is already known.
     See installer/Product.wxs's SilentProvision custom action for how
     this gets invoked automatically during install.

  5. `--cloud-setup`: the original (still supported) interactive
     pairing path for a generic, non-personalized install -- generates
     its own token, opens a browser to stocktoolsetup.opslabsystems.cloud,
     and polls until someone fills in the form there. See
     app/cloud_setup.py.

  6. `--unpair`: clears the setup_installation_token/setup_paired_at
     fields from settings.json so a machine already paired with
     StockTool Setup can be paired again (e.g. for testing, or moving
     a kiosk to a different account). Does NOT delete the local user(s)
     or any inventory data -- only the cloud-pairing link.

First run creates its local SQLite DB and settings.json under
%LOCALAPPDATA%\\StockToolKiosk\\ automatically (or ProgramData, when run
as a service with no per-user profile — see app/__init__.py).
"""
import sys
import os
import time
import logging
import argparse
import threading
import webbrowser
import urllib.request
from datetime import datetime, timezone

from server_supervisor import Supervisor


def _wait_for_server(base_url: str, timeout_seconds=15) -> bool:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{base_url}/api/status", timeout=1) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(0.3)
    return False


def _current_port() -> int:
    """Read the configured port without fully booting the app, so both
    startup modes can build BASE_URL before the server thread is even
    up."""
    from app import _local_data_dir
    from app.settings import load_settings
    return load_settings(_local_data_dir()).get("port", 8420)


def run_interactive():
    """Opens the kiosk UI in a browser and keeps a console window open so
    staff can see the kiosk is up and have something to close.

    IMPORTANT: after a normal MSI install, the "StockToolKioskAPI"
    Windows service (see installer/SetupWizard.ps1's Register-ApiService)
    is already running and bound to this same port, independent of
    whether anyone is logged in. So this checks for that FIRST, rather
    than unconditionally starting a second embedded server:

      - Service already answering -> just open the browser against it.
        Nothing here owns that server, so closing this window (or
        Ctrl+C) does NOT stop the API -- it keeps running in the
        background as designed. Use the "Stop StockTool Kiosk" Start
        Menu shortcut for that.
      - Nothing answering yet (service not installed -- e.g. running
        the raw .exe without the MSI/installer, a dev/portable
        workflow) -> fall back to running our own embedded server in
        this process, same as before. In that fallback case, closing
        this window DOES stop the server, since this process is the
        only thing running it.

    Previously this always did the latter unconditionally, which meant
    the normal post-install case (service already up) tried to bind a
    port that was already in use. That failed every time, and after the
    15s wait here plus the Supervisor's own internal 10-attempt retry
    loop gave up, this printed an error and exited -- the window would
    vanish shortly after opening instead of staying up.
    """
    port = _current_port()
    base_url = f"http://127.0.0.1:{port}"

    already_running = _wait_for_server(base_url, timeout_seconds=2)

    if already_running:
        print(f"StockTool Kiosk API is already running as a service at {base_url}/ui/")
        webbrowser.open(f"{base_url}/ui/")
        print("Opening it in your browser.")
        print("This window does not control that background service.")
        print("Use 'Stop StockTool Kiosk' / 'Start StockTool Kiosk' in the")
        print("Start Menu to stop or restart it. Closing this window is safe")
        print("and will not affect the running kiosk.")
    else:
        print("No StockTool Kiosk service detected -- starting an embedded server for this session.")
        supervisor = Supervisor()
        server_thread = threading.Thread(target=supervisor.run_forever, daemon=True)
        server_thread.start()

        if not _wait_for_server(base_url):
            print("ERROR: embedded server did not start in time.", file=sys.stderr)
            print("Check that nothing else is using port %d, then try again." % port, file=sys.stderr)
            sys.exit(1)

        webbrowser.open(f"{base_url}/ui/")
        print(f"StockTool Kiosk is running at {base_url}/ui/")
        print("Close this window to stop the kiosk server.")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("Shutting down.")


def run_service():
    """Headless entry point for the Windows service. No stdout — NSSM
    redirects it nowhere useful, and printing to a nonexistent console
    can itself raise under some service hosts — so this logs to a file
    instead."""
    from app import _local_data_dir

    log_path = f"{_local_data_dir()}\\service.log" if sys.platform == "win32" else "./service.log"
    logging.basicConfig(
        filename=log_path,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    logging.getLogger("main").info("StockTool Kiosk API service starting.")

    supervisor = Supervisor()
    supervisor.run_forever()  # blocks; NSSM manages the process lifetime


def run_create_user_inprocess(username: str | None, badge_code: str | None, role: str) -> str | None:
    """Creates or updates a LocalUser directly via the ORM (not hand-
    written SQL, so this can never drift out of sync with models.py).
    Returns the user's final badge_code on success, or None on failure
    -- instead of just True/False, so callers (app/cloud_setup.py, mid-
    way through its own pairing flow) can show the person the actual
    login credential, not just whether it worked. Unlike the
    `--create-user` CLI mode below (a one-shot process expected to
    exit), this doesn't exit the process itself.

    Always ensures the resulting user has a badge_code, generating one
    if none was given -- badge_code is the ONLY login credential now
    (see app/routes_auth.py), so leaving it blank would create a user
    who can never actually log in.

    Retries a few times on a transient "database is locked" error rather
    than failing outright on what's usually just brief contention: this
    may run on a first install (nothing else touching the DB yet) or a
    later re-run (the StockToolKioskAPI Windows service is likely already
    running and holding this same DB file open)."""
    import time as _time
    from sqlalchemy.exc import OperationalError
    from app import create_app
    from app.models import db, LocalUser
    from app.codes import unique_badge_code

    if not username and not badge_code:
        print("ERROR: --username or --badge-code is required.", file=sys.stderr)
        return None

    app = create_app()
    with app.app_context():
        attempts = 5
        for attempt in range(1, attempts + 1):
            try:
                existing = None
                if username:
                    existing = LocalUser.query.filter_by(username=username).first()
                if not existing and badge_code:
                    existing = LocalUser.query.filter_by(badge_code=badge_code).first()

                if existing:
                    # Idempotent update rather than an error, so re-running
                    # the Setup Wizard (e.g. just to switch exposure mode)
                    # never fails or creates a duplicate account.
                    if badge_code:
                        existing.badge_code = badge_code
                    elif not existing.badge_code:
                        existing.badge_code = unique_badge_code()
                    existing.role = role
                    existing.is_active = True
                    db.session.commit()
                    print(f"Updated existing user '{existing.username}' (badge_code={existing.badge_code}, role={role}).")
                    return existing.badge_code
                else:
                    final_badge_code = badge_code or unique_badge_code()
                    user = LocalUser(
                        username=username or final_badge_code,
                        badge_code=final_badge_code,
                        role=role,
                        is_active=True,
                    )
                    db.session.add(user)
                    db.session.commit()
                    print(f"Created user '{user.username}' (badge_code={final_badge_code}, role={role}).")
                    return final_badge_code
            except OperationalError as exc:
                db.session.rollback()
                if "locked" not in str(exc).lower() or attempt == attempts:
                    print(f"ERROR: database error creating user: {exc}", file=sys.stderr)
                    return None
                _time.sleep(0.5 * attempt)  # brief backoff, then retry

    return None


def run_create_user(username: str | None, badge_code: str | None, role: str) -> None:
    """CLI wrapper around run_create_user_inprocess for `--create-user`
    — still called directly by installer/SetupWizard.ps1's local (non-
    cloud) account-management step. Exits the process, unlike the
    in-process helper above."""
    result = run_create_user_inprocess(username, badge_code, role)
    sys.exit(0 if result is not None else 1)


def run_cloud_setup() -> None:
    """`--cloud-setup`: pair with stocktoolsetup.opslabsystems.cloud —
    see app/cloud_setup.py for the actual token/poll/pairing logic.
    Launched automatically right after MSI install (see
    installer/CloudSetupLaunch.ps1), or manually from the "StockTool
    Kiosk Setup" Start Menu shortcut."""
    from app.cloud_setup import run_cloud_setup as _run
    sys.exit(_run())


def run_provision(installation_token: str | None, username: str | None,
                   badge_code: str | None, role: str) -> None:
    """`--provision`: fully non-interactive pairing for a machine whose
    admin account details were already decided BEFORE this exe ever
    ran (see stocktoolsetup's /provision route, which bakes these
    values into a personalized MSI as WiX properties, and
    installer/Product.wxs's SilentProvision custom action, which is
    what actually invokes this during install).

    Unlike --cloud-setup, this never generates its own token, opens a
    browser, or polls anything -- it writes the exact same settings.json
    fields --cloud-setup would have ended up with after its whole round
    trip, and creates the local user, directly, in one shot."""
    from app import _local_data_dir
    from app.settings import load_settings, save_settings

    if not installation_token or not username:
        print("ERROR: --provision requires --installation-token and --username.", file=sys.stderr)
        sys.exit(1)

    data_dir = _local_data_dir()
    settings = load_settings(data_dir)
    if settings.get("setup_installation_token"):
        print("ERROR: this kiosk is already paired with StockTool Setup. "
              "Run --unpair first if you really want to replace the pairing.", file=sys.stderr)
        sys.exit(1)

    settings["setup_installation_token"] = installation_token
    settings["setup_paired_at"] = datetime.now(timezone.utc).isoformat()
    save_settings(data_dir, settings)

    badge = run_create_user_inprocess(username=username, badge_code=badge_code, role=role)
    if not badge:
        print("ERROR: could not create the local admin account during provisioning "
              "(pairing was still saved -- re-run --create-user manually to fix the account).",
              file=sys.stderr)
        sys.exit(1)

    print(f"Provisioned. Admin '{username}' badge code: {badge}")
    sys.exit(0)


def run_unpair() -> None:
    """`--unpair`: clears the cloud-pairing fields from settings.json
    so this machine can be paired again (via --cloud-setup, --pair, or
    --provision). Does NOT touch local users or inventory data -- only
    the link to stocktoolsetup.opslabsystems.cloud. Mainly useful for
    testing, or genuinely moving a kiosk to a different account."""
    from app import _local_data_dir
    from app.settings import load_settings, save_settings

    data_dir = _local_data_dir()
    settings = load_settings(data_dir)
    if not settings.get("setup_installation_token"):
        print("This kiosk isn't currently paired -- nothing to do.")
        sys.exit(0)

    settings["setup_installation_token"] = None
    settings["setup_paired_at"] = None
    save_settings(data_dir, settings)
    print("Unpaired. Local users and inventory data were left untouched. "
          "Run --cloud-setup, --pair, or --provision to pair again.")
    sys.exit(0)


def _claim(code: str) -> bool:
    """Exchanges a short code (obtained by filling in the form at
    stocktoolsetup.opslabsystems.cloud BEFORE installing) for this
    kiosk's pairing details, in one request. Reuses the exact same
    /api/kiosk/poll endpoint --cloud-setup already polls in a loop --
    except the SetupSession behind this code is already in "completed"
    status by the time this runs (the admin filled in the form first,
    before this kiosk ever asked), so this only ever needs to call it
    once, not loop. Returns True/False rather than exiting, since the
    caller (run_pair) still needs to register the service afterward."""
    import json
    import urllib.error
    from app import _local_data_dir
    from app.settings import load_settings, save_settings

    data_dir = _local_data_dir()
    settings = load_settings(data_dir)
    if settings.get("setup_installation_token"):
        print("ERROR: this kiosk is already paired with StockTool Setup. "
              "Run --unpair first if you really want to replace the pairing.", file=sys.stderr)
        return False

    base = settings.get("setup_api_base", "https://stocktoolsetup.opslabsystems.cloud").rstrip("/")
    token = code.strip().upper()

    req = urllib.request.Request(f"{base}/api/kiosk/poll?token={token}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print(f"ERROR: could not reach StockTool Setup: {exc}", file=sys.stderr)
        return False

    status = data.get("status")
    if status != "completed":
        print(f"ERROR: that code isn't ready (status: {status}). Double-check you typed it "
              "correctly, or that you finished the form on the website.", file=sys.stderr)
        return False

    username = data.get("username")
    badge_code = data.get("badge_code")
    role = data.get("role") or "admin"
    installation_token = data.get("installation_token")
    if not username or not installation_token:
        print("ERROR: StockTool Setup returned an incomplete response.", file=sys.stderr)
        return False

    settings["setup_installation_token"] = installation_token
    settings["setup_paired_at"] = datetime.now(timezone.utc).isoformat()
    save_settings(data_dir, settings)

    assigned_badge = run_create_user_inprocess(username=username, badge_code=badge_code, role=role)
    if not assigned_badge:
        print("ERROR: could not create the local admin account (pairing was still saved -- "
              "re-run --create-user manually to fix the account).", file=sys.stderr)
        return False

    try:
        ack_req = urllib.request.Request(
            f"{base}/api/kiosk/ack",
            data=json.dumps({"token": token}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(ack_req, timeout=15)
    except (urllib.error.URLError, OSError):
        pass  # non-fatal -- same as app/cloud_setup.py's own ack handling

    print(f"Paired with StockTool Setup. Admin account '{username}' is ready.")
    print()
    print("=" * 60)
    print(f"  BADGE CODE (scan or type this to log in): {assigned_badge}")
    print("  There is no password -- this is the only way to log in.")
    print("=" * 60)
    print()
    return True


def _register_service_silently() -> None:
    """Calls SetupWizard.ps1 -Silent to register/start the Windows
    service in local bind mode, right after a successful pairing --
    nothing else does this automatically (see SetupWizard.ps1's own
    notes on why service registration is normally a separate manual
    step). Best-effort: warns but doesn't fail the overall pairing flow
    if this specific step has a problem, since pairing itself already
    succeeded and is the more important part not to lose -- "StockTool
    Kiosk Setup" in the Start Menu is always available to retry just
    this step by itself."""
    import subprocess

    if not getattr(sys, "frozen", False):
        return  # dev/non-frozen run -- no installed SetupWizard.ps1 alongside this file to call

    install_dir = os.path.dirname(sys.executable)
    setup_wizard = os.path.join(install_dir, "SetupWizard.ps1")
    if not os.path.isfile(setup_wizard):
        print(f"WARNING: could not find {setup_wizard} -- skipping automatic service registration. "
              "Run 'StockTool Kiosk Setup' from the Start Menu manually.", file=sys.stderr)
        return

    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", setup_wizard, "-Silent"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            print(f"WARNING: service registration failed: {result.stdout} {result.stderr}", file=sys.stderr)
            print("Run 'StockTool Kiosk Setup' from the Start Menu manually to fix this.", file=sys.stderr)
        else:
            print("Service registered and started.")
    except Exception as exc:
        print(f"WARNING: could not run SetupWizard.ps1 -Silent: {exc}", file=sys.stderr)
        print("Run 'StockTool Kiosk Setup' from the Start Menu manually to fix this.", file=sys.stderr)


def run_pair() -> None:
    """`--pair`: the primary post-install pairing flow (see
    installer/Product.wxs's LaunchCloudSetup, which runs this
    automatically right after a fresh install). Prompts for a short
    setup code -- get one by filling in account details at
    stocktoolsetup.opslabsystems.cloud BEFORE downloading (that's the
    primary flow now: fill in details there first, get a code, download,
    install, type the code once, done). Leaving it blank falls back to
    the original --cloud-setup flow (generates its own code, opens a
    browser, waits there) for anyone who installed without visiting the
    site first. Either way, on success this also registers/starts the
    Windows service, since nothing else does that automatically.

    Refuses outright, before even prompting, if this kiosk is already
    paired -- checked here up front rather than only after the person
    types a code, so re-running this on an already-paired machine (e.g.
    "StockTool Kiosk Setup" re-run by habit) fails immediately and
    clearly instead of wasting their time on a prompt that was always
    going to be rejected."""
    from app import _local_data_dir
    from app.settings import load_settings

    data_dir = _local_data_dir()
    settings = load_settings(data_dir)
    if settings.get("setup_installation_token"):
        print("This kiosk is already paired with StockTool Setup.", file=sys.stderr)
        print("Run 'StockToolKiosk.exe --unpair' first if you really want to re-pair it.", file=sys.stderr)
        sys.exit(1)

    try:
        code = input(
            "Enter your StockTool Setup code (from stocktoolsetup.opslabsystems.cloud), "
            "or press Enter to pair a different way in your browser instead: "
        ).strip()
    except (EOFError, OSError):
        code = ""

    if code:
        ok = _claim(code)
    else:
        from app.cloud_setup import run_cloud_setup as _run_cloud_setup
        ok = (_run_cloud_setup() == 0)

    if not ok:
        sys.exit(1)

    _register_service_silently()

    # Open the actual kiosk UI now, so the person sees a working app
    # immediately instead of having to separately find and click the
    # "StockTool Kiosk" Start Menu shortcut after setup finishes. Waits
    # for the service to actually be answering requests first (NSSM
    # reporting the service as "started" doesn't guarantee the app
    # inside has finished booting yet) rather than opening a browser tab
    # that just shows a connection error for a second or two.
    port = _current_port()
    base_url = f"http://127.0.0.1:{port}"
    if _wait_for_server(base_url, timeout_seconds=20):
        webbrowser.open(f"{base_url}/ui/")
        print(f"Opened {base_url}/ui/ in your browser.")
    else:
        print(f"WARNING: the service didn't come up within 20s -- open {base_url}/ui/ "
              "manually once it does, or check service.log.", file=sys.stderr)

    sys.exit(0)


def _boot_check(deadline) -> bool:
    """Boot verification for confirm_or_rollback(), called after a
    self-update swap: creates the app and touches the DB, WITHOUT binding
    a port. Binding would fight the already-running old build for the
    same port during the brief window before the old process has fully
    exited, producing a false failure. Loading the app + a live query is
    still a real test that the new .exe isn't corrupted and its bundled
    code actually imports and runs — the two failure modes an update can
    realistically have."""
    try:
        from app import create_app
        from app.models import db
        app = create_app()
        with app.app_context():
            db.session.execute(db.text("SELECT 1"))
        return True
    except Exception:
        logging.getLogger("main").exception("Post-update boot check failed")
        return False


def main():
    # Must run before anything else: if this process is the result of a
    # self-update (see updater.apply_update), this verifies the new build
    # actually works and rolls back to the previous .exe if it doesn't.
    # A completely normal startup (no pending update) returns immediately.
    from updater import confirm_or_rollback
    confirm_or_rollback(_boot_check)

    parser = argparse.ArgumentParser(description="StockTool Kiosk")
    parser.add_argument(
        "--service", action="store_true",
        help="Run headless (no browser/console) — used by the installed Windows service.",
    )
    parser.add_argument(
        "--create-user", action="store_true",
        help="Create/update a local user, then exit — used by the Setup Wizard.",
    )
    parser.add_argument(
        "--cloud-setup", action="store_true",
        help="Pair with stocktoolsetup.opslabsystems.cloud (admin account + backups), then exit.",
    )
    parser.add_argument(
        "--provision", action="store_true",
        help="Silently pair using details already decided on the website (no browser/polling), then exit.",
    )
    parser.add_argument(
        "--unpair", action="store_true",
        help="Clear this kiosk's cloud pairing so it can be paired again, then exit.",
    )
    parser.add_argument(
        "--pair", action="store_true",
        help="Pair with StockTool Setup: prompts for a short code (or falls back to the browser flow), then exits.",
    )
    parser.add_argument("--installation-token", default=None)
    parser.add_argument("--username", default=None)
    parser.add_argument("--badge-code", default=None)
    parser.add_argument("--role", default="admin")
    args = parser.parse_args()

    if args.create_user:
        run_create_user(args.username, args.badge_code, args.role)
    elif args.cloud_setup:
        run_cloud_setup()
    elif args.provision:
        run_provision(args.installation_token, args.username, args.badge_code, args.role)
    elif args.pair:
        run_pair()
    elif args.unpair:
        run_unpair()
    elif args.service:
        run_service()
    else:
        run_interactive()


if __name__ == "__main__":
    main()