import os
import re
import subprocess

from utils.ttl_cache import ttl_cache

SITES_AVAILABLE = "/etc/nginx/sites-available"
SITES_ENABLED = "/etc/nginx/sites-enabled"
DOMAIN_RE = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$")


class NginxError(Exception):
    pass


def _run(args, timeout=60):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError as exc:
        raise NginxError(f"'{args[0]}' isn't installed or on PATH.") from exc
    except subprocess.TimeoutExpired as exc:
        raise NginxError(f"Command timed out: {' '.join(args)}") from exc


@ttl_cache(seconds=60)
def is_installed():
    try:
        result = _run(["nginx", "-v"])
    except NginxError:
        return False
    return result.returncode == 0 or "nginx version" in (result.stderr or "")


def install_nginx():
    steps = [
        (["apt-get", "update", "-y"], "apt-get update failed"),
        (["apt-get", "install", "-y", "nginx"], "nginx install failed"),
    ]
    for args, err_msg in steps:
        result = _run(args, timeout=300)
        if result.returncode != 0:
            raise NginxError(f"{err_msg}: {result.stderr.strip()[-500:]}")
    is_installed.invalidate()
    return True


def _validate_domain(domain):
    domain = domain.strip().lower()
    if not DOMAIN_RE.match(domain):
        raise NginxError(f"'{domain}' doesn't look like a valid domain name.")
    return domain


def list_sites():
    sites = []
    if not os.path.isdir(SITES_AVAILABLE):
        return sites
    enabled = set(os.listdir(SITES_ENABLED)) if os.path.isdir(SITES_ENABLED) else set()
    for fname in sorted(os.listdir(SITES_AVAILABLE)):
        path = os.path.join(SITES_AVAILABLE, fname)
        if not os.path.isfile(path):
            continue
        server_name = None
        proxy_pass = None
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            m = re.search(r"server_name\s+([^;]+);", content)
            if m:
                server_name = m.group(1).strip()
            m = re.search(r"proxy_pass\s+([^;]+);", content)
            if m:
                proxy_pass = m.group(1).strip()
            has_ssl = "listen 443" in content or "ssl_certificate" in content
        except OSError:
            content, has_ssl = "", False
        sites.append({
            "filename": fname,
            "server_name": server_name or fname,
            "proxy_pass": proxy_pass,
            "enabled": fname in enabled,
            "ssl": has_ssl,
        })
    return sites


def build_site_config(domain, port, extra_directives=""):
    domain = _validate_domain(domain)
    try:
        port_int = int(port)
        if not (1 <= port_int <= 65535):
            raise ValueError
    except ValueError as exc:
        raise NginxError(f"'{port}' isn't a valid port number.") from exc

    extra = f"\n    {extra_directives.strip()}" if extra_directives and extra_directives.strip() else ""

    config = (
        "server {\n"
        "    listen 80;\n"
        f"    server_name {domain};\n\n"
        "    location / {\n"
        f"        proxy_pass http://127.0.0.1:{port_int};\n"
        "        proxy_set_header Host $host;\n"
        "        proxy_set_header X-Real-IP $remote_addr;\n"
        "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n"
        "        proxy_set_header X-Forwarded-Proto $scheme;\n"
        f"{extra}\n"
        "    }\n"
        "}\n"
    )
    return domain, config


def write_site(domain, config_text):
    if not os.path.isdir(SITES_AVAILABLE):
        raise NginxError(f"{SITES_AVAILABLE} doesn't exist — is nginx installed?")

    available_path = os.path.join(SITES_AVAILABLE, f"{domain}.conf")

    if os.path.isfile(available_path):
        from services import backup_service
        backup_service.backup_file(available_path)

    try:
        with open(available_path, "w", encoding="utf-8") as f:
            f.write(config_text)
    except PermissionError as exc:
        raise NginxError(f"No permission to write {available_path}. The panel needs to run as root.") from exc

    enabled_path = os.path.join(SITES_ENABLED, f"{domain}.conf")
    if not os.path.exists(enabled_path):
        try:
            os.symlink(available_path, enabled_path)
        except OSError as exc:
            raise NginxError(f"Failed to enable site: {exc}") from exc

    return available_path


def remove_site(filename):
    safe_name = os.path.basename(filename)
    available_path = os.path.join(SITES_AVAILABLE, safe_name)
    enabled_path = os.path.join(SITES_ENABLED, safe_name)
    if os.path.islink(enabled_path) or os.path.exists(enabled_path):
        os.remove(enabled_path)
    if os.path.exists(available_path):
        os.remove(available_path)
    return True


def test_config():
    result = _run(["nginx", "-t"])
    ok = result.returncode == 0
    output = (result.stdout or "") + (result.stderr or "")
    return ok, output.strip()


def reload_nginx():
    result = _run(["systemctl", "reload", "nginx"])
    if result.returncode != 0:
        raise NginxError(result.stderr.strip() or "Failed to reload nginx.")
    return True


# ---- SSL / Certbot ----

def certbot_installed():
    try:
        result = _run(["certbot", "--version"])
    except NginxError:
        return False
    return result.returncode == 0


def install_certbot():
    result = _run(["apt-get", "install", "-y", "certbot", "python3-certbot-nginx"], timeout=300)
    if result.returncode != 0:
        raise NginxError(f"certbot install failed: {result.stderr.strip()[-500:]}")
    return True


def issue_certificate(domain, email, force_https=True):
    domain = _validate_domain(domain)
    args = ["certbot", "--nginx", "-d", domain, "--non-interactive", "--agree-tos", "-m", email]
    if force_https:
        args += ["--redirect"]
    else:
        args += ["--no-redirect"]
    result = _run(args, timeout=180)
    if result.returncode != 0:
        raise NginxError(result.stderr.strip()[-800:] or "certbot failed to issue the certificate.")
    return result.stdout.strip()


def renew_certificates():
    result = _run(["certbot", "renew", "--non-interactive"], timeout=300)
    if result.returncode != 0:
        raise NginxError(result.stderr.strip()[-800:] or "certbot renew failed.")
    return result.stdout.strip()


def delete_certificate(domain):
    domain = _validate_domain(domain)
    result = _run(["certbot", "delete", "--cert-name", domain, "--non-interactive"], timeout=60)
    if result.returncode != 0:
        raise NginxError(result.stderr.strip()[-500:] or f"Failed to delete certificate for {domain}.")
    return True


# ---- Repair ----

def list_site_backups(filename):
    from services import backup_service
    return backup_service.list_backups(filename)


def restore_site_backup(filename, backup_path):
    from services import backup_service
    available_path = os.path.join(SITES_AVAILABLE, filename)
    backup_service.restore_backup(backup_path, available_path)
    ok, output = test_config()
    if not ok:
        raise NginxError(f"Restored the backup, but nginx -t still fails: {output}")
    reload_nginx()
    return True


def repair():
    """Test config, and restart nginx if the test passes. Returns (ok, message)."""
    try:
        ok, output = test_config()
    except NginxError as exc:
        return False, str(exc)

    if not ok:
        return False, f"nginx -t failed:\n{output}"

    try:
        reload_nginx()
    except NginxError as exc:
        return False, f"Config is valid, but reload failed: {exc}"

    return True, "Config is valid and nginx was reloaded."
