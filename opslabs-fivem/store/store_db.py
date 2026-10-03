"""Small local database for the store: sign-in codes and the admin audit log."""
import hashlib
import hmac
import os
import secrets
import sqlite3
import time

DB_PATH = os.path.join(os.path.dirname(__file__), 'instance', 'store.db')


def connect():
    db = sqlite3.connect(DB_PATH, timeout=10)
    db.row_factory = sqlite3.Row
    return db


def init():
    with connect() as db:
        db.executescript('''
            CREATE TABLE IF NOT EXISTS login_codes (
                number TEXT PRIMARY KEY, code_hash TEXT NOT NULL, expires INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0, sent_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS send_log (key TEXT NOT NULL, at INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS send_log_key ON send_log (key, at);
            CREATE TABLE IF NOT EXISTS audit (
                id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, actor TEXT NOT NULL,
                action TEXT NOT NULL, target TEXT, detail TEXT);
        ''')


def _hash(code, number):
    return hmac.new(os.environ['SECRET_KEY'].encode(), f'{number}:{code}'.encode(), hashlib.sha256).hexdigest()


def recent_sends(key, window):
    with connect() as db:
        db.execute('DELETE FROM send_log WHERE at < ?', (int(time.time()) - 3600,))
        return db.execute('SELECT COUNT(*) FROM send_log WHERE key = ? AND at > ?', (key, int(time.time()) - window)).fetchone()[0]


def log_send(*keys):
    with connect() as db:
        db.executemany('INSERT INTO send_log (key, at) VALUES (?, ?)', [(k, int(time.time())) for k in keys])


def new_code(number):
    code = f'{secrets.randbelow(1000000):06d}'
    with connect() as db:
        db.execute('REPLACE INTO login_codes (number, code_hash, expires, attempts, sent_at) VALUES (?, ?, ?, 0, ?)',
                   (number, _hash(code, number), int(time.time()) + 600, int(time.time())))
    return code


def check_code(number, code):
    """returns 'ok', 'wrong', 'expired' or 'locked'"""
    with connect() as db:
        row = db.execute('SELECT * FROM login_codes WHERE number = ?', (number,)).fetchone()
        if not row or row['expires'] < time.time():
            return 'expired'
        if row['attempts'] >= 5:
            return 'locked'
        if hmac.compare_digest(row['code_hash'], _hash(code.strip(), number)):
            db.execute('DELETE FROM login_codes WHERE number = ?', (number,))
            return 'ok'
        db.execute('UPDATE login_codes SET attempts = attempts + 1 WHERE number = ?', (number,))
        return 'wrong'


def audit(actor, action, target=None, detail=None):
    with connect() as db:
        db.execute('INSERT INTO audit (at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?)',
                   (int(time.time()), actor, action, target, (detail or '')[:500]))


def audit_log(limit=100):
    with connect() as db:
        return [dict(r) for r in db.execute('SELECT * FROM audit ORDER BY id DESC LIMIT ?', (limit,))]
