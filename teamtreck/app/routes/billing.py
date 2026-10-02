from datetime import datetime, timedelta, date
from functools import wraps
from flask import Blueprint, render_template, request, abort
from flask_login import login_required, current_user
from app.models.project import Client, Project
from app.models.time_entry import TimeEntry
from app.models.user import User

billing_bp = Blueprint('billing', __name__, url_prefix='/billing')


def manager_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if not current_user.is_manager:
            abort(403)
        return f(*args, **kwargs)
    return wrapped


def _parse_date(s, default):
    if not s:
        return default
    try:
        return datetime.strptime(s, '%Y-%m-%d').date()
    except ValueError:
        return default


@billing_bp.route('/')
@login_required
@manager_required
def index():
    today = date.today()
    range_start = _parse_date(request.args.get('start'), today.replace(day=1))
    range_end = _parse_date(request.args.get('end'), today)
    client_id = request.args.get('client_id')

    entries_q = TimeEntry.query.join(User, TimeEntry.user_id == User.id).filter(
        User.team_id == current_user.team_id,
        TimeEntry.started_at >= datetime.combine(range_start, datetime.min.time()),
        TimeEntry.started_at < datetime.combine(range_end + timedelta(days=1), datetime.min.time()),
        TimeEntry.is_billable == True,
        TimeEntry.status == 'stopped',
    )
    entries = entries_q.all()

    # group by client -> project
    client_totals = {}
    for e in entries:
        project = e.project
        client = project.client if project else None
        client_key = client.id if client else 'none'
        client_name = client.name if client else 'No client'
        rate = project.effective_rate() if project else None

        if client_key not in client_totals:
            client_totals[client_key] = {
                'name': client_name,
                'currency': client.currency if client else 'GBP',
                'projects': {},
                'total_seconds': 0,
                'total_amount': 0.0,
            }

        proj_key = project.id if project else 'none'
        proj_name = project.name if project else 'No project'
        if proj_key not in client_totals[client_key]['projects']:
            client_totals[client_key]['projects'][proj_key] = {
                'name': proj_name, 'seconds': 0, 'rate': rate, 'amount': 0.0
            }

        secs = e.duration_seconds()
        client_totals[client_key]['projects'][proj_key]['seconds'] += secs
        client_totals[client_key]['total_seconds'] += secs

        if rate:
            amount = (secs / 3600.0) * rate
            client_totals[client_key]['projects'][proj_key]['amount'] += amount
            client_totals[client_key]['total_amount'] += amount

    if client_id:
        client_totals = {k: v for k, v in client_totals.items() if str(k) == client_id}

    clients = Client.query.filter_by(team_id=current_user.team_id).all()

    return render_template(
        'billing/index.html',
        client_totals=client_totals,
        clients=clients,
        range_start=range_start,
        range_end=range_end,
        filter_client_id=client_id,
    )
