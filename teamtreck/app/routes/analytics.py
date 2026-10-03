from datetime import datetime, timedelta, date
from functools import wraps
from collections import defaultdict
from flask import Blueprint, render_template, request, abort
from flask_login import login_required, current_user
from app.models.user import User
from app.models.time_entry import TimeEntry

analytics_bp = Blueprint('analytics', __name__, url_prefix='/analytics')


def manager_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if not current_user.is_manager:
            abort(403)
        return f(*args, **kwargs)
    return wrapped


# thresholds for over/under-load flagging, in hours/day averaged over the period
OVERLOAD_HOURS_PER_DAY = 9.0
UNDERLOAD_HOURS_PER_DAY = 3.0


@analytics_bp.route('/')
@login_required
@manager_required
def index():
    period = request.args.get('period', 'week')  # week, month
    today = date.today()

    if period == 'month':
        range_start = today.replace(day=1)
        # last day of month
        next_month = range_start.replace(day=28) + timedelta(days=4)
        range_end = next_month - timedelta(days=next_month.day)
        bucket_days = 7  # weekly buckets within the month
    else:
        range_start = today - timedelta(days=today.weekday())
        range_end = range_start + timedelta(days=6)
        bucket_days = 1  # daily buckets within the week

    members = User.query.filter_by(team_id=current_user.team_id).all()

    entries = TimeEntry.query.join(User, TimeEntry.user_id == User.id).filter(
        User.team_id == current_user.team_id,
        TimeEntry.started_at >= datetime.combine(range_start, datetime.min.time()),
        TimeEntry.started_at < datetime.combine(range_end + timedelta(days=1), datetime.min.time()),
    ).all()

    # trend buckets (team-wide total seconds per bucket)
    trend = defaultdict(int)
    cursor = range_start
    while cursor <= range_end:
        trend[cursor] = 0
        cursor += timedelta(days=bucket_days)

    per_user_seconds = defaultdict(int)
    per_user_days = defaultdict(set)

    for e in entries:
        secs = e.duration_seconds()
        entry_day = e.started_at.date()

        # bucket assignment
        offset_days = (entry_day - range_start).days
        bucket_index = offset_days // bucket_days
        bucket_key = range_start + timedelta(days=bucket_index * bucket_days)
        if bucket_key in trend:
            trend[bucket_key] += secs
        else:
            trend[bucket_key] = trend.get(bucket_key, 0) + secs

        per_user_seconds[e.user_id] += secs
        per_user_days[e.user_id].add(entry_day)

    trend_sorted = sorted(trend.items())

    # comparisons + workload flags
    comparisons = []
    total_days_in_period = (range_end - range_start).days + 1
    for m in members:
        secs = per_user_seconds.get(m.id, 0)
        active_days = len(per_user_days.get(m.id, set())) or 1
        avg_hours_per_active_day = (secs / 3600.0) / active_days

        flag = 'normal'
        if avg_hours_per_active_day >= OVERLOAD_HOURS_PER_DAY:
            flag = 'overloaded'
        elif secs == 0:
            flag = 'no_activity'
        elif avg_hours_per_active_day <= UNDERLOAD_HOURS_PER_DAY:
            flag = 'underloaded'

        comparisons.append({
            'user': m,
            'total_seconds': secs,
            'active_days': len(per_user_days.get(m.id, set())),
            'avg_hours_per_active_day': round(avg_hours_per_active_day, 1),
            'flag': flag,
        })

    comparisons.sort(key=lambda c: c['total_seconds'], reverse=True)

    team_total_seconds = sum(per_user_seconds.values())

    return render_template(
        'analytics/index.html',
        period=period,
        range_start=range_start,
        range_end=range_end,
        trend=trend_sorted,
        comparisons=comparisons,
        team_total_seconds=team_total_seconds,
        bucket_days=bucket_days,
    )
