#!/usr/bin/env bash
# OpsLab Migrate launcher — creates a venv, installs deps, runs the tool.
set -euo pipefail
cd "$(dirname "$0")"

PY=python3
command -v "$PY" >/dev/null || { echo "python3 not found"; exit 1; }

if [ ! -d .venv ]; then
    echo "→ Creating virtual environment"
    "$PY" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt

exec python migrate.py "$@"
