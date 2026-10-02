"""Registry of available DNS providers. Adding a new one (Route 53,
Porkbun, GoDaddy, DigitalOcean DNS, ...) means writing a class that
implements services.dns_providers.base.DNSProvider and adding one line
here — routes.py and the template iterate this dict/list and never need
to know a new provider exists beyond that.
"""
from services.dns_providers.cloudflare_provider import CloudflareProvider
from services.dns_providers.namecheap_provider import NamecheapProvider
from services.dns_providers.godaddy_provider import GoDaddyProvider

_PROVIDERS = {
    "cloudflare": CloudflareProvider(),
    "namecheap": NamecheapProvider(),
    "godaddy": GoDaddyProvider(),
    # "route53": Route53Provider(),
    # "porkbun": PorkbunProvider(),
    # "digitalocean": DigitalOceanDNSProvider(),
}

DEFAULT_PROVIDER = "cloudflare"


def get_provider(key):
    return _PROVIDERS.get(key)


def all_providers():
    """Ordered list for the provider picker UI."""
    return list(_PROVIDERS.values())


def is_valid(key):
    return key in _PROVIDERS

