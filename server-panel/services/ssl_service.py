"""Reads Certbot-managed TLS certificate status via `certbot certificates`.
Read-only by default; renew_all() shells out to `certbot renew` explicitly
and only when the admin clicks the button."""
import re
import shutil
import subprocess
from datetime import datetime


class SSLServiceError(Exception):
    pass


def is_installed():
    return shutil.which("certbot") is not None


def _run(args, timeout=30):
    try:
        result = subprocess.run(
            ["certbot", *args],
            capture_output=True, text=True, timeout=timeout,
        )
    except FileNotFoundError as exc:
        raise SSLServiceError("certbot is not installed on this host.") from exc
    except subprocess.TimeoutExpired as exc:
        raise SSLServiceError("certbot timed out.") from exc
    return result


def get_certificates():
    """Parses `certbot certificates` into a list of dicts:
    name, domains (list), expiry (datetime|None), days_left (int|None),
    status ('valid'|'expiring'|'expired'|'unknown'), cert_path, key_path."""
    if not is_installed():
        return []

    result = _run(["certificates"])
    if result.returncode != 0:
        raise SSLServiceError(result.stderr.strip() or "certbot certificates failed.")

    output = result.stdout
    blocks = re.split(r"\n(?=\s*Certificate Name:)", output)
    certs = []
    for block in blocks:
        name_m = re.search(r"Certificate Name:\s*(\S+)", block)
        if not name_m:
            continue
        domains_m = re.search(r"Domains:\s*(.+)", block)
        expiry_m = re.search(r"Expiry Date:\s*([0-9-]+\s[0-9:]+\+[0-9]{2}:[0-9]{2})", block)
        cert_path_m = re.search(r"Certificate Path:\s*(\S+)", block)
        key_path_m = re.search(r"Private Key Path:\s*(\S+)", block)
        invalid = "INVALID" in block

        expiry = None
        days_left = None
        if expiry_m:
            try:
                expiry = datetime.strptime(expiry_m.group(1), "%Y-%m-%d %H:%M:%S%z")
                days_left = (expiry - datetime.now(expiry.tzinfo)).days
            except ValueError:
                expiry = None

        if invalid:
            status = "expired"
        elif days_left is None:
            status = "unknown"
        elif days_left <= 14:
            status = "expiring"
        else:
            status = "valid"

        certs.append({
            "name": name_m.group(1),
            "domains": [d.strip() for d in domains_m.group(1).split()] if domains_m else [],
            "expiry": expiry,
            "days_left": days_left,
            "status": status,
            "cert_path": cert_path_m.group(1) if cert_path_m else None,
            "key_path": key_path_m.group(1) if key_path_m else None,
        })

    certs.sort(key=lambda c: (c["days_left"] if c["days_left"] is not None else 999999))
    return certs


def renew_all(dry_run=False):
    """Runs `certbot renew` (only actually renews certs within their renewal
    window; Certbot itself decides that, this doesn't force early renewal
    unless dry_run demonstrates the process)."""
    args = ["renew", "--quiet"]
    if dry_run:
        args.append("--dry-run")
    result = _run(args, timeout=120)
    if result.returncode != 0:
        raise SSLServiceError(result.stderr.strip() or result.stdout.strip() or "certbot renew failed.")
    return result.stdout.strip()
