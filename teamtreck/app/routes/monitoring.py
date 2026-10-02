import os
import secrets
import base64
from datetime import datetime
from functools import wraps
from flask import Blueprint, render_template, request, jsonify, redirect, url_for, flash, abort, send_from_directory
from flask_login import login_required, current_user
from app import db
from app.models.user import User
from app.models.monitoring import Screenshot, ActivitySample

monitoring_bp = Blueprint('monitoring', __name__, url_prefix='/monitoring')

SCREENSHOT_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'static', 'uploads', 'screenshots')
os.makedirs(SCREENSHOT_DIR, exist_ok=True)


def manager_required(f):
    @wraps(f)
    def wrapped(*args, **kwargs):
        if not current_user.is_manager:
            abort(403)
        return f(*args, **kwargs)
    return wrapped


def _agent_user():
    """Resolve the agent's User from a Bearer token. Returns None if invalid."""
    auth = request.headers.get('Authorization', '')
    if not auth.startswith('Bearer '):
        return None
    token = auth[len('Bearer '):].strip()
    if not token:
        return None
    return User.query.filter_by(api_token=token).first()


def _payload():
    if request.is_json:
        return request.json or {}
    return request.form


# ---------- Agent-facing ingestion API (token auth, no session) ----------

@monitoring_bp.route('/api/screenshot', methods=['POST'])
def api_upload_screenshot():
    user = _agent_user()
    if not user:
        return jsonify({'error': 'invalid or missing token'}), 401

    data = _payload()
    image_b64 = data.get('image')
    if not image_b64:
        return jsonify({'error': 'missing image (base64) field'}), 400

    time_entry_id = data.get('time_entry_id') or None
    session_id = data.get('session_id')

    try:
        image_bytes = base64.b64decode(image_b64)
    except Exception:
        return jsonify({'error': 'invalid base64 image data'}), 400

    filename = f'{user.id}_{secrets.token_hex(8)}.png'
    filepath = os.path.join(SCREENSHOT_DIR, filename)
    with open(filepath, 'wb') as f:
        f.write(image_bytes)

    shot = Screenshot(
        user_id=user.id,
        time_entry_id=int(time_entry_id) if time_entry_id else None,
        filename=filename,
        captured_at=datetime.utcnow(),
        session_id=session_id,
    )
    db.session.add(shot)
    db.session.commit()
    return jsonify({'ok': True, 'id': shot.id})


@monitoring_bp.route('/api/activity', methods=['POST'])
def api_upload_activity():
    user = _agent_user()
    if not user:
        return jsonify({'error': 'invalid or missing token'}), 401

    data = _payload()
    try:
        window_start = datetime.fromisoformat(data['window_start'])
        window_end = datetime.fromisoformat(data['window_end'])
    except (KeyError, ValueError, TypeError):
        return jsonify({'error': 'window_start and window_end (ISO datetime) required'}), 400

    keyboard_events = int(data.get('keyboard_events', 0) or 0)
    mouse_events = int(data.get('mouse_events', 0) or 0)
    active_seconds = int(data.get('active_seconds', 0) or 0)
    idle_seconds = int(data.get('idle_seconds', 0) or 0)
    time_entry_id = data.get('time_entry_id') or None

    window_secs = max(1, int((window_end - window_start).total_seconds()))
    activity_level = min(100, int((active_seconds / window_secs) * 100))

    sample = ActivitySample(
        user_id=user.id,
        time_entry_id=int(time_entry_id) if time_entry_id else None,
        window_start=window_start,
        window_end=window_end,
        keyboard_events=keyboard_events,
        mouse_events=mouse_events,
        active_seconds=active_seconds,
        idle_seconds=idle_seconds,
        activity_level=activity_level,
    )
    db.session.add(sample)
    db.session.commit()
    return jsonify({'ok': True, 'id': sample.id, 'activity_level': activity_level})


# ---------- Human-facing viewer (session auth, permission-checked) ----------

@monitoring_bp.route('/')
@login_required
def index():
    view_user_id = request.args.get('user_id')

    if view_user_id and int(view_user_id) != current_user.id:
        if not current_user.is_manager:
            abort(403)
        target = User.query.get_or_404(int(view_user_id))
        if target.team_id != current_user.team_id:
            abort(403)
        view_user = target
    else:
        view_user = current_user

    screenshots = Screenshot.query.filter_by(user_id=view_user.id).order_by(Screenshot.captured_at.desc()).limit(60).all()
    activity = ActivitySample.query.filter_by(user_id=view_user.id).order_by(ActivitySample.window_start.desc()).limit(50).all()

    avg_activity = round(sum(a.activity_level for a in activity) / len(activity)) if activity else None

    team_members = []
    if current_user.is_manager:
        team_members = User.query.filter_by(team_id=current_user.team_id).all()

    return render_template(
        'monitoring/index.html',
        view_user=view_user,
        screenshots=screenshots,
        activity=activity,
        avg_activity=avg_activity,
        team_members=team_members,
    )


@monitoring_bp.route('/screenshot/<int:shot_id>/image')
@login_required
def screenshot_image(shot_id):
    shot = Screenshot.query.get_or_404(shot_id)
    if shot.user_id != current_user.id and not current_user.is_manager:
        abort(403)
    if current_user.is_manager and shot.user.team_id != current_user.team_id:
        abort(403)
    return send_from_directory(SCREENSHOT_DIR, shot.filename)


@monitoring_bp.route('/api-token/generate', methods=['POST'])
@login_required
def generate_api_token():
    current_user.api_token = secrets.token_urlsafe(32)
    db.session.commit()
    flash('New agent token generated. Use it in the desktop agent config.', 'success')
    return redirect(url_for('monitoring.index'))


@monitoring_bp.route('/api-token/revoke', methods=['POST'])
@login_required
def revoke_api_token():
    current_user.api_token = None
    db.session.commit()
    flash('Agent token revoked', 'success')
    return redirect(url_for('monitoring.index'))
