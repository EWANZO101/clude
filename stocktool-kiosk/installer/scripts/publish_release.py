"""
publish_release.py — announces a new StockTool Kiosk build to
stocktool-api's release channel (POST /api/updates). This is the entire
"online update" mechanism: once a release is published here, every kiosk
already paired with StockTool Setup picks it up automatically on its next
sync cycle (see backup22/sync_loop.py -> updater.py), downloads it,
verifies its SHA-256, and self-applies with an automatic rollback if the
new build fails its boot check (see main.py's confirm_or_rollback).

This script does NOT upload the .exe anywhere — `--download-url` must
already be a real, reachable URL (your own static file host, S3/R2
bucket, GitHub release asset, etc.) by the time you run this. Publishing
a release just announces "the exe at this URL, with this checksum, is
version X" — kiosks do the downloading themselves.

Usage:
    python scripts/publish_release.py \\
        --api-base https://api.opslabsystems.cloud \\
        --username admin --password '...' \\
        --version 2.2.0 \\
        --exe-path dist/StockToolKiosk.exe \\
        --download-url https://cdn.opslabsystems.cloud/StockToolKiosk.exe \\
        --release-notes "Adds category-aware kiosk browsing"

Or, if you already have a checksum and don't have the file locally:
    python scripts/publish_release.py --api-base ... --username ... --password ... \\
        --version 2.2.0 --checksum <sha256> --download-url ...
"""
import argparse
import hashlib
import sys
import requests


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Publish a new StockTool Kiosk release")
    parser.add_argument("--api-base", required=True, help="e.g. https://api.opslabsystems.cloud")
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--version", required=True, help="e.g. 2.2.0 — must match version.py")
    parser.add_argument("--download-url", required=True, help="Public URL where the .exe is hosted")
    parser.add_argument("--exe-path", help="Local path to StockToolKiosk.exe, to compute its checksum")
    parser.add_argument("--checksum", help="SHA-256 hex digest, if you already have it (skips --exe-path)")
    parser.add_argument("--channel", default="stable", choices=["stable", "beta"])
    parser.add_argument("--release-notes", default="")
    parser.add_argument("--min-supported-version", default=None,
                         help="Older clients must upgrade before this one applies (rarely needed)")
    args = parser.parse_args()

    if not args.checksum and not args.exe_path:
        parser.error("one of --checksum or --exe-path is required")

    checksum = args.checksum or sha256_of(args.exe_path)
    if len(checksum) != 64:
        parser.error(f"checksum must be 64 hex characters, got {len(checksum)}")

    base = args.api_base.rstrip("/")

    login = requests.post(f"{base}/api/auth/login",
                           json={"username": args.username, "password": args.password}, timeout=15)
    login.raise_for_status()
    token = login.json()["access_token"]

    resp = requests.post(
        f"{base}/api/updates",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "version": args.version,
            "channel": args.channel,
            "download_url": args.download_url,
            "checksum_sha256": checksum,
            "release_notes": args.release_notes or None,
            "min_supported_version": args.min_supported_version,
        },
        timeout=15,
    )

    if resp.status_code != 201:
        print(f"FAILED ({resp.status_code}): {resp.text}", file=sys.stderr)
        sys.exit(1)

    release = resp.json()
    print(f"Published {release['version']} on channel '{release['channel']}'.")
    print(f"  download_url: {release['download_url']}")
    print(f"  checksum:     {release['checksum_sha256']}")
    print("Paired kiosks will pick this up on their next sync cycle.")


if __name__ == "__main__":
    main()
