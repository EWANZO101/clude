"""GoDaddy adapter — implements DNSProvider by delegating to
services/dns_providers/godaddy_service.py.

Unlike Cloudflare and Namecheap, the GoDaddy Domains v3 API has no
"list every domain on this account" endpoint (that's still v1-only —
see godaddy_service.py's docstring), so this panel can't discover zones
automatically the way it does for the other two providers. Instead the
domain is entered once, alongside the API token, when GoDaddy is
connected, and list_domains() just re-confirms that one domain still
resolves. The zone-picker dropdown in the template ends up with exactly
one option for GoDaddy — that's expected here, not a bug.
"""
from flask import current_app

from services.dns_providers import godaddy_service as gd
from services.dns_providers.base import DNSProvider, DNSProviderError
from config import persist_godaddy_credentials, persist_godaddy_domain


class GoDaddyProvider(DNSProvider):
    key = "godaddy"
    label = "GoDaddy"
    record_types = gd.RECORD_TYPES
    proxyable_types = gd.PROXYABLE_TYPES
    supports_nameserver_switch = False

    def _token(self):
        return current_app.config.get("GODADDY_API_TOKEN", "")

    def _domain(self):
        return current_app.config.get("GODADDY_DOMAIN", "")

    def is_configured(self):
        return bool(self._token() and self._domain())

    def verify_credentials(self, token=None, domain=None, **_):
        try:
            gd.verify_token(token, domain=domain)
            if domain:
                gd.get_domain(token, domain)
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc
        return True

    def save_credentials(self, token=None, domain=None, **_):
        persist_godaddy_credentials(token, domain)
        current_app.config["GODADDY_API_TOKEN"] = token
        current_app.config["GODADDY_DOMAIN"] = domain

    def remove_credentials(self):
        persist_godaddy_credentials("", "")
        current_app.config["GODADDY_API_TOKEN"] = ""
        current_app.config["GODADDY_DOMAIN"] = ""

    def active_domain_id(self):
        return self._domain()

    def persist_active_domain(self, domain_id):
        # There's only ever one domain here (see class docstring) — this
        # exists to satisfy the DNSProvider contract the template calls
        # unconditionally, not because GoDaddy actually supports switching
        # between multiple zones.
        persist_godaddy_domain(domain_id)
        current_app.config["GODADDY_DOMAIN"] = domain_id

    def list_domains(self):
        try:
            return gd.list_domains(self._token(), self._domain())
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

    def list_records(self, domain_id):
        try:
            return gd.list_dns_records(self._token(), domain_id)
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

    def create_record(self, domain_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        try:
            return gd.create_dns_record(
                self._token(), domain_id, record_type, name, content,
                ttl=ttl, proxied=proxied, priority=priority,
            )
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

    def update_record(self, domain_id, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        try:
            return gd.update_dns_record(
                self._token(), domain_id, record_id, record_type, name, content,
                ttl=ttl, proxied=proxied, priority=priority,
            )
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

    def delete_record(self, domain_id, record_id):
        try:
            return gd.delete_dns_record(self._token(), domain_id, record_id)
        except gd.GoDaddyError as exc:
            raise DNSProviderError(str(exc)) from exc

