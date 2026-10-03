"""Client for the opslabs-phone REST API (runs on the FiveM server)."""
import os

import requests


class PhoneApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


ERRORS = {
    'insufficient_funds': "There isn't enough money in your in-game bank account.",
    'no_account': "We couldn't find a bank account for this character.",
    'no_line': "This phone doesn't have an OPS Mobile line yet.",
    'invalid_plan': 'That plan is not available.',
    'invalid_addon': 'That add-on is not available.',
    'no_active_line': 'You need an active plan before you can add extras.',
    'plan_retired': 'That plan has been retired. Please choose a new plan.',
    'offline': 'The player is not in the city right now.',
    'Phone number not found': "We couldn't find a phone with that number.",
}


def friendly(err):
    return ERRORS.get(getattr(err, 'message', str(err)), getattr(err, 'message', str(err)))


# MySQL sums/decimals can arrive as strings ("1400"); these fields are always numbers
NUMERIC = {'sms', 'seconds', 'data_kb', 'minutes', 'data_mb', 'revenue_total', 'revenue_30d', 'outstanding', 'customers', 'given_30d',
           'line_count', 'unread', 'amount', 'balance_after', 'balance', 'bank', 'cash', 'credit', 'sms_used', 'seconds_used',
           'period_end', 'period_start', 'at', 'price', 'period_days', 'used', 'limit', 'sms_limit', 'minutes_limit', 'data_limit_mb',
           'plan_price', 'active', 'pending', 'expired', 'suspended', 'cancelled', 'sort', 'id', 'line_id'}


def _numbers(v, key=None):
    if isinstance(v, dict):
        return {k: _numbers(x, k) for k, x in v.items()}
    if isinstance(v, list):
        return [_numbers(x, key) for x in v]
    if key in NUMERIC and isinstance(v, str):
        try:
            f = float(v)
            return int(f) if f == int(f) else f
        except ValueError:
            return v
    return v


class PhoneApi:
    def __init__(self, base_url, key, timeout=8):
        self.base = base_url.rstrip('/')
        self.key = key
        self.timeout = timeout
        self.http = requests.Session()
        self.http.headers.update({'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'})

    def call(self, method, path, body=None, params=None):
        try:
            r = self.http.request(method, self.base + path, json=body, params=params, timeout=self.timeout)
        except requests.RequestException:
            raise PhoneApiError(503, 'The city server is offline right now. Please try again shortly.')
        try:
            data = r.json() if r.content else {}
        except ValueError:
            data = {}
        if r.status_code >= 400:
            raise PhoneApiError(r.status_code, data.get('error') or f'HTTP {r.status_code}')
        return _numbers(data.get('data', data))

    # carrier ---------------------------------------------------------------
    def settings(self): return self.call('GET', '/carrier/settings')
    def update_settings(self, **kw): return self.call('PATCH', '/carrier/settings', kw)
    def stats(self): return self.call('GET', '/carrier/stats')
    def plans(self, all=False): return self.call('GET', '/carrier/plans', params={'all': '1'} if all else None)
    def create_plan(self, data): return self.call('POST', '/carrier/plans', data)
    def update_plan(self, plan_id, data): return self.call('PATCH', f'/carrier/plans/{plan_id}', data)
    def retire_plan(self, plan_id): return self.call('DELETE', f'/carrier/plans/{plan_id}')
    def lines(self, search='', status='', limit=50, offset=0):
        return self.call('GET', '/carrier/lines', params={'search': search, 'status': status, 'limit': limit, 'offset': offset})
    def line(self, number):
        info = self.call('GET', f'/carrier/lines/{number}')
        # defaults for fields an older phone resource doesn't send yet
        info.setdefault('balance', {})
        for k in ('bank', 'cash', 'credit'):
            info['balance'].setdefault(k, 0)
        for k in ('credit_log', 'daily', 'events'):
            if not isinstance(info.get(k), list):
                info[k] = []
        info.setdefault('extra', {'sms': 0, 'minutes': 0, 'data_mb': 0})
        if not isinstance(info.get('extra'), dict):
            info['extra'] = {'sms': 0, 'minutes': 0, 'data_mb': 0}
        info.setdefault('carrier', {})
        info['carrier'].setdefault('credit', info['balance']['credit'])
        return info
    def subscribe(self, number, plan, charge=True, auto_renew=True):
        return self.call('POST', f'/carrier/lines/{number}/subscribe', {'plan': plan, 'charge': charge, 'auto_renew': auto_renew})
    def addon(self, number, plan, charge=True): return self.call('POST', f'/carrier/lines/{number}/addon', {'plan': plan, 'charge': charge})
    def action(self, number, action, **kw): return self.call('POST', f'/carrier/lines/{number}/action', {'action': action, **kw})
    def update_line(self, number, data): return self.call('PATCH', f'/carrier/lines/{number}', data)
    def sms(self, number, message): return self.call('POST', '/carrier/sms', {'number': number, 'message': message})
    def credit(self, number): return self.call('GET', f'/carrier/credit/{number}')
    def add_credit(self, number, amount, reason='', actor='admin', quiet=False):
        return self.call('POST', f'/carrier/credit/{number}', {'amount': amount, 'reason': reason, 'actor': actor, 'quiet': quiet})
    def credit_totals(self): return self.call('GET', '/carrier/credit')
    def thread(self, number, since=0): return self.call('GET', f'/carrier/messages/{number}', params={'since': since} if since else None)
    def mark_read(self, number): return self.call('POST', f'/carrier/messages/{number}/read', {})
    def inbox(self, limit=50, offset=0): return self.call('GET', '/carrier/inbox', params={'limit': limit, 'offset': offset})

    # phone -----------------------------------------------------------------
    def health(self): return self.call('GET', '/health')
    def user(self, number): return self.call('GET', f'/users/{number}')
    def balance(self, number): return self.call('GET', f'/users/{number}/balance')


class TowersApi(PhoneApi):
    """opslabs-towers resource (cell towers + Wi-Fi) on the same FiveM server"""
    def live(self): return self.call('GET', '/live')
    def towers(self): return self.call('GET', '/towers')
    def create(self, data): return self.call('POST', '/towers', data)
    def update(self, tower_id, data): return self.call('PATCH', f'/towers/{tower_id}', data)
    def delete(self, tower_id): return self.call('DELETE', f'/towers/{tower_id}')
    def bulk(self, data): return self.call('POST', '/towers/bulk', data)


def towers_from_env():
    return TowersApi(os.environ.get('TOWERS_API_URL', 'http://127.0.0.1:30120/opslabs-towers/api'), os.environ.get('PHONE_API_KEY', ''))


def from_env():
    return PhoneApi(os.environ.get('PHONE_API_URL', 'http://127.0.0.1:30120/opslabs-phone/api/v1'), os.environ.get('PHONE_API_KEY', ''))
