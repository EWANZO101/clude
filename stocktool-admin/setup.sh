#!/usr/bin/env bash
# setup.sh -- installs dependencies for the StockTool admin frontend and
# sanity-checks it can actually reach stocktool-api. This app has no
# database or admin account of its own (see README.md) -- everything
# it needs comes from environment variables and a reachable API.
#
# Usage: ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "ERROR: $PYTHON_BIN not found on PATH. Install Python 3.10+ and re-run." >&2
    exit 1
fi

# Self-healing: if a venv exists but is missing its own python3/pip (common
# on minimal images where python3-venv's ensurepip step silently produced
# an incomplete venv, or a partial/interrupted run left one half-built),
# blow it away and recreate rather than silently limping along on a
# broken environment.
if [ -d "venv" ] && { [ ! -x "venv/bin/python3" ] || [ ! -x "venv/bin/pip" ]; }; then
    echo "[SETUP] Existing venv looks broken/incomplete (missing python3 or pip) -- recreating ..."
    rm -rf venv
fi

if [ ! -d "venv" ]; then
    echo "[SETUP] Creating virtual environment (venv) ..."
    "$PYTHON_BIN" -m venv venv
    if [ ! -x "venv/bin/python3" ] || [ ! -x "venv/bin/pip" ]; then
        echo "ERROR: venv creation did not produce a working python3/pip." >&2
        echo "       This usually means the venv/ensurepip module isn't fully installed." >&2
        echo "       Try: apt install python3-venv python3-pip   (Debian/Ubuntu)" >&2
        exit 1
    fi
fi

# Called by explicit path from here on rather than relying on `source
# venv/bin/activate` + bare `python`/`pip` resolving correctly on PATH --
# immune to PATH surprises (systemd Environment= overrides, missing
# `python` alias on the base system, etc.).
VENV_PY="$SCRIPT_DIR/venv/bin/python3"
VENV_PIP="$SCRIPT_DIR/venv/bin/pip"

echo "[SETUP] Installing/upgrading dependencies from requirements.txt ..."
"$VENV_PIP" install --quiet --upgrade pip
"$VENV_PIP" install --quiet -r requirements.txt

echo
echo "============================================================"
echo " StockTool Admin -- setup check"
echo "============================================================"

if [ -z "${SECRET_KEY:-}" ]; then
    echo "[WARN] SECRET_KEY is not set in this shell -- run.py will fall back to"
    echo "       the insecure default. Set it in your systemd unit / .env before"
    echo "       exposing this on a network:"
    echo "         export SECRET_KEY=\$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
else
    echo "[OK] SECRET_KEY is set."
fi

API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:5032}"
echo "[SETUP] Checking connectivity to stocktool-api at $API_BASE_URL ..."
if "$VENV_PY" - "$API_BASE_URL" <<'PYEOF'
import sys
import urllib.request
url = sys.argv[1].rstrip("/") + "/api/auth/me"
try:
    urllib.request.urlopen(url, timeout=5)
except urllib.error.HTTPError as e:
    # Any HTTP response (even 401 "not logged in") proves the API is reachable.
    sys.exit(0)
except Exception as e:
    print(f"  -> {e}")
    sys.exit(1)
PYEOF
then
    echo "[OK] stocktool-api is reachable at $API_BASE_URL."
else
    echo "[WARN] Could not reach stocktool-api at $API_BASE_URL."
    echo "       Set API_BASE_URL to wherever stocktool-api is actually running,"
    echo "       e.g.: export API_BASE_URL=http://127.0.0.1:5032"
    echo "       (This app will still start, but every page will show a"
    echo "       'Could not reach StockTool API' error until this is fixed.)"
fi

echo "============================================================"
echo " Setup complete. Run with: venv/bin/python run.py"
echo "============================================================"
