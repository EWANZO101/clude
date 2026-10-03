"""Namecheap adapter — implements DNSProvider by delegating to
namecheap_service.py. See that module's docstring for why create/update/
delete all funnel through getHosts + setHosts instead of per-record calls.
"""
from flask import current_app

from services.dns_providers import namecheap_service as nc
from services.dns_providers.base import DNSProvider, DNSProviderError
from config import persist_namecheap_credentials, persist_namecheap_domain


class NamecheapProvider(DNSProvider):
    key = "namecheap"
    label = "Namecheap"
    record_types = nc.RECORD_TYPES
    proxyable_types = nc.PROXYABLE_TYPES
    supports_nameserver_switch = True

    def is_configured(self):
        return nc.is_configured()

    def verify_credentials(self, api_user=None, api_key=None, username=None, client_ip=None, **_):
        try:
            nc.verify_credentials(api_user, api_key, username, client_ip)
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc
        return True

    def save_credentials(self, api_user=None, api_key=None, username=None, client_ip=None, **_):
        persist_namecheap_credentials(api_user, api_key, username or api_user, client_ip)
        current_app.config["NAMECHEAP_API_USER"] = api_user
        current_app.config["NAMECHEAP_API_KEY"] = api_key
        current_app.config["NAMECHEAP_USERNAME"] = username or api_user
        current_app.config["NAMECHEAP_CLIENT_IP"] = client_ip

    def remove_credentials(self):
        persist_namecheap_credentials("", "", "", "")
        persist_namecheap_domain("")
        for k in ("NAMECHEAP_API_USER", "NAMECHEAP_API_KEY", "NAMECHEAP_USERNAME", "NAMECHEAP_CLIENT_IP", "NAMECHEAP_ACTIVE_DOMAIN"):
            current_app.config[k] = ""

    def active_domain_id(self):
        return current_app.config.get("NAMECHEAP_ACTIVE_DOMAIN", "")

    def persist_active_domain(self, domain_id):
        persist_namecheap_domain(domain_id)
        current_app.config["NAMECHEAP_ACTIVE_DOMAIN"] = domain_id

    def list_domains(self):
        try:
            return nc.list_domains()
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc

    def list_records(self, domain_id):
        try:
            return nc.get_hosts(domain_id)
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc

    def create_record(self, domain_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        try:
            return nc.create_host(domain_id, record_type, name, content, ttl=ttl, priority=priority)
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc

    def update_record(self, domain_id, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        try:
            return nc.update_host(domain_id, record_id, record_type, name, content, ttl=ttl, priority=priority)
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc

    def delete_record(self, domain_id, record_id):
        try:
            return nc.delete_host(domain_id, record_id)
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc

    def get_nameserver_mode(self, domain_id):
        try:
            return nc.get_nameserver_mode(domain_id)
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc

    def use_provider_dns(self, domain_id):
        try:
            return nc.set_default_dns(domain_id)
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc

    def use_custom_nameservers(self, domain_id, nameservers):
        try:
            return nc.set_custom_nameservers(domain_id, nameservers)
        except nc.NamecheapError as exc:
            raise DNSProviderError(str(exc)) from exc
