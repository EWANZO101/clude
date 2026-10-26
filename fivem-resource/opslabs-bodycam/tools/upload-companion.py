#!/usr/bin/env python3
"""Xon Sight media upload companion - EXPERIMENTAL portal-hosting alternative to self-hosting
opslabs-bodycam's media/ folder with your own web server.

Run this as its own process on the SAME machine as your FXServer (systemd service, screen/tmux,
or a cron job that just runs it once with --once) - it watches the resource's media/ folder for
new recordings and pushes each one to your Xon Sight portal over HTTP, so ServerConfig.Storage.
PublicUrl can be the portal's own address instead of a web server you run yourself.

IMPORTANT: this is deliberately a completely separate process from FXServer. opslabs-bodycam
itself never pushes video bytes through FXServer's own HTTP client - doing that crashed the whole
game server once already (see opslabs-bodycam/server/storage.js's comment). This script changes
nothing about that: FXServer keeps saving files to disk exactly as it always has; this script just
reads them back off disk afterwards and uploads them on its own, fully independent of the game
server's process and networking stack.

Usage (Linux/macOS):
    pip3 install requests   # if not already installed
    python3 upload-companion.py \\
        --media-dir /path/to/resources/[rps]/opslabs-bodycam/media \\
        --portal-url https://fly14.opslabsystems.cloud \\
        --token YOUR-COMMUNITY-TOKEN
    # the same token you set in config_server.lua's ServerConfig.XonSight.Token (get it from /integration)

Usage (Windows - FXServer's txAdmin Windows build included):
    1. Install Python from https://python.org if you don't already have it (check "Add
       python.exe to PATH" during install), then open PowerShell or Command Prompt:
    2. pip install requests
    3. python upload-companion.py --media-dir "C:\path\to\resources\[rps]\opslabs-bodycam\media" --portal-url https://fly14.opslabsystems.cloud --token YOUR-COMMUNITY-TOKEN
    It loops and keeps checking every --interval seconds (default 15) - just leave that window
    open (minimized is fine). To run it in the background without a window, use Task Scheduler:
    "Create Task" -> Trigger "At log on" -> Action "Start a program" ->
    Program: pythonw.exe, Arguments: the same upload-companion.py ... line as above.

Then set in config_server.lua:
    ServerConfig.Storage.PublicUrl = 'https://fly14.opslabsystems.cloud/media'

A systemd unit to keep this running on Linux instead:
    [Unit]
    Description=Xon Sight media upload companion
    After=network.target

    [Service]
    ExecStart=/usr/bin/python3 /path/to/upload-companion.py --media-dir ... --portal-url ... --token ...
    Restart=always
    User=root

    [Install]
    WantedBy=multi-user.target
"""

import argparse
import json
import os
import sys
import time

try:
    import requests
except ImportError:
    print("This script needs the 'requests' package: pip3 install requests", file=sys.stderr)
    sys.exit(1)

STATE_FILENAME = ".xonsight-uploaded.json"
FILENAME_SUFFIX = ".webm"


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def load_state(media_dir):
    path = os.path.join(media_dir, STATE_FILENAME)
    try:
        with open(path, "r") as f:
            return set(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError):
        return set()


def save_state(media_dir, uploaded):
    path = os.path.join(media_dir, STATE_FILENAME)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(sorted(uploaded), f)
    os.replace(tmp, path)


def upload_one(portal_url, headers, media_dir, filename):
    full = os.path.join(media_dir, filename)
    try:
        with open(full, "rb") as f:
            resp = requests.post(
                portal_url.rstrip("/") + "/api/xonsight/media/upload",
                headers=headers,
                data={"filename": filename},
                files={"file": (filename, f, "video/webm")},
                timeout=60,
            )
    except requests.RequestException as e:
        log(f"  upload failed for {filename}: {e}")
        return False
    if resp.status_code == 200:
        return True
    log(f"  upload refused for {filename}: HTTP {resp.status_code} {resp.text[:200]}")
    return False


def run_once(portal_url, headers, media_dir):
    uploaded = load_state(media_dir)
    try:
        files = sorted(f for f in os.listdir(media_dir) if f.endswith(FILENAME_SUFFIX))
    except OSError as e:
        log(f"Could not list {media_dir}: {e}")
        return
    pending = [f for f in files if f not in uploaded]
    if not pending:
        return
    log(f"{len(pending)} new recording(s) to upload")
    changed = False
    for filename in pending:
        if upload_one(portal_url, headers, media_dir, filename):
            uploaded.add(filename)
            changed = True
            log(f"  uploaded {filename}")
    if changed:
        save_state(media_dir, uploaded)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--media-dir", required=True, help="opslabs-bodycam resource's media/ folder")
    ap.add_argument("--portal-url", required=True, help="Your Xon Sight portal's base URL, e.g. https://fly14.opslabsystems.cloud")
    ap.add_argument("--token", required=True, help="Community API token (X-XonSight-Token) - from /integration")
    ap.add_argument("--interval", type=float, default=15.0, help="Seconds between checks (default 15)")
    ap.add_argument("--once", action="store_true", help="Check once and exit instead of looping (for cron)")
    args = ap.parse_args()

    headers = {"X-XonSight-Token": args.token}
    media_dir = os.path.abspath(args.media_dir)
    if not os.path.isdir(media_dir):
        ap.error(f"{media_dir} is not a directory")

    log(f"Watching {media_dir} -> {args.portal_url}")
    if args.once:
        run_once(args.portal_url, headers, media_dir)
        return
    while True:
        run_once(args.portal_url, headers, media_dir)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
