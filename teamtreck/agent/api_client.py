"""
Thin HTTP client for the TeamTreck server. Every write goes through here.
On network failure, writes are queued locally instead of raising, so the
rest of the agent doesn't need to know or care whether the server is up.
"""
import requests
from agent.config import load_config
from agent import local_queue

DEFAULT_TIMEOUT = 8


class ApiClient:
    def __init__(self):
        self.cfg = load_config()

    def _headers(self):
        return {'Authorization': f"Bearer {self.cfg['api_token']}"}

    def _base(self):
        return self.cfg['server_url'].rstrip('/')

    def reload_config(self):
        self.cfg = load_config()

    # ---------- connectivity ----------

    def ping(self):
        try:
            r = requests.get(f'{self._base()}/sync/api/ping', headers=self._headers(), timeout=DEFAULT_TIMEOUT)
            return r.status_code == 200
        except requests.RequestException:
            return False

    # ---------- immediate (non-queued) calls: timer control needs a live response ----------

    def start_timer(self, project_id=None, task_id=None, note=''):
        return self._post_form('/time/start', {
            'project_id': project_id or '', 'task_id': task_id or '', 'note': note,
        })

    def pause_timer(self, entry_id):
        return self._post_form(f'/time/pause/{entry_id}', {})

    def resume_timer(self, entry_id):
        return self._post_form(f'/time/resume/{entry_id}', {})

    def stop_timer(self, entry_id):
        return self._post_form(f'/time/stop/{entry_id}', {})

    def timer_status(self):
        try:
            r = requests.get(f'{self._base()}/time/status', headers=self._headers(), timeout=DEFAULT_TIMEOUT)
            if r.status_code == 200:
                return r.json()
        except requests.RequestException:
            pass
        return {'active': False, 'offline': True}

    def _post_form(self, path, data):
        try:
            r = requests.post(f'{self._base()}{path}', data=data, headers=self._headers(), timeout=DEFAULT_TIMEOUT, allow_redirects=False)
            return r.status_code in (200, 302)
        except requests.RequestException:
            return False

    # ---------- queued writes: screenshots, activity, url logs, backfilled time entries ----------
    # These always succeed locally (enqueue) even if the network call fails; the sync
    # loop drains the queue independently. Callers don't need to handle failure.

    def upload_screenshot(self, image_b64, time_entry_id=None, session_id=None):
        payload = {'image': image_b64, 'time_entry_id': time_entry_id, 'session_id': session_id}
        try:
            r = requests.post(f'{self._base()}/monitoring/api/screenshot', json=payload,
                               headers=self._headers(), timeout=DEFAULT_TIMEOUT)
            if r.status_code == 200:
                return True
        except requests.RequestException:
            pass
        # screenshots aren't queued locally (too large for the lightweight sync queue) -
        # they're simply dropped on failure and the next interval tries a fresh capture
        return False

    def log_activity(self, window_start_iso, window_end_iso, keyboard_events, mouse_events,
                      active_seconds, idle_seconds, time_entry_id=None):
        payload = {
            'window_start': window_start_iso, 'window_end': window_end_iso,
            'keyboard_events': keyboard_events, 'mouse_events': mouse_events,
            'active_seconds': active_seconds, 'idle_seconds': idle_seconds,
            'time_entry_id': time_entry_id,
        }
        try:
            r = requests.post(f'{self._base()}/monitoring/api/activity', json=payload,
                               headers=self._headers(), timeout=DEFAULT_TIMEOUT)
            if r.status_code == 200:
                return True
        except requests.RequestException:
            pass
        local_queue.enqueue('activity_sample', payload)
        return False

    def log_url(self, url, title='', duration_seconds=0, visited_at_iso=None,
                time_entry_id=None, private_browsing=False):
        if private_browsing:
            return True  # never sent, never queued
        payload = {
            'url': url, 'title': title, 'duration_seconds': duration_seconds,
            'visited_at': visited_at_iso, 'time_entry_id': time_entry_id,
        }
        try:
            r = requests.post(f'{self._base()}/url-tracking/api/log', json=payload,
                               headers=self._headers(), timeout=DEFAULT_TIMEOUT)
            if r.status_code == 200:
                return True
        except requests.RequestException:
            pass
        local_queue.enqueue('url_log', payload)
        return False

    # ---------- batch sync of everything queued ----------

    def sync_queue(self):
        batch = local_queue.pending_batch()
        if not any(batch.values()):
            return {'synced': 0, 'total': 0}
        try:
            r = requests.post(f'{self._base()}/sync/api/batch', json=batch,
                               headers=self._headers(), timeout=30)
            if r.status_code == 200:
                data = r.json()
                local_queue.clear_confirmed(data['results'])
                return {'synced': data['synced'], 'total': data['total']}
        except requests.RequestException:
            pass
        return {'synced': 0, 'total': sum(len(v) for v in batch.values()), 'error': 'sync failed, will retry'}
