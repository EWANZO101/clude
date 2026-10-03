"""OPS Mobile store: the carrier website for the opslabs-phone FiveM phone.

Players sign in with their in-game phone number (a code is texted to their
phone), buy an eSIM plan paid from their in-game bank, add extras and manage
their line. Staff manage plans, lines and the network from /admin.
Everything goes through the phone's REST API; the phone resource is the
source of truth.
"""
import functools
import hmac
import os
import re
import secrets
import time
from datetime import datetime, timezone

from dotenv import load_dotenv
from flask import Flask, abort, flash, g, jsonify, redirect, render_template, request, session, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

import store_db  # noqa: E402  (needs SECRET_KEY from .env)
from phoneapi import PhoneApiError, friendly, from_env, towers_from_env  # noqa: E402

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)
app.config.update(
    SECRET_KEY=os.environ['SECRET_KEY'],
    SESSION_COOKIE_SECURE=os.environ.get('COOKIE_SECURE', '1') == '1',
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Lax',
    PERMANENT_SESSION_LIFETIME=60 * 60 * 24 * 14,
)
api = from_env()
towers_api = towers_from_env()
store_db.init()

ADMIN_USER = os.environ.get('ADMIN_USER', 'admin')
ADMIN_PASSWORD = os.environ.get('ADMIN_PASSWORD', '')

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_settings_cache = {'at': 0, 'value': None}


def carrier():
    """carrier settings (name, number...) cached for a minute"""
    if time.time() - _settings_cache['at'] > 60 or not _settings_cache['value']:
        try:
            _settings_cache['value'] = api.settings()
        except PhoneApiError:
            _settings_cache['value'] = _settings_cache['value'] or {'name': 'OPS Mobile', 'number': '6677', 'enabled': True}
        _settings_cache['at'] = time.time()
    return _settings_cache['value']


def csrf_token():
    if '_csrf' not in session:
        session['_csrf'] = secrets.token_urlsafe(24)
    return session['_csrf']


@app.before_request
def check_csrf():
    if request.method in ('POST', 'PATCH', 'PUT', 'DELETE'):
        token = request.form.get('_csrf') or request.headers.get('X-CSRF-Token', '')
        if not token or not hmac.compare_digest(token, session.get('_csrf', '')):
            abort(400, 'Your session expired. Please go back and try again.')


@app.context_processor
def globals_():
    return {'csrf_token': csrf_token, 'carrier': carrier(), 'me': session.get('number'), 'now': time.time()}


@app.template_filter('money')
def money(v):
    try:
        return '$' + f'{int(v):,}'
    except Exception:  # missing / undefined values render as $0
        return '$0'


@app.template_filter('limit')
def limit_filter(v, unit=''):
    if v is None:
        return '—'
    if int(v) < 0:
        return 'Unlimited'
    if unit == 'mb':
        return mb(v)
    return f'{int(v):,}{(" " + unit) if unit else ""}'


@app.template_filter('mb')
def mb(v):
    v = float(v or 0)
    if v >= 1024:
        gb = v / 1024
        return f'{gb:.0f} GB' if gb >= 10 or gb == int(gb) else f'{gb:.1f} GB'
    return f'{v:.0f} MB'


@app.template_filter('date')
def date_filter(ts, fmt='%d %b %Y'):
    if not ts:
        return '—'
    if isinstance(ts, (int, float)):
        d = datetime.fromtimestamp(ts / 1000 if ts > 1e11 else ts, tz=timezone.utc)
    else:
        try:
            d = datetime.fromisoformat(str(ts).replace('Z', '+00:00'))
        except ValueError:
            return str(ts)
    return d.strftime(fmt)


@app.template_filter('pct')
def pct(u):
    if not u or u.get('limit', 0) < 0:
        return 0
    return min(100, round(u.get('used', 0) / max(1, u['limit']) * 100))


@app.template_filter('ago')
def ago(ts):
    if not ts:
        return '—'
    secs = int(time.time() - (ts / 1000 if ts > 1e11 else ts))
    if secs < 0:
        secs = -secs
        for n, label in ((86400, 'day'), (3600, 'hour'), (60, 'minute')):
            if secs >= n:
                k = secs // n
                return f'in {k} {label}{"s" if k > 1 else ""}'
        return 'in under a minute'
    for n, label in ((86400, 'day'), (3600, 'hour'), (60, 'minute')):
        if secs >= n:
            k = secs // n
            return f'{k} {label}{"s" if k > 1 else ""} ago'
    return 'just now'


def normalize_number(raw):
    return re.sub(r'[^0-9]', '', raw or '')[:15]


def login_required(fn):
    @functools.wraps(fn)
    def wrap(*a, **kw):
        if not session.get('number'):
            return redirect(url_for('login', next=request.path))
        return fn(*a, **kw)
    return wrap


def admin_required(fn):
    @functools.wraps(fn)
    def wrap(*a, **kw):
        if not session.get('admin'):
            return redirect(url_for('admin_login', next=request.path))
        return fn(*a, **kw)
    return wrap


def safe_next(target, default):
    return target if target and target.startswith('/') and not target.startswith('//') else default


def plans_split(plans):
    return [p for p in plans if p['kind'] == 'plan'], [p for p in plans if p['kind'] == 'addon']


@app.errorhandler(PhoneApiError)
def api_down(err):
    if request.path.startswith('/admin') and session.get('admin'):
        flash(friendly(err), 'error')
        return render_template('admin/error.html', error=friendly(err)), err.status if err.status >= 400 else 500
    return render_template('error.html', error=friendly(err)), 503 if err.status == 503 else 500


# ---------------------------------------------------------------------------
# public pages
# ---------------------------------------------------------------------------

@app.get('/')
def home():
    try:
        plans, addons = plans_split(api.plans())
    except PhoneApiError:
        plans, addons = [], []
    return render_template('index.html', plans=plans, addons=addons)


@app.get('/plans')
def plans_page():
    plans, addons = plans_split(api.plans())
    return render_template('plans.html', plans=plans, addons=addons)


@app.get('/help')
def help_page():
    return render_template('help.html')


@app.get('/status')
def status_page():
    """public network status, straight from the phone server"""
    started = time.time()
    try:
        health = api.health()
        ms = int((time.time() - started) * 1000)
    except PhoneApiError:
        health, ms = None, None
    try:
        stats = api.stats() if health else None
    except PhoneApiError:
        stats = None
    lines = (stats or {}).get('lines') or {}
    if isinstance(lines, list):
        lines = {}
    return render_template('status.html', health=health, ms=ms, active=lines.get('active', 0), checked=time.time())


@app.route('/login', methods=['GET', 'POST'])
def login():
    nxt = safe_next(request.values.get('next'), url_for('account'))
    if request.method == 'GET':
        return render_template('login.html', next=nxt)
    number = normalize_number(request.form.get('number'))
    if len(number) < 3:
        flash('Enter the phone number shown on your in-game phone.', 'error')
        return render_template('login.html', next=nxt), 400
    ip = request.remote_addr or 'unknown'
    if store_db.recent_sends('n:' + number, 60) >= 1:
        flash('We just sent you a code. Please wait a minute before asking for another one.', 'error')
        return redirect(url_for('verify', next=nxt))
    if store_db.recent_sends('n:' + number, 3600) >= 5 or store_db.recent_sends('ip:' + ip, 3600) >= 15:
        flash('Too many sign-in attempts. Please try again later.', 'error')
        return render_template('login.html', next=nxt), 429
    try:
        user = api.user(number)
    except PhoneApiError as e:
        flash("We couldn't find a phone with that number." if e.status == 404 else friendly(e), 'error')
        return render_template('login.html', next=nxt), 400
    canonical = user['number']
    code = store_db.new_code(canonical)
    api.sms(canonical, f'{code} is your {carrier()["name"]} sign-in code. It expires in 10 minutes. Never share it with anyone.')
    store_db.log_send('n:' + number, 'ip:' + ip)
    session['pending_number'] = canonical
    return redirect(url_for('verify', next=nxt))


@app.route('/login/verify', methods=['GET', 'POST'])
def verify():
    number = session.get('pending_number')
    nxt = safe_next(request.values.get('next'), url_for('account'))
    if not number:
        return redirect(url_for('login'))
    if request.method == 'POST':
        result = store_db.check_code(number, re.sub(r'\D', '', request.form.get('code', '')))
        if result == 'ok':
            session.pop('pending_number', None)
            session['number'] = number
            session.permanent = True
            return redirect(nxt)
        flash({'wrong': "That code isn't right. Check Messages on your phone.",
               'expired': 'That code has expired. Request a new one.',
               'locked': 'Too many wrong codes. Request a new one.'}[result], 'error')
    return render_template('verify.html', number=number, next=nxt)


@app.post('/logout')
def logout():
    session.pop('number', None)
    return redirect(url_for('home'))


# ---------------------------------------------------------------------------
# customer account
# ---------------------------------------------------------------------------

@app.get('/account')
@login_required
def account():
    info = api.line(session['number'])
    plans, addons = plans_split(api.plans())
    return render_template('account.html', info=info, line=info['carrier'].get('line'), plans=plans, addons=addons)


@app.get('/account/usage.json')
@login_required
def account_usage():
    info = api.line(session['number'])
    return jsonify(line=info['carrier'].get('line'), balance=info['balance'])


@app.route('/account/checkout/<code>', methods=['GET', 'POST'])
@login_required
def checkout(code):
    plans = {p['code']: p for p in api.plans()}
    item = plans.get(code)
    if not item:
        abort(404)
    info = api.line(session['number'])
    line = info['carrier'].get('line')
    if request.method == 'POST':
        try:
            if item['kind'] == 'addon':
                api.addon(session['number'], item['code'])
                flash(f'{item["name"]} added to your plan.', 'success')
            else:
                api.subscribe(session['number'], item['code'], auto_renew=request.form.get('auto_renew') == '1')
                flash(f'You are now on {item["name"]}.' + ('' if line and line.get('installed') else ' Install your eSIM below to start using it.'), 'success')
            return redirect(url_for('account'))
        except PhoneApiError as e:
            flash(friendly(e), 'error')
    return render_template('checkout.html', item=item, info=info, line=line)


@app.post('/account/renew')
@login_required
def renew():
    try:
        api.action(session['number'], 'renew')
        flash('Your plan has been renewed.', 'success')
    except PhoneApiError as e:
        flash(friendly(e), 'error')
    return redirect(url_for('account'))


@app.post('/account/auto-renew')
@login_required
def auto_renew():
    on = request.form.get('on') == '1'
    try:
        api.update_line(session['number'], {'auto_renew': on})
        flash('Auto-renew is ' + ('on.' if on else 'off. Your plan will end at the end of this period.'), 'success')
    except PhoneApiError as e:
        flash(friendly(e), 'error')
    return redirect(url_for('account'))


@app.post('/account/send-esim')
@login_required
def send_esim():
    try:
        api.action(session['number'], 'notify')
        flash('Sent! Check the notification on your phone.', 'success')
    except PhoneApiError as e:
        flash('Your phone needs to be in the city to receive it. You can also enter the activation code in Settings > Mobile Service.' if e.message == 'offline' else friendly(e), 'error')
    return redirect(url_for('account'))


@app.post('/account/cancel')
@login_required
def cancel():
    try:
        api.action(session['number'], 'cancel', reason='Cancelled by customer')
        flash('Your line has been cancelled.', 'success')
    except PhoneApiError as e:
        flash(friendly(e), 'error')
    return redirect(url_for('account'))


# ---------------------------------------------------------------------------
# admin
# ---------------------------------------------------------------------------

@app.route('/admin/login', methods=['GET', 'POST'])
def admin_login():
    nxt = safe_next(request.values.get('next'), url_for('admin'))
    if request.method == 'POST':
        ip = request.remote_addr or 'unknown'
        if store_db.recent_sends('admin:' + ip, 600) >= 8:
            flash('Too many attempts. Wait a few minutes.', 'error')
            return render_template('admin/login.html', next=nxt), 429
        user_ok = hmac.compare_digest(request.form.get('username', ''), ADMIN_USER)
        pass_ok = ADMIN_PASSWORD and hmac.compare_digest(request.form.get('password', ''), ADMIN_PASSWORD)
        if user_ok and pass_ok:
            session['admin'] = ADMIN_USER
            store_db.audit(ADMIN_USER, 'login', detail=ip)
            return redirect(nxt)
        store_db.log_send('admin:' + ip)
        flash('Wrong username or password.', 'error')
    return render_template('admin/login.html', next=nxt)


@app.post('/admin/logout')
def admin_logout():
    session.pop('admin', None)
    return redirect(url_for('admin_login'))


@app.get('/admin')
@admin_required
def admin():
    stats = api.stats()
    try:
        health = api.health()
    except PhoneApiError:
        health = None
    recent = api.lines(limit=8)
    try:
        credit = api.credit_totals()
    except PhoneApiError:
        credit = None
    return render_template('admin/dashboard.html', stats=stats, health=health, recent=recent, credit=credit)


PLAN_FORM_FIELDS = ('code', 'kind', 'name', 'description', 'price', 'period_days', 'sms', 'minutes', 'data_mb', 'color', 'sort')


def plan_from_form(f):
    data = {k: f.get(k, '').strip() for k in PLAN_FORM_FIELDS}
    for k in ('price', 'period_days', 'sms', 'minutes', 'data_mb', 'sort'):
        try:
            data[k] = int(float(data[k] or 0))
        except ValueError:
            data[k] = 0
    # allowance fields: "unlimited" checkbox -> -1, data entered in GB
    for k in ('sms', 'minutes', 'data_mb'):
        if f.get(k + '_unlimited') == '1':
            data[k] = -1
    if f.get('data_unit') == 'gb' and f.get('data_mb_unlimited') != '1':
        try:
            data['data_mb'] = int(float(f.get('data_mb') or 0) * 1024)
        except ValueError:
            data['data_mb'] = 0
    data['featured'] = f.get('featured') == '1'
    data['public'] = f.get('public') == '1'
    data['active'] = f.get('active') == '1'
    return data


@app.get('/admin/plans')
@admin_required
def admin_plans():
    plans, addons = plans_split(api.plans(all=True))
    return render_template('admin/plans.html', plans=plans, addons=addons)


@app.route('/admin/plans/new', methods=['GET', 'POST'])
@app.route('/admin/plans/<int:plan_id>', methods=['GET', 'POST'])
@admin_required
def admin_plan(plan_id=None):
    plan = None
    if plan_id:
        plan = next((p for p in api.plans(all=True) if p['id'] == plan_id), None)
        if not plan:
            abort(404)
    if request.method == 'POST':
        data = plan_from_form(request.form)
        try:
            saved = api.update_plan(plan_id, data) if plan_id else api.create_plan(data)
            store_db.audit(session['admin'], 'plan.save', saved['code'], str(data))
            flash(f'{saved["name"]} saved.', 'success')
            return redirect(url_for('admin_plans'))
        except PhoneApiError as e:
            flash(friendly(e), 'error')
            plan = {**(plan or {}), **data}
    return render_template('admin/plan_form.html', plan=plan or {'kind': request.args.get('kind', 'plan'), 'active': True, 'public': True,
                                                                'color': '#0a84ff', 'period_days': 7, 'price': 500, 'sms': 500, 'minutes': 300, 'data_mb': 5120})


@app.post('/admin/plans/<int:plan_id>/retire')
@admin_required
def admin_plan_retire(plan_id):
    api.retire_plan(plan_id)
    store_db.audit(session['admin'], 'plan.retire', str(plan_id))
    flash('Plan retired. Existing customers keep it until their period ends.', 'success')
    return redirect(url_for('admin_plans'))


@app.get('/admin/lines')
@admin_required
def admin_lines():
    q, status = request.args.get('q', ''), request.args.get('status', '')
    page = max(1, int(request.args.get('page', 1) or 1))
    rows = api.lines(search=q, status=status, limit=50, offset=(page - 1) * 50)
    try:
        stats = api.stats()
    except PhoneApiError:
        stats = {'lines': {}}
    counts = stats.get('lines') or {}
    if isinstance(counts, list):  # empty Lua table comes back as []
        counts = {}
    digits = normalize_number(q)
    return render_template('admin/lines.html', rows=rows, q=q, status=status, page=page, counts=counts,
                           total=sum(int(v) for v in counts.values()), revenue=stats.get('revenue_30d', 0),
                           jump=digits if len(digits) >= 4 and not rows else '')


@app.get('/admin/lines/<number>')
@admin_required
def admin_line(number):
    try:
        info = api.line(number)
    except PhoneApiError as e:
        if e.status == 404:
            flash("No phone with that number.", 'error')
            return redirect(url_for('admin_lines'))
        raise
    plans, addons = plans_split(api.plans(all=True))
    thread = load_thread(info['number'])
    return render_template('admin/line.html', info=info, line=info['carrier'].get('line'), plans=plans, addons=addons, thread=thread)


def load_thread(number, since=0, mark=True):
    """texts between the carrier number and this customer (oldest first); opening it marks replies read"""
    try:
        msgs = api.thread(number, since).get('messages') or []
        if mark and any(m['from'] == 'customer' and not m['read'] for m in msgs):
            api.mark_read(number)
        return msgs
    except PhoneApiError:
        return None


@app.get('/admin/lines/<number>/messages.json')
@admin_required
def admin_line_messages(number):
    since = int(request.args.get('since', 0) or 0)
    msgs = load_thread(number, since)
    if msgs is None:
        return jsonify(error='unavailable'), 503
    return jsonify(messages=[{**m, 'html': render_template('admin/_bubble.html', m=m)} for m in msgs])


@app.get('/admin/inbox')
@admin_required
def admin_inbox():
    return render_template('admin/inbox.html', rows=api.inbox(limit=100))


@app.get('/admin/inbox/unread.json')
@admin_required
def admin_unread():
    try:
        return jsonify(unread=sum(int(r.get('unread') or 0) for r in api.inbox(limit=200)))
    except PhoneApiError:
        return jsonify(unread=0)


@app.post('/admin/lines/<number>/<what>')
@admin_required
def admin_line_post(number, what):
    f = request.form
    try:
        if what == 'subscribe':
            api.subscribe(number, f['plan'], charge=f.get('charge') == '1', auto_renew=f.get('auto_renew') == '1')
            msg = 'Plan set.'
        elif what == 'addon':
            api.addon(number, f['plan'], charge=f.get('charge') == '1')
            msg = 'Add-on applied.'
        elif what == 'action':
            api.action(number, f['action'], reason=f.get('reason') or None, charge=f.get('charge', '1') == '1')
            msg = f'Done: {f["action"].replace("_", " ")}.'
        elif what == 'adjust':
            data = {'auto_renew': f.get('auto_renew') == '1'}
            for k in ('extra_sms', 'extra_minutes', 'extra_data_mb'):
                if f.get(k, '') != '':
                    data[k] = int(float(f[k]))
            if f.get('extend_days'):
                info = api.line(number)
                line = info['carrier'].get('line') or {}
                base = max(line.get('period_end') or 0, int(time.time()))
                data['period_end'] = base + int(float(f['extend_days']) * 86400)
            api.update_line(number, data)
            msg = 'Line updated.'
        elif what == 'credit':
            try:
                amount = int(round(float(f.get('amount') or 0)))
            except ValueError:
                amount = 0
            if f.get('direction') == 'remove':
                amount = -abs(amount)
            if amount == 0:
                raise PhoneApiError(400, 'Enter an amount.')
            r = api.add_credit(number, amount, f.get('reason', '').strip(), actor=session['admin'], quiet=f.get('notify') != '1')
            msg = f'{"Added" if amount > 0 else "Removed"} ${abs(amount):,} credit. New balance ${r["balance"]:,}.'
        elif what == 'sms':
            api.sms(number, f['message'])
            if request.headers.get('X-Requested-With') == 'fetch':
                store_db.audit(session['admin'], 'line.sms', number, f['message'][:400])
                return jsonify(ok=True)
            msg = 'Text sent.'
        else:
            abort(404)
        store_db.audit(session['admin'], 'line.' + what, number, str(dict(f.items()))[:400])
        flash(msg, 'success')
    except PhoneApiError as e:
        if request.headers.get('X-Requested-With') == 'fetch':
            return jsonify(error=friendly(e)), 400
        flash(friendly(e), 'error')
    return redirect(url_for('admin_line', number=number) + ('#messages' if what == 'sms' else ''))


@app.route('/admin/settings', methods=['GET', 'POST'])
@admin_required
def admin_settings():
    if request.method == 'POST':
        f = request.form
        data = {'enabled': f.get('enabled') == '1', 'name': f.get('name', '').strip(), 'number': f.get('number', '').strip(),
                'store_url': f.get('store_url', '').strip(), 'starter_plan': f.get('starter_plan') or False, 'society': f.get('society', '').strip() or False}
        api.update_settings(**data)
        _settings_cache['at'] = 0
        store_db.audit(session['admin'], 'settings', detail=str(data))
        flash('Network settings saved. Phones in the city update right away.', 'success')
        return redirect(url_for('admin_settings'))
    plans, _ = plans_split(api.plans(all=True))
    return render_template('admin/settings.html', s=api.settings(), plans=plans)


@app.get('/admin/audit')
@admin_required
def admin_audit():
    return render_template('admin/audit.html', rows=store_db.audit_log(200))


# ---------------------------------------------------------------------------
# admin: live tower map (opslabs-towers)
# ---------------------------------------------------------------------------

@app.get('/admin/towers')
@admin_required
def admin_towers():
    return render_template('admin/towers.html')


@app.get('/admin/towers/live.json')
@admin_required
def admin_towers_live():
    try:
        return jsonify(towers_api.live())
    except PhoneApiError as e:
        return jsonify(error=friendly(e) if e.status != 404 else 'opslabs-towers is not running on the game server.'), 503


TOWER_FIELDS = ('type', 'name', 'x', 'y', 'z', 'range', 'ssid', 'jobs', 'active', 'model', 'notes', 'password')


def tower_body():
    data = request.get_json(silent=True) or {}
    out = {k: data[k] for k in TOWER_FIELDS if k in data}
    for k in ('x', 'y', 'z', 'range'):
        if k in out and out[k] not in (None, ''):
            try:
                out[k] = float(out[k])
            except (TypeError, ValueError):
                out.pop(k)
    return out


@app.post('/admin/towers/api')
@admin_required
def admin_tower_create():
    try:
        body = tower_body()
        body['actor'] = session['admin']
        t = towers_api.create(body)
        store_db.audit(session['admin'], 'tower.create', str(t.get('id')), f"{t.get('type')} {t.get('name')}")
        return jsonify(t)
    except PhoneApiError as e:
        return jsonify(error=friendly(e)), 400


@app.post('/admin/towers/api/bulk')
@admin_required
def admin_tower_bulk():
    data = request.get_json(silent=True) or {}
    action = data.get('action')
    if action not in ('delete', 'offline', 'online'):
        return jsonify(error='Unknown action'), 400
    body = {'action': action}
    if isinstance(data.get('ids'), list):
        body['ids'] = [int(i) for i in data['ids'] if str(i).isdigit()][:1000]
    elif data.get('all'):
        body['all'] = True
        if data.get('type') in ('cell', 'wifi'):
            body['type'] = data['type']
        if data.get('offline'):
            body['offline'] = True
    else:
        return jsonify(error='Nothing selected'), 400
    try:
        r = towers_api.bulk(body)
        store_db.audit(session['admin'], 'tower.bulk_' + action, None, str(body)[:400])
        return jsonify(r)
    except PhoneApiError as e:
        if e.status == 404:
            return jsonify(error='The game server is running an older opslabs-towers. Run “restart opslabs-towers” in the server console, then try again.'), 400
        return jsonify(error=friendly(e)), 400


@app.route('/admin/towers/api/<int:tower_id>', methods=['PATCH', 'DELETE'])
@admin_required
def admin_tower_edit(tower_id):
    try:
        if request.method == 'DELETE':
            towers_api.delete(tower_id)
            store_db.audit(session['admin'], 'tower.delete', str(tower_id))
            return jsonify(ok=True)
        body = tower_body()
        t = towers_api.update(tower_id, body)
        store_db.audit(session['admin'], 'tower.update', str(tower_id), str(body)[:400])
        return jsonify(t)
    except PhoneApiError as e:
        return jsonify(error=friendly(e)), 400


@app.get('/healthz')
def healthz():
    return {'ok': True}


if __name__ == '__main__':
    app.run(port=int(os.environ.get('PORT', 5121)), debug=True)
