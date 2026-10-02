"""Thin wrapper around the Cloudflare v4 API for the one thing we need: managing a
CNAME record per connected customer domain. https://api.cloudflare.com/#dns-records-for-a-zone
"""
import requests

API_BASE = 'https://api.cloudflare.com/client/v4'


class CloudflareError(Exception):
    pass


def _headers(api_token):
    return {'Authorization': f'Bearer {api_token}', 'Content-Type': 'application/json'}


def create_cname_record(api_token, zone_id, hostname, target, proxied=True):
    """Creates a CNAME record for `hostname` -> `target`. Proxied (orange-cloud) means
    Cloudflare terminates edge TLS for it, which is why the platform's origin doesn't
    need a per-domain cert (see app/domains/routes.py). Returns the Cloudflare record id."""
    resp = requests.post(
        f'{API_BASE}/zones/{zone_id}/dns_records',
        headers=_headers(api_token),
        json={'type': 'CNAME', 'name': hostname, 'content': target,
              'proxied': proxied, 'ttl': 1},  # ttl=1 means "automatic" when proxied
        timeout=15,
    )
    data = resp.json()
    if not data.get('success'):
        raise CloudflareError(f'Failed to create CNAME for {hostname}: {data.get("errors")}')
    return data['result']['id']


def delete_record(api_token, zone_id, record_id):
    resp = requests.delete(
        f'{API_BASE}/zones/{zone_id}/dns_records/{record_id}',
        headers=_headers(api_token), timeout=15,
    )
    data = resp.json()
    if not data.get('success'):
        raise CloudflareError(f'Failed to delete record {record_id}: {data.get("errors")}')


def zone_status(api_token, zone_id):
    """Sanity check the token/zone actually work — used by admin settings, not the
    per-domain flow, so a bad token surfaces immediately rather than on a customer's
    first domain add."""
    resp = requests.get(f'{API_BASE}/zones/{zone_id}', headers=_headers(api_token), timeout=15)
    data = resp.json()
    if not data.get('success'):
        raise CloudflareError(f'Zone check failed: {data.get("errors")}')
    return data['result']
