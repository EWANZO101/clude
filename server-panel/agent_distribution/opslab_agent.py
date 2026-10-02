#!/usr/bin/env python3
"""OpsLab Agent - lightweight check-in client for OpsLab Server Panel.

Install (as root):
    python3 opslab_agent.py --install --panel-url https://serverpanel.opslabsystems.cloud

That registers this VM with the panel (printing a one-time pairing code
you'll enter on the panel to claim it), writes a small local state file,
installs a systemd unit so this keeps running across reboots, and starts
it immediately.

Manual run (e.g. for testing without installing the service):
    python3 opslab_agent.py --run --panel-url https://serverpanel.opslabsystems.cloud

Only dependency: `requests` (pip3 install requests). Everything else is
Python standard library, on purpose - this is meant to drop onto any
Linux VM with minimal fuss. It never opens a listening port and never
accepts inbound connections; every request is initiated by this script
outbound to the panel, so no firewall changes are needed on this VM.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

try:
    import requests
except ImportError:
    sys.exit("This script needs the 'requests' package: pip3 install requests")

STATE_DIR = "/etc/opslab-agent"
STATE_FILE = os.path.join(STATE_DIR, "state.json")
SERVICE_PATH = "/etc/systemd/system/opslab-agent.service"
HEARTBEAT_INTERVAL_SECONDS = 20
REQUEST_TIMEOUT = 15
AGENT_VERSION = "1.0"


def _load_state():
    if not os.path.exists(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)
    os.chmod(STATE_FILE, 0o600)  # agent_token lives in here - keep it off-limits to non-root users


def _hostname():
    try:
        return socket.gethostname()
    except Exception:
        return ""


def register(panel_url):
    resp = requests.post(
        f"{panel_url.rstrip('/')}/api/agent/register",
        json={"hostname": _hostname(), "agent_version": AGENT_VERSION},
        timeout=REQUEST_TIMEOUT,
    )
    resp.raise_for_status()
    data = resp.json()

    state = _load_state()
    state["panel_url"] = panel_url
    state["agent_token"] = data["agent_token"]
    _save_state(state)

    print("=" * 60)
    if data.get("claimed"):
        print("This VM is already claimed on the panel.")
    else:
        print("Registered with the panel.")
        print(f"  Pairing code: {data['pairing_code']}")
        print("  Enter this VM's IP address and the pairing code above")
        print(f"  at: {panel_url.rstrip('/')}/portal/claim")
    print("=" * 60)
    return state


def _run_ssh_action(enable):
    """Best-effort across common init/service names - tries systemctl
    first (the overwhelming majority of current distros use it), falls
    back to service(8) for older ones. Never raises; returns (ok, detail)
    so the caller can report status back to the panel either way."""
    verb = "start" if enable else "stop"
    persist_verb = "enable" if enable else "disable"

    for unit in ("ssh", "sshd"):
        try:
            subprocess.run(["systemctl", verb, unit], check=True, capture_output=True, timeout=20)
            subprocess.run(["systemctl", persist_verb, unit], check=False, capture_output=True, timeout=20)
            return True, f"systemctl {verb} {unit}"
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
            continue

    for unit in ("ssh", "sshd"):
        try:
            subprocess.run(["service", unit, verb], check=True, capture_output=True, timeout=20)
            return True, f"service {unit} {verb}"
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
            continue

    return False, "no ssh/sshd service found via systemctl or service(8)"


def _run_power_off():
    for cmd in (["shutdown", "-h", "now"], ["poweroff"]):
        try:
            subprocess.Popen(cmd)
            return True, " ".join(cmd)
        except FileNotFoundError:
            continue
    return False, "no shutdown/poweroff command found"


def _execute(action):
    if action == "disable_ssh":
        return _run_ssh_action(enable=False)
    if action == "enable_ssh":
        return _run_ssh_action(enable=True)
    if action == "power_off":
        return _run_power_off()
    return False, f"unknown action: {action}"


def _heartbeat_loop(state):
    panel_url = state["panel_url"].rstrip("/")
    token = state["agent_token"]

    while True:
        try:
            resp = requests.post(
                f"{panel_url}/api/agent/heartbeat",
                json={"agent_token": token, "hostname": _hostname(), "agent_version": AGENT_VERSION},
                timeout=REQUEST_TIMEOUT,
            )
            if resp.status_code == 403:
                print("Panel doesn't recognize this agent_token - re-run with --install to re-register.")
                time.sleep(HEARTBEAT_INTERVAL_SECONDS)
                continue
            resp.raise_for_status()
            data = resp.json()

            for cmd in data.get("commands", []):
                ok, detail = _execute(cmd["action"])
                print(f"executed {cmd['action']}: ok={ok} detail={detail}")
                try:
                    requests.post(
                        f"{panel_url}/api/agent/ack",
                        json={
                            "agent_token": token,
                            "command_id": cmd["id"],
                            "status": "acked" if ok else "failed",
                            "detail": detail,
                        },
                        timeout=REQUEST_TIMEOUT,
                    )
                except requests.RequestException:
                    pass  # picked up again on the next heartbeat if the panel re-queues it

        except requests.RequestException as exc:
            print(f"Heartbeat failed (will retry): {exc}")

        time.sleep(HEARTBEAT_INTERVAL_SECONDS)


def install(panel_url):
    if os.geteuid() != 0:
        sys.exit("--install must be run as root (needed to write the systemd unit and control sshd).")

    register(panel_url)

    script_path = os.path.abspath(__file__)
    unit = f"""[Unit]
Description=OpsLab Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart={sys.executable} {script_path} --run
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
"""
    with open(SERVICE_PATH, "w") as f:
        f.write(unit)

    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "opslab-agent"], check=True)
    subprocess.run(["systemctl", "restart", "opslab-agent"], check=True)
    print("Installed and started as a systemd service (opslab-agent) - will auto-start on boot.")


def main():
    parser = argparse.ArgumentParser(description="OpsLab Agent")
    parser.add_argument("--install", action="store_true", help="Register this VM and install as a systemd service")
    parser.add_argument("--run", action="store_true", help="Run the heartbeat loop directly (used by the systemd unit)")
    parser.add_argument("--panel-url", help="e.g. https://serverpanel.opslabsystems.cloud")
    args = parser.parse_args()

    if args.install:
        if not args.panel_url:
            sys.exit("--install requires --panel-url")
        install(args.panel_url)
    elif args.run:
        state = _load_state()
        if not state.get("agent_token"):
            sys.exit("No saved agent_token found - run with --install first.")
        _heartbeat_loop(state)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
