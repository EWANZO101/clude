#!/usr/bin/env bash
# Fixes cloudflare_provider.py: calls into cloudflare_service.py were
# missing the required 'token' first argument on every function
# (list_zones, list_dns_records, create/update/delete_dns_record).
# This backs up the current file, writes the corrected version, and
# restarts the service.
set -euo pipefail

APP_DIR="/root/server-panel"
TARGET="$APP_DIR/services/dns_providers/cloudflare_provider.py"
SERVICE_NAME="SERVERPANEL.service"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$APP_DIR/backups"

if [[ ! -f "$TARGET" ]]; then
    echo "ERROR: $TARGET not found. Check APP_DIR at the top of this script." >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/cloudflare_provider.py.${TIMESTAMP}.bak"
cp "$TARGET" "$BACKUP_FILE"
echo "Backed up current file to $BACKUP_FILE"

cat > "$TARGET" << 'PYEOF'
"""Cloudflare adapter — implements DNSProvider by delegating to
services/cloudflare_service.py.

Every function in cloudflare_service.py takes the API token explicitly
as its first argument rather than reading a global token out of app
config (see that module's docstring — it's set up this way to eventually
support multiple saved Cloudflare accounts). Nothing else in this
codebase currently persists more than one account though: config.py
only has a single CLOUDFLARE_API_TOKEN slot. So this adapter just reads
that one token out of config and passes it explicitly on every call,
matching cloudflare_service.py's real signatures. If/when multi-account
support gets built, this is the file that needs to change to loop over
saved connections instead of a single token.
"""
from flask import current_app

from services import cloudflare_service as cf
from services.dns_providers.base import DNSProvider, DNSProviderError
from config import persist_cloudflare_token, persist_cloudflare_zone


class CloudflareProvider(DNSProvider):
    key = "cloudflare"
    label = "Cloudflare"
    record_types = cf.RECORD_TYPES
    proxyable_types = cf.PROXYABLE_TYPES
    supports_nameserver_switch = False

    def _token(self):
        return current_app.config.get("CLOUDFLARE_API_TOKEN", "")

    def is_configured(self):
        return bool(self._token())

    def verify_credentials(self, token=None, **_):
        try:
            cf.verify_token(token)
        except cf.CloudflareError as exc:
            raise DNSProviderError(str(exc)) from exc
        return True

    def save_credentials(self, token=None, **_):
        persist_cloudflare_token(token)
        current_app.config["CLOUDFLARE_API_TOKEN"] = token

    def remove_credentials(self):
        persist_cloudflare_token("")
        persist_cloudflare_zone("")
        current_app.config["CLOUDFLARE_API_TOKEN"] = ""
        current_app.config["CLOUDFLARE_ZONE_ID"] = ""

    def active_domain_id(self):
        return current_app.config.get("CLOUDFLARE_ZONE_ID", "")

    def persist_active_domain(self, domain_id):
        persist_cloudflare_zone(domain_id)
        current_app.config["CLOUDFLARE_ZONE_ID"] = domain_id

    def list_domains(self):
        try:
            return cf.list_zones(self._token())
        except cf.CloudflareError as exc:
            raise DNSProviderError(str(exc)) from exc

    def list_records(self, domain_id):
        try:
            return cf.list_dns_records(self._token(), domain_id)
        except cf.CloudflareError as exc:
            raise DNSProviderError(str(exc)) from exc

    def create_record(self, domain_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        try:
            return cf.create_dns_record(
                self._token(), domain_id, record_type, name, content,
                ttl=ttl, proxied=proxied, priority=priority,
            )
        except cf.CloudflareError as exc:
            raise DNSProviderError(str(exc)) from exc

    def update_record(self, domain_id, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        try:
            return cf.update_dns_record(
                self._token(), domain_id, record_id, record_type, name, content,
                ttl=ttl, proxied=proxied, priority=priority,
            )
        except cf.CloudflareError as exc:
            raise DNSProviderError(str(exc)) from exc

    def delete_record(self, domain_id, record_id):
        try:
            return cf.delete_dns_record(self._token(), domain_id, record_id)
        except cf.CloudflareError as exc:
            raise DNSProviderError(str(exc)) from exc
PYEOF

echo "Wrote corrected $TARGET"

# Sanity check: make sure it at least parses before restarting the service
PYTHON_BIN="$APP_DIR/venv/bin/python3"
if [[ ! -x "$PYTHON_BIN" ]]; then
    PYTHON_BIN="python3"
fi
if ! "$PYTHON_BIN" -m py_compile "$TARGET"; then
    echo "ERROR: new file failed to compile. Restoring backup." >&2
    cp "$BACKUP_FILE" "$TARGET"
    exit 1
fi
echo "Syntax check passed."

echo "Restarting $SERVICE_NAME ..."
systemctl restart "$SERVICE_NAME"
sleep 2
systemctl --no-pager status "$SERVICE_NAME" | head -n 10

echo
echo "Done. Tail the log to confirm /dns now loads cleanly:"
echo "  journalctl -u $SERVICE_NAME -n 20 --no-pager"
