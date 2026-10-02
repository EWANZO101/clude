from datetime import datetime, timedelta, date
from flask import Blueprint, render_template, request
from flask_login import login_required, current_user
from app.models.time_entry import TimeEntry
from app.models.user import User
from app.models.project import Project, Task

timesheets_bp = Blueprint('timesheets', __name__, url_prefix='/timesheets')


def _parse_date(s, default):
    if not s:
        return default
    try:
        return datetime.strptime(s, '%Y-%m-%d').date()
    except ValueError:
        return default


def _week_bounds(d):
    start = d - timedelta(days=d.weekday())
    end = start + timedelta(days=6)
    return start, end


def _find_gaps_overlaps(entries):
    """entries: sorted list of TimeEntry with ended_at set. Returns (gaps, overlaps) as list of tuples."""
    gaps = []
    overlaps = []
    sorted_entries = sorted([e for e in entries if e.ended_at], key=lambda e: e.started_at)
    for i in range(1, len(sorted_entries)):
        prev = sorted_entries[i - 1]
        curr = sorted_entries[i]
        if curr.started_at > prev.ended_at:
            gap_secs = (curr.started_at - prev.ended_at).total_seconds()
            if gap_secs > 60:
                gaps.append((prev.ended_at, curr.started_at, gap_secs))
        elif curr.started_at < prev.ended_at:
            overlaps.append((prev, curr))
    return gaps, overlaps


@timesheets_bp.route('/')
@login_required
def index():
    view = request.args.get('view', 'week')  # day, week, range
    today = date.today()

    if view == 'day':
        day = _parse_date(request.args.get('date'), today)
        range_start, range_end = day, day
    elif view == 'range':
        range_start = _parse_date(request.args.get('start'), today - timedelta(days=6))
        range_end = _parse_date(request.args.get('end'), today)
    else:
        anchor = _parse_date(request.args.get('date'), today)
        range_start, range_end = _week_bounds(anchor)

    # filters
    filter_user_id = request.args.get('user_id')
    filter_project_id = request.args.get('project_id')
    filter_task_id = request.args.get('task_id')

    query = TimeEntry.query.filter(
        TimeEntry.started_at >= datetime.combine(range_start, datetime.min.time()),
        TimeEntry.started_at < datetime.combine(range_end + timedelta(days=1), datetime.min.time()),
    )

    if current_user.is_manager:
        query = query.join(User, TimeEntry.user_id == User.id).filter(User.team_id == current_user.team_id)
        if filter_user_id:
            query = query.filter(TimeEntry.user_id == int(filter_user_id))
    else:
        query = query.filter(TimeEntry.user_id == current_user.id)

    if filter_project_id:
        query = query.filter(TimeEntry.project_id == int(filter_project_id))
    if filter_task_id:
        query = query.filter(TimeEntry.task_id == int(filter_task_id))

    entries = query.order_by(TimeEntry.started_at.asc()).all()

    total_seconds = sum(e.duration_seconds() for e in entries)

    # group by day for calendar-style view
    by_day = {}
    for e in entries:
        key = e.started_at.date()
        by_day.setdefault(key, []).append(e)

    gaps, overlaps = _find_gaps_overlaps(entries)

    team_members = User.query.filter_by(team_id=current_user.team_id).all() if current_user.is_manager else []
    projects = Project.query.filter_by(team_id=current_user.team_id).all()
    tasks = Task.query.join(Project).filter(Project.team_id == current_user.team_id).all()

    return render_template(
        'timesheets/index.html',
        view=view,
        range_start=range_start,
        range_end=range_end,
        entries=entries,
        by_day=sorted(by_day.items()),
        total_seconds=total_seconds,
        gaps=gaps,
        overlaps=overlaps,
        team_members=team_members,
        projects=projects,
        tasks=tasks,
        filter_user_id=filter_user_id,
        filter_project_id=filter_project_id,
        filter_task_id=filter_task_id,
    )


def format_hms(seconds):
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    return f'{h:02d}:{m:02d}:{s:02d}'
