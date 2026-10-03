"""
Gunicorn config for production. Usage from the project root:
    gunicorn -c deploy/gunicorn_conf.py run:app
"""
import multiprocessing
import os

bind = os.environ.get("GUNICORN_BIND", "127.0.0.1:8000")
workers = int(os.environ.get("GUNICORN_WORKERS", multiprocessing.cpu_count() * 2 + 1))
threads = int(os.environ.get("GUNICORN_THREADS", 2))
worker_class = "gthread"

# Exports/imports run synchronously inside the request, and large
# databases/uploads can take a while — give them room before gunicorn
# kills the worker.
timeout = int(os.environ.get("GUNICORN_TIMEOUT", 1800))
graceful_timeout = 30

accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOG_LEVEL", "info")

# CWD matters for the sqlite/exports/uploads path resolution fallback —
# always run gunicorn from the project root (the systemd unit sets this).
