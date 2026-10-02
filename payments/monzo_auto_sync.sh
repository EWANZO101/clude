#!/bin/bash
# Runs sync_monzo_once.py every 30 seconds, forever. Intended to run under
# systemd (see monzo-sync.service below) so it survives reboots and restarts
# itself if it ever dies — not meant to be nohup'd by hand.

set -u
PROJECT_DIR="/root/payments"
cd "$PROJECT_DIR"
source .venv/bin/activate
export PYTHONPATH="$PROJECT_DIR"

echo "==> Monzo auto-sync loop starting (every 30s). Ctrl-C to stop."

while true; do
    python "$PROJECT_DIR/sync_monzo_once.py"
    sleep 30
done
