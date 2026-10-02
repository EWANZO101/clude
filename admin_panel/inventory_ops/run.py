"""Entrypoint for inventory-ops — a generic inventory tracker (cables,
parts, whatever an IT/computer business wants to call things), built on the
same ItemType/InventoryItem engine as kiosk_app's generic inventory system,
with no dependency on admin_panel's database/sync/licensing: it keeps its
own local users, its own settings, its own SQLite db.

Two independent ways to run it, both supported:
  - Standalone: its own folder/venv/systemd unit, versioned release zips
    built and swapped in by hand (tools/build_inventory_ops_release.py,
    update.sh, service_files/systemd/opslab-inventory-ops.service).
  - As a real fleet product through admin_panel: a company enrolls a
    machine against an Inventory Ops enrollment token, the Instance Agent
    registers it and supervises this same run.py as its one managed app
    (see app/models.py's Instance.product_id / agent/config.py's
    AgentSettings.product on the admin_panel side) — Linux or Windows,
    the Agent installs on both.

Serves via waitress by default; set INVENTORY_OPS_DEV=1 for Flask's own dev
server with the reloader/debugger, for local development only.
"""
import os
import re
import secrets
import sys


def _ensure_dependencies_installed():
    """Checks every line of this package's own requirements.txt against
    what's actually importable in the current interpreter and `pip
    install`s anything missing, before app/ is ever imported.

    Needed specifically for the Agent-managed deployment path above: the
    Agent's update_manager.py just extracts a release zip's files in place
    (see OWNERSHIP.md) — it never runs pip on this app's behalf, so a fresh
    machine (or a bare bundled Python runtime on Windows, which the Agent's
    own install.ps1 downloads with nothing preinstalled) would otherwise
    fail to even import argon2/Flask-Login on first boot. Same fix, same
    reasoning, as kiosk_app/run.py's own version of this function (real
    incident there, 2026-09-08 — a release added a new import and nothing
    in the update pipeline ever re-ran pip install). The standalone
    deployment path above isn't affected either way (its venv is built by
    hand with `pip install -r requirements.txt` up front), so this is a
    no-op there — one importlib.metadata lookup per requirement, no
    subprocess, unless something is genuinely missing."""
    import importlib.metadata

    req_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "requirements.txt")
    if not os.path.isfile(req_path):
        return

    missing = []
    with open(req_path, "r", encoding="utf-8") as f:
        for line in f:
            requirement = line.split("#", 1)[0].strip()
            if not requirement:
                continue
            dist_name = re.split(r"[<>=!~;\[]", requirement, 1)[0].strip()
            if not dist_name:
                continue
            try:
                importlib.metadata.version(dist_name)
            except importlib.metadata.PackageNotFoundError:
                missing.append(requirement)

    if not missing:
        return

    print(f"[bootstrap] installing missing dependencies: {missing}", flush=True)
    import subprocess
    try:
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", *missing],
            check=True, timeout=300,
        )
        print("[bootstrap] dependency install complete", flush=True)
    except Exception as e:
        print(f"[bootstrap] WARNING: dependency install failed, continuing anyway: {e}", flush=True)


_ensure_dependencies_installed()

from app import create_app
from app.extensions import db

app = create_app()

PORT = int(os.environ.get("INVENTORY_OPS_PORT", "8521"))


def _ensure_bootstrapped():
    from app.models import Settings, ItemType, LocalUser

    with app.app_context():
        db.create_all()

        Settings.get()  # creates the singleton settings row if missing

        if ItemType.query.get("general") is None:
            db.session.add(ItemType(key="general", name="General", is_builtin=True))
            db.session.commit()

        if LocalUser.query.count() == 0:
            password = secrets.token_urlsafe(9)
            admin = LocalUser(username="admin", role="admin")
            admin.set_password(password)
            db.session.add(admin)
            db.session.commit()
            print("=" * 60, flush=True)
            print("[bootstrap] created initial admin account:", flush=True)
            print("  username: admin", flush=True)
            print(f"  password: {password}", flush=True)
            print("  (change this from Settings after logging in)", flush=True)
            print("=" * 60, flush=True)


_ensure_bootstrapped()

if __name__ == "__main__":
    if os.environ.get("INVENTORY_OPS_DEV") == "1":
        app.run(debug=True, host="127.0.0.1", port=PORT)
    else:
        from waitress import serve
        serve(app, host="127.0.0.1", port=PORT)
