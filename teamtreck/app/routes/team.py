from functools import wraps
import secrets
from flask import Blueprint, render_template, redirect, url_for, request, flash, abort
from flask_login import login_required, current_user
from app import db
from app.models.user import User
from app.models.team import Team

team_bp = Blueprint('team', __name__, url_prefix='/team')


def manager_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if not current_user.is_manager:
            abort(403)
        return f(*args, **kwargs)
    return wrapped


@team_bp.route('/')
@login_required
@manager_required
def index():
    members = User.query.filter_by(team_id=current_user.team_id).all()
    team = Team.query.get(current_user.team_id)
    for m in members:
        pass  # is_online is computed on the model
    return render_template('team/index.html', members=members, team=team)


@team_bp.route('/invite-link/generate', methods=['POST'])
@login_required
@manager_required
def generate_invite_link():
    team = Team.query.get(current_user.team_id)
    team.invite_code = secrets.token_urlsafe(12)
    db.session.commit()
    flash('Invite link generated', 'success')
    return redirect(url_for('team.index'))


@team_bp.route('/invite-link/revoke', methods=['POST'])
@login_required
@manager_required
def revoke_invite_link():
    team = Team.query.get(current_user.team_id)
    team.invite_code = None
    db.session.commit()
    flash('Invite link revoked', 'success')
    return redirect(url_for('team.index'))


@team_bp.route('/join/<code>', methods=['GET', 'POST'])
def join(code):
    team = Team.query.filter_by(invite_code=code).first()
    if not team:
        abort(404)

    if request.method == 'POST':
        name = request.form.get('name', '').strip()
        email = request.form.get('email', '').strip().lower()
        password = request.form.get('password', '')

        if not name or not email or not password:
            flash('All fields required', 'error')
            return render_template('team/join.html', team=team, code=code)

        if User.query.filter_by(email=email).first():
            flash('Email already registered', 'error')
            return render_template('team/join.html', team=team, code=code)

        user = User(name=name, email=email, role='employee', team_id=team.id)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()

        from flask_login import login_user
        login_user(user, remember=True)
        return redirect(url_for('main.dashboard'))

    return render_template('team/join.html', team=team, code=code)


@team_bp.route('/invite', methods=['POST'])
@login_required
@manager_required
def invite():
    name = request.form.get('name', '').strip()
    email = request.form.get('email', '').strip().lower()
    role = request.form.get('role', 'employee')
    temp_password = request.form.get('temp_password', 'welcome123')

    if role not in ('admin', 'manager', 'employee'):
        role = 'employee'

    if User.query.filter_by(email=email).first():
        flash('That email is already registered', 'error')
        return redirect(url_for('team.index'))

    user = User(name=name, email=email, role=role, team_id=current_user.team_id)
    user.set_password(temp_password)
    db.session.add(user)
    db.session.commit()
    flash(f'{name} invited with temporary password: {temp_password}', 'success')
    return redirect(url_for('team.index'))


@team_bp.route('/remove/<int:user_id>', methods=['POST'])
@login_required
@manager_required
def remove(user_id):
    user = User.query.get_or_404(user_id)
    if user.team_id != current_user.team_id:
        abort(403)
    if user.id == current_user.id:
        flash("You can't remove yourself", 'error')
        return redirect(url_for('team.index'))
    db.session.delete(user)
    db.session.commit()
    flash('User removed', 'success')
    return redirect(url_for('team.index'))


@team_bp.route('/role/<int:user_id>', methods=['POST'])
@login_required
@manager_required
def change_role(user_id):
    user = User.query.get_or_404(user_id)
    if user.team_id != current_user.team_id:
        abort(403)
    new_role = request.form.get('role')
    if new_role in ('admin', 'manager', 'employee'):
        user.role = new_role
        db.session.commit()
        flash('Role updated', 'success')
    return redirect(url_for('team.index'))
