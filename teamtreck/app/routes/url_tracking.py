from datetime import datetime, timedelta, date
from collections import defaultdict
from flask import Blueprint, render_template, request, jsonify, abort
from flask_login import login_required, current_user
from app import db
from app.models.user import User
from app.models.url_log import UrlLog, categorize
from urllib.parse import urlparse

url_tracking_bp = Blueprint('url_tracking', __name__, url_prefix='/url-tracking')

PRODUCTIVE_CATEGORIES = {'Research', 'Communication'}
UNPRODUCTIVE_CATEGORIES = {'Social Media', 'Entertainment'}


def _agent_user():
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


@url_tracking_bp.route('/api/log', methods=['POST'])
def api_log_url():
    user = _agent_user()
    if not user:
        return jsonify({'error': 'invalid or missing token'}), 401

    data = _payload()
    url = data.get('url')
    if not url:
        return jsonify({'error': 'url is required'}), 400

    if data.get('private_browsing'):
        return jsonify({'ok': True, 'skipped': 'private browsing not tracked'})

    title = (data.get('title') or '')[:500]
    duration_seconds = int(data.get('duration_seconds', 0) or 0)
    time_entry_id = data.get('time_entry_id') or None
    visited_at_raw = data.get('visited_at')

    try:
        visited_at = datetime.fromisoformat(visited_at_raw) if visited_at_raw else datetime.utcnow()
    except ValueError:
        visited_at = datetime.utcnow()

    domain = urlparse(url).netloc.lower().replace('www.', '')
    category = categorize(url)

    log = UrlLog(
        user_id=user.id,
        time_entry_id=int(time_entry_id) if time_entry_id else None,
        url=url[:1000],
        domain=domain,
        title=title,
        category=category,
        visited_at=visited_at,
        duration_seconds=duration_seconds,
    )
    db.session.add(log)
    db.session.commit()
    return jsonify({'ok': True, 'id': log.id, 'category': category})


@url_tracking_bp.route('/')
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

    today = date.today()
    range_start = today - timedelta(days=6)

    logs = UrlLog.query.filter(
        UrlLog.user_id == view_user.id,
        UrlLog.visited_at >= datetime.combine(range_start, datetime.min.time()),
    ).order_by(UrlLog.visited_at.desc()).all()

    domain_totals = defaultdict(int)
    category_totals = defaultdict(int)
    for log in logs:
        domain_totals[log.domain] += log.duration_seconds
        category_totals[log.category] += log.duration_seconds

    most_visited = sorted(domain_totals.items(), key=lambda x: -x[1])[:10]
    by_category = sorted(category_totals.items(), key=lambda x: -x[1])

    total_seconds = sum(domain_totals.values())
    productive_seconds = sum(secs for cat, secs in category_totals.items() if cat in PRODUCTIVE_CATEGORIES)

    productivity_score = None
    if total_seconds > 0:
        productivity_score = round((productive_seconds / total_seconds) * 100)

    team_members = []
    if current_user.is_manager:
        team_members = User.query.filter_by(team_id=current_user.team_id).all()

    return render_template(
        'url_tracking/index.html',
        view_user=view_user,
        logs=logs[:50],
        most_visited=most_visited,
        by_category=by_category,
        total_seconds=total_seconds,
        productivity_score=productivity_score,
        team_members=team_members,
        range_start=range_start,
        range_end=today,
    )
