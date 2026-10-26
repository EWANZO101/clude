#!/usr/bin/env python3
"""OPSHUB update companion - EXPERIMENTAL auto-update for OPSHUB-licensed OPS resources.

Run this as its own process on the SAME machine as your FXServer (systemd service, screen/tmux, or a
cron job with --once) - it polls the OPSHUB licensing API (opsphone-store.opslabsystems.cloud) for new
versions of whichever resources you're entitled to, downloads and verifies them, and swaps the files on
disk. It then drops a small marker file in the resource's own folder; opslabs-license's existing
check-in loop notices it and does the actual StopResource/StartResource.

IMPORTANT: this is deliberately a completely separate process from FXServer, same reasoning as
opslabs-bodycam/tools/upload-companion.py - FXServer's Lua sandbox has no unzip native and no
proven-safe way to pull a multi-MB binary HTTP response and write many files into a resource directory
while it's running (opslabs-bodycam/server/storage.js has the story of the one time this project pushed
bytes through FXServer's own HTTP stack - it crash-looped the live server). This script changes nothing
about that: FXServer keeps running exactly as it always has; this script does the download/verify/swap
on its own, fully outside the game server's process.

Usage:
    pip3 install requests cryptography
    python3 ops-update-companion.py \\
        --resources-dir /path/to/resources \\
        --key OPSHUB-XXXX-XXXX-XXXX-XXXX
    # --modules towers,phone,pos restricts which modules to watch (default: every resource module your
    # key is entitled to that's actually installed under --resources-dir).

A systemd unit to keep this running on Linux:
    [Unit]
    Description=OPSHUB update companion
    After=network.target

    [Service]
    ExecStart=/usr/bin/python3 /path/to/ops-update-companion.py --resources-dir ... --key ...
    Restart=always
    User=root

    [Install]
    WantedBy=multi-user.target

Rollback: `python3 ops-update-companion.py --resources-dir ... --rollback towers` swaps the previous
install back into place (one generation back is kept locally; the full history stays on OPSHUB, where an
admin can also just re-publish an older version as current - see /license/admin/modules/<code>/releases).
"""
import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import sys
import time
import zipfile

try:
    import requests
except ImportError:
    print("This script needs the 'requests' package: pip3 install requests", file=sys.stderr)
    sys.exit(1)

try:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.serialization import load_pem_public_key
except ImportError:
    print("This script needs the 'cryptography' package: pip3 install cryptography", file=sys.stderr)
    sys.exit(1)

# Same key as every opslabs-license/config.lua's Config.PublicKey - hardcoded (not fetched at runtime)
# so there's no first-contact trust question. Don't change it.
PUBLIC_KEY_PEM = b"""-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAsh1RF0TeOasUZnMcA/OpVLD4zNrV9/FSXMzRRRFU/zs=
-----END PUBLIC KEY-----
"""
MARKER_NAME = '.opshub-update-pending'
VERSION_RE = re.compile(r"""^\s*version\s+['"]([^'"]+)['"]""", re.MULTILINE)
DEFAULT_API = 'https://opsphone-store.opslabsystems.cloud/license/api/v1'


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def local_version(resource_dir):
    fx = os.path.join(resource_dir, 'fxmanifest.lua')
    try:
        with open(fx, 'r', errors='replace') as f:
            text = f.read()
    except OSError:
        return None
    m = VERSION_RE.search(text)
    return m.group(1) if m else None


def find_resource_dir(resources_dir, resource_name):
    """resource folders live under a '[bracketed]' category dir (e.g. [ops], [rps]) one level down -
    search a couple of levels rather than requiring an exact known category."""
    for root, dirs, files in os.walk(resources_dir):
        depth = root[len(resources_dir):].count(os.sep)
        if depth >= 3:
            dirs[:] = []
            continue
        if os.path.basename(root) == resource_name and 'fxmanifest.lua' in files:
            return root
    return None


def discover_targets(api_base, resources_dir, wanted_codes):
    resp = requests.get(f"{api_base}/modules", timeout=20)
    resp.raise_for_status()
    modules = resp.json().get('modules', [])
    targets = []
    for m in modules:
        code, resource = m.get('code'), m.get('resource')
        if not code or not resource:
            continue
        if wanted_codes and code not in wanted_codes:
            continue
        path = find_resource_dir(resources_dir, resource)
        if not path:
            if wanted_codes:
                log(f"  {code} ({resource}) requested but not found under {resources_dir} — skipping")
            continue
        targets.append({'code': code, 'resource': resource, 'path': path})
    return targets


def verify_manifest(data):
    """{'cert','sig','kid'} (ops_license.py's sign()) -> the verified dict, or None if the signature
    doesn't check out against PUBLIC_KEY_PEM."""
    try:
        body = base64.b64decode(data['cert'])
        sig = base64.b64decode(data['sig'])
        pub = load_pem_public_key(PUBLIC_KEY_PEM)
        pub.verify(sig, body)
        return json.loads(body)
    except (InvalidSignature, KeyError, ValueError, TypeError) as e:
        log(f"  manifest signature did not verify: {e}")
        return None


def check_update(api_base, key, code, current_version):
    resp = requests.post(f"{api_base}/updates/check", json={
        'key': key, 'module': code, 'version': current_version or '',
    }, timeout=20)
    if resp.status_code != 200:
        log(f"  {code}: check failed — HTTP {resp.status_code} {resp.text[:200]}")
        return None
    data = resp.json()
    if not data.get('update_available'):
        return None
    manifest = verify_manifest(data)
    if manifest is None:
        return None
    return manifest


def download_verified(api_base, key, code, manifest, staging_root):
    os.makedirs(staging_root, exist_ok=True)
    zip_path = os.path.join(staging_root, f"{code}-{manifest['version']}.zip")
    resp = requests.get(f"{api_base}/updates/{code}/download", params={'key': key}, stream=True, timeout=120)
    if resp.status_code != 200:
        log(f"  {code}: download failed — HTTP {resp.status_code}")
        return None
    h = hashlib.sha256()
    size = 0
    with open(zip_path, 'wb') as out:
        for chunk in resp.iter_content(chunk_size=1024 * 1024):
            out.write(chunk)
            h.update(chunk)
            size += len(chunk)
    if size != manifest['size_bytes'] or h.hexdigest() != manifest['sha256']:
        log(f"  {code}: downloaded file doesn't match the signed manifest (size/hash mismatch) — discarding, nothing installed")
        os.remove(zip_path)
        return None
    return zip_path


def install(code, resource_path, zip_path, version, staging_root):
    """Never touches the live resource folder directly: extract to a staging dir on the SAME filesystem
    (so the final move is an atomic rename, not a copy), keep exactly one rollback generation, then write
    the restart marker opslabs-license's check-in loop is watching for."""
    extract_dir = os.path.join(staging_root, f"{code}-{version}-extracted")
    if os.path.isdir(extract_dir):
        shutil.rmtree(extract_dir)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(extract_dir)
    if not os.path.isfile(os.path.join(extract_dir, 'fxmanifest.lua')):
        log(f"  {code}: extracted package has no fxmanifest.lua at its root — not what a resource zip should look like, aborting")
        shutil.rmtree(extract_dir, ignore_errors=True)
        return False

    rollback_path = resource_path + '.rollback'
    if os.path.isdir(rollback_path):
        shutil.rmtree(rollback_path)
    if os.path.isdir(resource_path):
        shutil.move(resource_path, rollback_path)
    shutil.move(extract_dir, resource_path)
    with open(os.path.join(resource_path, MARKER_NAME), 'w') as f:
        f.write(version)
    os.remove(zip_path)
    log(f"  {code}: installed {version} — waiting for opslabs-license to restart the resource")
    return True


def rollback(resources_dir, code):
    targets = discover_targets(DEFAULT_API, resources_dir, {code})
    if not targets:
        log(f"{code}: not found under {resources_dir}")
        return
    path = targets[0]['path']
    rollback_path = path + '.rollback'
    if not os.path.isdir(rollback_path):
        log(f"{code}: no local rollback copy available (only one generation back is kept)")
        return
    swapped_forward = path + '.rolled-forward'
    if os.path.isdir(swapped_forward):
        shutil.rmtree(swapped_forward)
    shutil.move(path, swapped_forward)
    shutil.move(rollback_path, path)
    shutil.move(swapped_forward, rollback_path)
    version = local_version(path) or 'previous version'
    with open(os.path.join(path, MARKER_NAME), 'w') as f:
        f.write(version)
    log(f"{code}: rolled back to {version} — waiting for opslabs-license to restart the resource")


def run_once(api_base, key, resources_dir, wanted_codes, staging_root):
    targets = discover_targets(api_base, resources_dir, wanted_codes)
    if not targets:
        log("No watched resources found — check --resources-dir and --modules")
        return
    for t in targets:
        cur = local_version(t['path'])
        manifest = check_update(api_base, key, t['code'], cur)
        if manifest is None:
            continue
        log(f"{t['code']}: {cur or '?'} -> {manifest['version']} available"
            + (f" — {manifest['notes']}" if manifest.get('notes') else ""))
        zip_path = download_verified(api_base, key, t['code'], manifest, staging_root)
        if zip_path:
            install(t['code'], t['path'], zip_path, manifest['version'], staging_root)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--resources-dir", required=True, help="the FXServer's resources/ folder")
    ap.add_argument("--key", help="your OPSHUB license key (required unless --rollback)")
    ap.add_argument("--modules", help="comma-separated module codes to watch (default: every entitled resource module found installed)")
    ap.add_argument("--api-base", default=DEFAULT_API, help=f"default: {DEFAULT_API}")
    ap.add_argument("--interval", type=float, default=300.0, help="seconds between checks (default 300 = 5 min)")
    ap.add_argument("--once", action="store_true", help="check once and exit instead of looping (for cron)")
    ap.add_argument("--rollback", metavar="MODULE_CODE", help="swap the previous install back into place for this module and exit")
    args = ap.parse_args()

    resources_dir = os.path.abspath(args.resources_dir)
    if not os.path.isdir(resources_dir):
        ap.error(f"{resources_dir} is not a directory")

    if args.rollback:
        rollback(resources_dir, args.rollback)
        return

    if not args.key:
        ap.error("pass --key OPSHUB-XXXX-XXXX-XXXX-XXXX (or --rollback MODULE_CODE)")

    wanted = {c.strip() for c in args.modules.split(',') if c.strip()} if args.modules else None
    staging_root = os.path.join(resources_dir, '.opshub-staging')

    log(f"Watching {resources_dir} ({'all entitled resource modules' if not wanted else ', '.join(sorted(wanted))}) -> {args.api_base}")
    if args.once:
        run_once(args.api_base, args.key, resources_dir, wanted, staging_root)
        return
    while True:
        run_once(args.api_base, args.key, resources_dir, wanted, staging_root)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
