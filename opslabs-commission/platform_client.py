"""Client for the OpsLabs Platform's internal API (/api/v1) — subscription visibility
and credit metering for this Commission instance as a platform-managed product.

Deliberately fails OPEN everywhere: a network blip, a platform outage, or a slow
response must never block a real admin from managing real customer orders. Every
function here catches its own exceptions and returns None (or leaves the calling
action to proceed) rather than raising — this is a nice-to-have integration, not a
dependency the business runs on.

Configured via PLATFORM_API_URL and PLATFORM_API_KEY in .env. Both blank (the
default) means the integration is off — every function is a no-op.
"""
import os
import time

import requests

_TIMEOUT = 4  # seconds — short, so a slow/unreachable platform never noticeably stalls an admin action
_CACHE_TTL = 300  # seconds
_cache = {'data': None, 'at': 0}


def _configured():
    return bool(os.environ.get('PLATFORM_API_URL') and os.environ.get('PLATFORM_API_KEY'))


def _headers():
    return {'Authorization': f'Bearer {os.environ.get("PLATFORM_API_KEY", "")}'}


def get_entitlement(use_cache=True):
    """Returns the platform's entitlement dict, or None if the integration isn't
    configured or the platform couldn't be reached — callers must treat None as
    "unknown," not "inactive." Cached for _CACHE_TTL seconds so a dashboard page load
    doesn't hit the platform on every request."""
    if not _configured():
        return None

    if use_cache and _cache['data'] and (time.time() - _cache['at']) < _CACHE_TTL:
        return _cache['data']

    try:
        url = os.environ['PLATFORM_API_URL'].rstrip('/') + '/api/v1/entitlement'
        resp = requests.get(url, headers=_headers(), timeout=_TIMEOUT)
        if resp.status_code != 200:
            return _cache['data']  # stale-but-known beats nothing, if we have it
        data = resp.json()
        _cache['data'] = data
        _cache['at'] = time.time()
        return data
    except requests.RequestException:
        return _cache['data']


def spend_credit(feature_key, reason=None):
    """Best-effort credit spend — never raises, never blocks the caller. Returns the
    new balance on success, or None (integration off, unreachable, or out of credits —
    the caller can't and shouldn't distinguish those cases; the action already happened
    regardless)."""
    if not _configured():
        return None
    try:
        url = os.environ['PLATFORM_API_URL'].rstrip('/') + '/api/v1/spend-credit'
        resp = requests.post(url, headers=_headers(), timeout=_TIMEOUT,
                              json={'feature_key': feature_key, 'reason': reason})
        if resp.status_code == 200:
            return resp.json().get('balance')
    except requests.RequestException:
        pass
    return None
