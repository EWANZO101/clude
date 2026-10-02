from datetime import datetime, timedelta, date
from flask import Blueprint, render_template
from flask_login import login_required, current_user
from app import db
from app.models.user import User
from app.models.project import Project, Task
from app.models.time_entry import TimeEntry

dashboard_bp = Blueprint('dashboard', __name__, url_prefix='/overview')


def _active_entry_for(user_id):
    return TimeEntry.query.filter(
        TimeEntry.user_id == user_id,
        TimeEntry.status.in_(['running', 'paused'])
    ).first()


@dashboard_bp.route('/')
@login_required
def index():
    current_user.touch()
    db.session.commit()

    today = date.today()
    today_start = datetime.combine(today, datetime.min.time())

    my_active = _active_entry_for(current_user.id)
    my_today_entries = TimeEntry.query.filter(
        TimeEntry.user_id == current_user.id,
        TimeEntry.started_at >= today_start,
    ).all()
    my_today_seconds = sum(e.duration_seconds() for e in my_today_entries)

    my_open_tasks = Task.query.filter_by(assigned_to_id=current_user.id).filter(Task.status != 'done').limit(5).all()

    team_snapshot = []
    if current_user.is_manager:
        members = User.query.filter_by(team_id=current_user.team_id).all()
        for m in members:
            active = _active_entry_for(m.id)
            today_entries = TimeEntry.query.filter(
                TimeEntry.user_id == m.id,
                TimeEntry.started_at >= today_start,
            ).all()
            today_secs = sum(e.duration_seconds() for e in today_entries)
            team_snapshot.append({
                'user': m,
                'active': active,
                'today_seconds': today_secs,
                'online': m.is_online,
            })
        team_snapshot.sort(key=lambda x: (not (x['active'] is not None), -x['today_seconds']))

    active_projects = Project.query.filter_by(team_id=current_user.team_id, status='active').limit(6).all()
    project_today = {}
    for p in active_projects:
        secs = sum(
            e.duration_seconds() for e in p.time_entries
            if e.started_at >= today_start
        )
        project_today[p.id] = secs

    return render_template(
        'dashboard_full/index.html',
        my_active=my_active,
        my_today_seconds=my_today_seconds,
        my_open_tasks=my_open_tasks,
        team_snapshot=team_snapshot,
        active_projects=active_projects,
        project_today=project_today,
    )
