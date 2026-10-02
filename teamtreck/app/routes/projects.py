from functools import wraps
from flask import Blueprint, render_template, request, redirect, url_for, flash, abort
from flask_login import login_required, current_user
from app import db
from app.models.project import Project, Client, Task
from app.models.time_entry import TimeEntry

projects_bp = Blueprint('projects', __name__, url_prefix='/projects')


def manager_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if not current_user.is_manager:
            abort(403)
        return f(*args, **kwargs)
    return wrapped


@projects_bp.route('/')
@login_required
def index():
    projects = Project.query.filter_by(team_id=current_user.team_id).order_by(Project.created_at.desc()).all()
    project_stats = {}
    for p in projects:
        total_secs = sum(e.duration_seconds() for e in p.time_entries)
        project_stats[p.id] = total_secs
    clients = Client.query.filter_by(team_id=current_user.team_id).all()
    return render_template('projects/index.html', projects=projects, project_stats=project_stats, clients=clients)


@projects_bp.route('/create', methods=['POST'])
@login_required
@manager_required
def create():
    name = request.form.get('name', '').strip()
    description = request.form.get('description', '').strip()
    client_id = request.form.get('client_id') or None
    hourly_rate = request.form.get('hourly_rate') or None

    if not name:
        flash('Project name required', 'error')
        return redirect(url_for('projects.index'))

    project = Project(
        name=name,
        description=description,
        team_id=current_user.team_id,
        client_id=int(client_id) if client_id else None,
        hourly_rate=float(hourly_rate) if hourly_rate else None,
    )
    db.session.add(project)
    db.session.commit()
    flash('Project created', 'success')
    return redirect(url_for('projects.index'))


@projects_bp.route('/<int:project_id>')
@login_required
def detail(project_id):
    project = Project.query.get_or_404(project_id)
    if project.team_id != current_user.team_id:
        abort(403)
    tasks = Task.query.filter_by(project_id=project.id).all()
    task_stats = {}
    for t in tasks:
        task_stats[t.id] = sum(e.duration_seconds() for e in t.time_entries)
    total_secs = sum(e.duration_seconds() for e in project.time_entries)
    return render_template('projects/detail.html', project=project, tasks=tasks, task_stats=task_stats, total_secs=total_secs)


@projects_bp.route('/<int:project_id>/archive', methods=['POST'])
@login_required
@manager_required
def archive(project_id):
    project = Project.query.get_or_404(project_id)
    if project.team_id != current_user.team_id:
        abort(403)
    project.status = 'archived' if project.status == 'active' else 'active'
    db.session.commit()
    flash('Project status updated', 'success')
    return redirect(url_for('projects.index'))


@projects_bp.route('/<int:project_id>/delete', methods=['POST'])
@login_required
@manager_required
def delete(project_id):
    project = Project.query.get_or_404(project_id)
    if project.team_id != current_user.team_id:
        abort(403)
    Task.query.filter_by(project_id=project.id).update({'project_id': None})
    TimeEntry.query.filter_by(project_id=project.id).update({'project_id': None})
    db.session.delete(project)
    db.session.commit()
    flash('Project deleted', 'success')
    return redirect(url_for('projects.index'))


@projects_bp.route('/<int:project_id>/tasks/create', methods=['POST'])
@login_required
def create_task(project_id):
    project = Project.query.get_or_404(project_id)
    if project.team_id != current_user.team_id:
        abort(403)
    name = request.form.get('name', '').strip()
    assigned_to_id = request.form.get('assigned_to_id') or None
    if not name:
        flash('Task name required', 'error')
        return redirect(url_for('projects.detail', project_id=project_id))
    task = Task(
        name=name,
        project_id=project.id,
        assigned_to_id=int(assigned_to_id) if assigned_to_id else None,
    )
    db.session.add(task)
    db.session.commit()
    flash('Task created', 'success')
    return redirect(url_for('projects.detail', project_id=project_id))


@projects_bp.route('/tasks/<int:task_id>/status', methods=['POST'])
@login_required
def update_task_status(task_id):
    task = Task.query.get_or_404(task_id)
    if task.project and task.project.team_id != current_user.team_id:
        abort(403)
    new_status = request.form.get('status')
    if new_status in ('open', 'in_progress', 'done'):
        task.status = new_status
        db.session.commit()
    return redirect(url_for('projects.detail', project_id=task.project_id))


@projects_bp.route('/tasks/<int:task_id>/delete', methods=['POST'])
@login_required
@manager_required
def delete_task(task_id):
    task = Task.query.get_or_404(task_id)
    project_id = task.project_id
    if task.project and task.project.team_id != current_user.team_id:
        abort(403)
    TimeEntry.query.filter_by(task_id=task.id).update({'task_id': None})
    db.session.delete(task)
    db.session.commit()
    flash('Task deleted', 'success')
    return redirect(url_for('projects.detail', project_id=project_id))


@projects_bp.route('/clients/create', methods=['POST'])
@login_required
@manager_required
def create_client():
    name = request.form.get('client_name', '').strip()
    contact_email = request.form.get('contact_email', '').strip()
    hourly_rate = request.form.get('client_hourly_rate') or None
    currency = request.form.get('currency', 'GBP')
    if not name:
        flash('Client name required', 'error')
        return redirect(url_for('projects.index'))
    client = Client(
        name=name,
        team_id=current_user.team_id,
        contact_email=contact_email,
        hourly_rate=float(hourly_rate) if hourly_rate else None,
        currency=currency,
    )
    db.session.add(client)
    db.session.commit()
    flash('Client created', 'success')
    return redirect(url_for('projects.index'))
