"""
Local offline queue. Every record the agent wants to send gets written here
first (or on send-failure), tagged with a client_ref. A background sync loop
periodically POSTs queued records to /sync/api/batch and clears whatever the
server confirms as received.
"""
import sqlite3
import json
import uuid
import threading
from contextlib import contextmanager
from agent.config import QUEUE_DB, ensure_config_dir

_lock = threading.Lock()


def _connect():
    ensure_config_dir()
    conn = sqlite3.connect(str(QUEUE_DB))
    conn.execute('''
        CREATE TABLE IF NOT EXISTS queue (
            client_ref TEXT PRIMARY KEY,
            record_type TEXT NOT NULL,   -- time_entry | activity_sample | url_log
            payload TEXT NOT NULL,       -- JSON blob matching the server's expected shape
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            attempts INTEGER DEFAULT 0
        )
    ''')
    conn.commit()
    return conn


@contextmanager
def _db():
    with _lock:
        conn = _connect()
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()


def enqueue(record_type, payload):
    """Add a record to the local queue. payload is a dict; client_ref is generated here."""
    client_ref = str(uuid.uuid4())
    payload = dict(payload)
    payload['client_ref'] = client_ref
    with _db() as conn:
        conn.execute(
            'INSERT INTO queue (client_ref, record_type, payload) VALUES (?, ?, ?)',
            (client_ref, record_type, json.dumps(payload)),
        )
    return client_ref


def pending_batch(limit_per_type=50):
    """Returns a dict shaped for POST /sync/api/batch: {time_entries: [...], activity_samples: [...], url_logs: [...]}"""
    type_map = {
        'time_entry': 'time_entries',
        'activity_sample': 'activity_samples',
        'url_log': 'url_logs',
    }
    batch = {'time_entries': [], 'activity_samples': [], 'url_logs': []}
    with _db() as conn:
        for record_type, batch_key in type_map.items():
            rows = conn.execute(
                'SELECT client_ref, payload FROM queue WHERE record_type = ? ORDER BY created_at ASC LIMIT ?',
                (record_type, limit_per_type),
            ).fetchall()
            for client_ref, payload_json in rows:
                batch[batch_key].append(json.loads(payload_json))
    return batch


def clear_confirmed(sync_results):
    """
    sync_results is the `results` dict returned by /sync/api/batch:
    {time_entries: [{client_ref, ok, ...}], activity_samples: [...], url_logs: [...]}
    Removes every record the server confirmed ok=True.
    """
    with _db() as conn:
        for group in sync_results.values():
            for r in group:
                if r.get('ok'):
                    conn.execute('DELETE FROM queue WHERE client_ref = ?', (r['client_ref'],))


def mark_attempt(client_refs):
    if not client_refs:
        return
    with _db() as conn:
        conn.executemany(
            'UPDATE queue SET attempts = attempts + 1 WHERE client_ref = ?',
            [(ref,) for ref in client_refs],
        )


def queue_size():
    with _db() as conn:
        row = conn.execute('SELECT COUNT(*) FROM queue').fetchone()
        return row[0] if row else 0
