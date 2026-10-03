from datetime import datetime, timedelta, date
from functools import wraps
from collections import defaultdict
from flask import Blueprint, render_template, request, abort
from flask_login import login_required, current_user
from app.models.user import User
from app.models.project import Project, Task
from app.models.time_entry import TimeEntry

planning_bp = Blueprint('planning', __name__, url_prefix='/planning')

CAPACITY_HOURS_PER_WEEK = 40.0  # standard full-time baseline used for capacity comparison
BOTTLENECK_TASK_MULTIPLIER = 2.0  # a task taking > 2x the project's average task time is flagged


def manager_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if not current_user.is_manager:
            abort(403)
        return f(*args, **kwargs)
    return wrapped


def _hms(seconds):
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    return f'{h:02d}:{m:02d}:{s:02d}'


@planning_bp.route('/')
@login_required
@manager_required
def index():
    team_id = current_user.team_id

    # --- Task duration estimates: average completed-task time per project, used to
    # project how long open/in-progress tasks might still take ---
    projects = Project.query.filter_by(team_id=team_id, status='active').all()
    project_estimates = []
    for p in projects:
        done_tasks = [t for t in p.tasks if t.status == 'done']
        done_durations = []
        for t in done_tasks:
            secs = sum(e.duration_seconds() for e in t.time_entries)
            if secs > 0:
                done_durations.append(secs)

        avg_secs = sum(done_durations) / len(done_durations) if done_durations else None

        open_tasks = [t for t in p.tasks if t.status != 'done']
        estimated_remaining = avg_secs * len(open_tasks) if avg_secs else None

        project_estimates.append({
            'project': p,
            'completed_task_count': len(done_tasks),
            'avg_task_seconds': avg_secs,
            'open_task_count': len(open_tasks),
            'estimated_remaining_seconds': estimated_remaining,
        })

    # --- Capacity: current week tracked hours vs standard baseline per employee ---
    today = date.today()
    week_start = today - timedelta(days=today.weekday())
    week_end = week_start + timedelta(days=6)

    members = User.query.filter_by(team_id=team_id).all()
    entries = TimeEntry.query.join(User, TimeEntry.user_id == User.id).filter(
        User.team_id == team_id,
        TimeEntry.started_at >= datetime.combine(week_start, datetime.min.time()),
        TimeEntry.started_at < datetime.combine(week_end + timedelta(days=1), datetime.min.time()),
    ).all()

    per_user_secs = defaultdict(int)
    for e in entries:
        per_user_secs[e.user_id] += e.duration_seconds()

    capacity = []
    for m in members:
        secs = per_user_secs.get(m.id, 0)
        hours = secs / 3600.0
        pct = round((hours / CAPACITY_HOURS_PER_WEEK) * 100) if CAPACITY_HOURS_PER_WEEK else 0
        spare_hours = round(CAPACITY_HOURS_PER_WEEK - hours, 1)
        capacity.append({
            'user': m,
            'hours': round(hours, 1),
            'pct_of_baseline': pct,
            'spare_hours': spare_hours if spare_hours > 0 else 0,
        })
    capacity.sort(key=lambda c: -c['pct_of_baseline'])

    # --- Bottleneck detection: tasks taking much longer than the project's own average ---
    bottlenecks = []
    for est in project_estimates:
        if not est['avg_task_seconds']:
            continue
        for t in est['project'].tasks:
            secs = sum(e.duration_seconds() for e in t.time_entries)
            if secs > est['avg_task_seconds'] * BOTTLENECK_TASK_MULTIPLIER:
                bottlenecks.append({
                    'task': t,
                    'project': est['project'],
                    'seconds': secs,
                    'project_avg_seconds': est['avg_task_seconds'],
                })
    bottlenecks.sort(key=lambda b: -b['seconds'])

    return render_template(
        'planning/index.html',
        project_estimates=project_estimates,
        capacity=capacity,
        bottlenecks=bottlenecks,
        week_start=week_start,
        week_end=week_end,
        capacity_baseline=CAPACITY_HOURS_PER_WEEK,
    )
