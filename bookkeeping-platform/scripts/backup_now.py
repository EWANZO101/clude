"""Run this from cron/systemd-timer for deployments that don't want the
in-process APScheduler thread (e.g. multi-worker gunicorn):
    */0 2 * * SUN  /path/to/venv/bin/python scripts/backup_now.py
"""
from app import create_app
from app.backups.service import create_backup, apply_retention_policy

app = create_app("production")
with app.app_context():
    backup = create_backup(triggered_by="scheduled")
    apply_retention_policy()
    print(f"Backup {backup.id}: {backup.status}")
