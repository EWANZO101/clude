"""Two-step verification before a connected domain is trusted:

1. DNS resolves at all (catches typos/never-configured records fast, cheaply).
2. An HTTP request to https://<hostname>/.well-known/domain-verify/<token> actually
   reaches THIS app and gets the expected response back. This is the real proof — a
   resolving CNAME alone doesn't confirm traffic is actually routed to us (wrong
   target, Cloudflare proxy misconfigured, etc.), but a successful round-trip through
   the customer's real DNS + Cloudflare + our own routing does. Comparing against a
   fixed Cloudflare IP wouldn't work here — Cloudflare's anycast edge IPs vary and
   aren't something we should hardcode.
"""
import socket

import requests


def dns_resolves(hostname):
    try:
        socket.getaddrinfo(hostname, 443)
        return True
    except socket.gaierror:
        return False


def http_challenge_passes(hostname, verify_token, timeout=10):
    url = f'https://{hostname}/.well-known/domain-verify/{verify_token}'
    try:
        resp = requests.get(url, timeout=timeout)
    except requests.RequestException as e:
        return False, str(e)

    if resp.status_code != 200:
        return False, f'unexpected status {resp.status_code}'
    if resp.text.strip() != verify_token:
        return False, 'unexpected response body'
    return True, None


def check(domain):
    """Runs both checks for a Domain row. Returns (new_status, failure_reason).

    pending -> verified -> active: a single pass promotes pending to verified, but
    getting to active requires passing again on a LATER check (i.e. domain.status was
    already 'verified' or 'active' coming in) — one lucky pass during, say, mid-DNS-
    propagation flapping shouldn't be enough to call it fully active."""
    if not dns_resolves(domain.hostname):
        return 'pending', f'{domain.hostname} doesn\'t resolve yet — DNS may still be propagating.'

    ok, reason = http_challenge_passes(domain.hostname, domain.verify_token)
    if not ok:
        return 'failed', f'DNS resolves but the verification request failed: {reason}'

    if domain.status in ('verified', 'active'):
        return 'active', None
    return 'verified', None
