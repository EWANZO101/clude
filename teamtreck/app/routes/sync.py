from datetime import datetime
from flask import Blueprint, request, jsonify
from app import db
from app.models.user import User
from app.models.time_entry import TimeEntry, TimeEntryAudit
from app.models.monitoring import ActivitySample
from app.models.url_log import UrlLog, categorize
from urllib.parse import urlparse

sync_bp = Blueprint('sync', __name__, url_prefix='/sync')


def _agent_user():
    auth = request.headers.get('Authorization', '')
    if not auth.startswith('Bearer '):
        return None
    token = auth[len('Bearer '):].strip()
    if not token:
        return None
    return User.query.filter_by(api_token=token).first()


@sync_bp.route('/api/batch', methods=['POST'])
def api_batch_sync():
    """
    Accepts a batch of records the agent queued while offline, applies them in order,
    and returns per-record results so the agent knows what succeeded and can safely
    discard those from its local queue. Designed to be idempotent-friendly: each
    record can carry a client-generated `client_ref` which is echoed back so the
    agent can match results without relying on server-assigned IDs alone.

    Expected JSON body:
    {
      "time_entries": [
        {"client_ref": "...", "started_at": "...", "ended_at": "...", "project_id": null,
         "task_id": null, "note": "...", "is_billable": true}
      ],
      "activity_samples": [
        {"client_ref": "...", "window_start": "...", "window_end": "...",
         "keyboard_events": 0, "mouse_events": 0, "active_seconds": 0, "idle_seconds": 0,
         "time_entry_id": null}
      ],
      "url_logs": [
        {"client_ref": "...", "url": "...", "title": "...", "visited_at": "...",
         "duration_seconds": 0, "time_entry_id": null, "private_browsing": false}
      ]
    }
    """
    user = _agent_user()
    if not user:
        return jsonify({'error': 'invalid or missing token'}), 401

    body = request.json or {}
    results = {'time_entries': [], 'activity_samples': [], 'url_logs': []}

    # --- backfilled time entries (already-completed offline sessions) ---
    for rec in body.get('time_entries', []):
        client_ref = rec.get('client_ref')
        try:
            started_at = datetime.fromisoformat(rec['started_at'])
            ended_at = datetime.fromisoformat(rec['ended_at']) if rec.get('ended_at') else None
        except (KeyError, ValueError):
            results['time_entries'].append({'client_ref': client_ref, 'ok': False, 'error': 'invalid started_at/ended_at'})
            continue

        entry = TimeEntry(
            user_id=user.id,
            project_id=rec.get('project_id') or None,
            task_id=rec.get('task_id') or None,
            started_at=started_at,
            ended_at=ended_at,
            status='stopped' if ended_at else 'running',
            note=(rec.get('note') or '')[:500],
            is_billable=rec.get('is_billable', True),
        )
        db.session.add(entry)
        db.session.flush()

        audit = TimeEntryAudit(
            time_entry_id=entry.id,
            changed_by_id=user.id,
            action='created',
            field_changed='offline_sync',
            new_value='backfilled from offline agent queue',
        )
        db.session.add(audit)

        results['time_entries'].append({'client_ref': client_ref, 'ok': True, 'id': entry.id})

    # --- backfilled activity samples ---
    for rec in body.get('activity_samples', []):
        client_ref = rec.get('client_ref')
        try:
            window_start = datetime.fromisoformat(rec['window_start'])
            window_end = datetime.fromisoformat(rec['window_end'])
        except (KeyError, ValueError):
            results['activity_samples'].append({'client_ref': client_ref, 'ok': False, 'error': 'invalid window_start/window_end'})
            continue

        window_secs = max(1, int((window_end - window_start).total_seconds()))
        active_seconds = int(rec.get('active_seconds', 0) or 0)
        activity_level = min(100, int((active_seconds / window_secs) * 100))

        sample = ActivitySample(
            user_id=user.id,
            time_entry_id=rec.get('time_entry_id') or None,
            window_start=window_start,
            window_end=window_end,
            keyboard_events=int(rec.get('keyboard_events', 0) or 0),
            mouse_events=int(rec.get('mouse_events', 0) or 0),
            active_seconds=active_seconds,
            idle_seconds=int(rec.get('idle_seconds', 0) or 0),
            activity_level=activity_level,
        )
        db.session.add(sample)
        db.session.flush()
        results['activity_samples'].append({'client_ref': client_ref, 'ok': True, 'id': sample.id})

    # --- backfilled URL logs ---
    for rec in body.get('url_logs', []):
        client_ref = rec.get('client_ref')
        if rec.get('private_browsing'):
            results['url_logs'].append({'client_ref': client_ref, 'ok': True, 'skipped': 'private browsing'})
            continue

        url = rec.get('url')
        if not url:
            results['url_logs'].append({'client_ref': client_ref, 'ok': False, 'error': 'missing url'})
            continue

        try:
            visited_at = datetime.fromisoformat(rec['visited_at']) if rec.get('visited_at') else datetime.utcnow()
        except ValueError:
            visited_at = datetime.utcnow()

        domain = urlparse(url).netloc.lower().replace('www.', '')
        log = UrlLog(
            user_id=user.id,
            time_entry_id=rec.get('time_entry_id') or None,
            url=url[:1000],
            domain=domain,
            title=(rec.get('title') or '')[:500],
            category=categorize(url),
            visited_at=visited_at,
            duration_seconds=int(rec.get('duration_seconds', 0) or 0),
        )
        db.session.add(log)
        db.session.flush()
        results['url_logs'].append({'client_ref': client_ref, 'ok': True, 'id': log.id})

    db.session.commit()

    total_ok = sum(1 for group in results.values() for r in group if r.get('ok'))
    total_records = sum(len(group) for group in results.values())

    return jsonify({'ok': True, 'synced': total_ok, 'total': total_records, 'results': results})


@sync_bp.route('/api/ping', methods=['GET'])
def api_ping():
    """Lightweight endpoint the agent can poll to check connectivity before attempting a sync."""
    user = _agent_user()
    if not user:
        return jsonify({'error': 'invalid or missing token'}), 401
    return jsonify({'ok': True, 'server_time': datetime.utcnow().isoformat(), 'user_id': user.id})
