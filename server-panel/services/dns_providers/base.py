"""Provider-agnostic DNS management interface.

The DNS page talks to whichever provider is active through this contract
only — it never imports cloudflare_service or namecheap_service directly.
That's the whole point of the abstraction: adding Route 53, Porkbun,
GoDaddy, DigitalOcean DNS, etc. later means writing one new class that
implements DNSProvider and registering it in registry.py. Nothing in
routes.py or the template has to change.

Every provider normalizes its records to the same shape so the template
can render them generically:
    {"id": str, "type": str, "name": str, "content": str, "ttl": int,
     "proxied": bool, "priority": int|None}

"proxied" is a Cloudflare-only concept (routing through their edge). For
providers that don't have an equivalent, records simply never set it and
PROXYABLE_TYPES is empty, so the template's existing "—" fallback covers
it with no extra branching.

Domains/zones are normalized to:
    {"id": str, "name": str, "status": str}
"id" is what gets passed back into list_records/create_record/etc. For
Cloudflare that's the zone ID; for Namecheap there's no separate ID, so
the domain name doubles as its own id.
"""
from abc import ABC, abstractmethod


class DNSProviderError(Exception):
    """Raised by any provider on API/auth/network failure. Routes only
    ever need to catch this one type regardless of which provider raised it."""
    pass


class DNSProvider(ABC):
    #: short machine key, e.g. "cloudflare" — used in config keys and URLs
    key = None
    #: human label shown in the provider picker, e.g. "Cloudflare"
    label = None
    #: record types this provider's Add/Edit form should offer
    record_types = ["A", "AAAA", "CNAME", "TXT", "MX", "NS"]
    #: record types that can be toggled through this provider's proxy/edge
    #: feature; empty set means the panel just won't show that control
    proxyable_types = set()
    #: whether this provider supports switching between its own DNS and
    #: externally-hosted nameservers (only Namecheap-style registrars do)
    supports_nameserver_switch = False

    @abstractmethod
    def is_configured(self):
        """True if credentials for this provider are saved."""

    @abstractmethod
    def verify_credentials(self, **creds):
        """Validate credentials against the live API before they're saved.
        Raises DNSProviderError on failure. Does not persist anything —
        that's the route's job once this returns True."""

    @abstractmethod
    def list_domains(self):
        """-> list of {"id", "name", "status"} this account/token can manage."""

    @abstractmethod
    def list_records(self, domain_id):
        """-> list of normalized record dicts for the given domain."""

    @abstractmethod
    def create_record(self, domain_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        pass

    @abstractmethod
    def update_record(self, domain_id, record_id, record_type, name, content, ttl=1, proxied=False, priority=None):
        pass

    @abstractmethod
    def delete_record(self, domain_id, record_id):
        pass

    # --- Optional capability, only meaningful when supports_nameserver_switch ---
    def get_nameserver_mode(self, domain_id):
        """-> {"using_provider_dns": bool, "nameservers": [str, ...]}"""
        raise NotImplementedError

    def use_provider_dns(self, domain_id):
        """Switch the domain back to this provider's own DNS (required
        for record changes made here to actually resolve)."""
        raise NotImplementedError

    def use_custom_nameservers(self, domain_id, nameservers):
        raise NotImplementedError
