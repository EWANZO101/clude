from datetime import datetime
from flask import Blueprint, render_template, request, jsonify, redirect, url_for, flash
from flask_login import login_required, current_user
from app import db
from app.models.time_entry import TimeEntry, TimeEntryAudit
from app.models.project import Project, Task

time_bp = Blueprint('time', __name__, url_prefix='/time')


def _log(entry, action, field=None, old=None, new=None):
    audit = TimeEntryAudit(
        time_entry_id=entry.id,
        changed_by_id=current_user.id,
        action=action,
        field_changed=field,
        old_value=str(old) if old is not None else None,
        new_value=str(new) if new is not None else None,
    )
    db.session.add(audit)


def _active_entry():
    return TimeEntry.query.filter(
        TimeEntry.user_id == current_user.id,
        TimeEntry.status.in_(['running', 'paused'])
    ).first()


@time_bp.route('/')
@login_required
def index():
    active = _active_entry()
    projects = Project.query.filter_by(team_id=current_user.team_id, status='active').all()
    tasks = Task.query.join(Project).filter(Project.team_id == current_user.team_id).all()
    recent = TimeEntry.query.filter_by(user_id=current_user.id).order_by(TimeEntry.started_at.desc()).limit(20).all()
    return render_template('time/index.html', active=active, projects=projects, tasks=tasks, recent=recent)


@time_bp.route('/start', methods=['POST'])
@login_required
def start():
    if _active_entry():
        return jsonify({'error': 'A timer is already running'}), 400

    project_id = request.form.get('project_id') or None
    task_id = request.form.get('task_id') or None
    note = request.form.get('note', '')[:500]

    entry = TimeEntry(
        user_id=current_user.id,
        project_id=int(project_id) if project_id else None,
        task_id=int(task_id) if task_id else None,
        started_at=datetime.utcnow(),
        status='running',
        note=note,
    )
    db.session.add(entry)
    db.session.flush()
    _log(entry, 'started')
    db.session.commit()
    return redirect(url_for('time.index'))


@time_bp.route('/pause/<int:entry_id>', methods=['POST'])
@login_required
def pause(entry_id):
    entry = TimeEntry.query.get_or_404(entry_id)
    if entry.user_id != current_user.id or entry.status != 'running':
        return redirect(url_for('time.index'))
    entry.status = 'paused'
    entry.paused_at = datetime.utcnow()
    _log(entry, 'paused')
    db.session.commit()
    return redirect(url_for('time.index'))


@time_bp.route('/resume/<int:entry_id>', methods=['POST'])
@login_required
def resume(entry_id):
    entry = TimeEntry.query.get_or_404(entry_id)
    if entry.user_id != current_user.id or entry.status != 'paused':
        return redirect(url_for('time.index'))
    if entry.paused_at:
        entry.paused_seconds = (entry.paused_seconds or 0) + int((datetime.utcnow() - entry.paused_at).total_seconds())
    entry.paused_at = None
    entry.status = 'running'
    _log(entry, 'resumed')
    db.session.commit()
    return redirect(url_for('time.index'))


@time_bp.route('/stop/<int:entry_id>', methods=['POST'])
@login_required
def stop(entry_id):
    entry = TimeEntry.query.get_or_404(entry_id)
    if entry.user_id != current_user.id or entry.status not in ('running', 'paused'):
        return redirect(url_for('time.index'))
    if entry.status == 'paused' and entry.paused_at:
        entry.paused_seconds = (entry.paused_seconds or 0) + int((datetime.utcnow() - entry.paused_at).total_seconds())
    entry.paused_at = None
    entry.ended_at = datetime.utcnow()
    entry.status = 'stopped'
    _log(entry, 'stopped')
    db.session.commit()
    flash(f'Session logged: {entry.duration_hms()}', 'success')
    return redirect(url_for('time.index'))


@time_bp.route('/status')
@login_required
def status():
    entry = _active_entry()
    if not entry:
        return jsonify({'active': False})
    return jsonify({
        'active': True,
        'id': entry.id,
        'status': entry.status,
        'duration_seconds': entry.duration_seconds(),
        'duration_hms': entry.duration_hms(),
    })


@time_bp.route('/entry/<int:entry_id>/edit', methods=['POST'])
@login_required
def edit_entry(entry_id):
    entry = TimeEntry.query.get_or_404(entry_id)
    if entry.user_id != current_user.id and not current_user.is_manager:
        return redirect(url_for('time.index'))

    new_note = request.form.get('note', '')[:500]
    if new_note != entry.note:
        _log(entry, 'edited', 'note', entry.note, new_note)
        entry.note = new_note

    new_project = request.form.get('project_id') or None
    new_project_id = int(new_project) if new_project else None
    if new_project_id != entry.project_id:
        _log(entry, 'edited', 'project_id', entry.project_id, new_project_id)
        entry.project_id = new_project_id

    db.session.commit()
    flash('Entry updated', 'success')
    return redirect(url_for('time.index'))


@time_bp.route('/entry/<int:entry_id>/delete', methods=['POST'])
@login_required
def delete_entry(entry_id):
    entry = TimeEntry.query.get_or_404(entry_id)
    if entry.user_id != current_user.id and not current_user.is_manager:
        return redirect(url_for('time.index'))
    _log(entry, 'deleted')
    db.session.commit()
    entry_id_val = entry.id
    db.session.delete(entry)
    db.session.commit()
    flash('Entry deleted', 'success')
    return redirect(url_for('time.index'))
