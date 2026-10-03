#!/usr/bin/env bash
#
# OpsLab Instance Agent — Linux (Ubuntu/Debian) installer.
#
# Run this from inside an extracted copy of the instance_agent project
# (i.e. this script expects agent/, requirements.txt, and service_files/
# to be its siblings — it copies FROM there, it does not download
# anything). See the "distribution" note in PROGRESS for why this isn't
# yet a real `curl | bash` one-liner.
#
# Usage:
#   sudo ./install/install.sh \
#       --admin-url https://admin.opslabsystems.cloud \
#       --registration-token <token from the Admin Panel's enrollment screen>
#
# Safe to re-run: re-running with the machine already registered updates
# the installed Agent code and restarts the service, leaving settings.json
# (identity, previously-applied config) untouched. Re-running without
# --admin-url/--registration-token on a machine that isn't registered yet
# just sets everything up and prints instructions instead of guessing.
set -euo pipefail

INSTALL_DIR="/opt/opslab-agent"
DATA_DIR="/etc/opslab-agent"
SERVICE_USER="opslab-agent"
SERVICE_GROUP="opslab-agent"
SYSTEMD_UNIT_SRC_NAME="opslab-agent.service"
SYSTEMD_UNIT_DEST="/etc/systemd/system/opslab-agent.service"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(dirname -- "$SCRIPT_DIR")"

ADMIN_URL="${OPSLAB_ADMIN_URL:-}"
REGISTRATION_TOKEN="${OPSLAB_REGISTRATION_TOKEN:-}"

log()  { echo "[opslab-agent-install] $*"; }
warn() { echo "[opslab-agent-install] WARNING: $*" >&2; }
die()  { echo "[opslab-agent-install] ERROR: $*" >&2; exit 1; }

# --- arg parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin-url)
            ADMIN_URL="$2"; shift 2 ;;
        --registration-token)
            REGISTRATION_TOKEN="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
        *)
            die "unrecognized argument: $1 (see --help)" ;;
    esac
done

# --- preflight -----------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "must be run as root (try: sudo $0 ...)"

[[ -f "$PROJECT_ROOT/agent/main.py" ]] || die \
    "expected to find agent/main.py next to this script's parent directory " \
    "($PROJECT_ROOT) — run this from inside the extracted instance_agent project"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        ubuntu*|debian*|*:*debian*) : ;;  # supported
        *)
            die "this installer supports Ubuntu/Debian only (detected ID=${ID:-unknown}, " \
                "ID_LIKE=${ID_LIKE:-unknown}) — spec Section 2.2 scopes this Agent to " \
                "Ubuntu/Debian/Windows, and Windows has its own installer under install/windows/" ;;
    esac
else
    die "cannot read /etc/os-release to confirm this is Ubuntu/Debian — refusing to guess"
fi

REINSTALL=false
if [[ -f "$DATA_DIR/settings.json" ]]; then
    REINSTALL=true
    log "Existing installation detected at $DATA_DIR — this will be an upgrade, settings.json is preserved."
fi

# --- 1. system packages --------------------------------------------------
log "Installing/confirming system prerequisites (python3, venv, pip)..."
export DEBIAN_FRONTEND=noninteractive
# Tolerate failures from unrelated third-party apt sources that may already
# be configured on a real machine (Docker, Node, etc.) — a single bad repo
# shouldn't block installing from the ones that matter here. The install
# step below is what actually needs to succeed.
if ! apt-get update -qq; then
    warn "apt-get update reported errors (likely an unrelated third-party repo) — continuing," \
         "since the packages needed here come from the standard Ubuntu/Debian archive."
fi
apt-get install -y -qq python3 python3-venv python3-pip rsync >/dev/null

# --- 2. service account ---------------------------------------------------
if ! getent group "$SERVICE_GROUP" >/dev/null; then
    log "Creating group $SERVICE_GROUP..."
    groupadd --system "$SERVICE_GROUP"
fi
if ! getent passwd "$SERVICE_USER" >/dev/null; then
    log "Creating system user $SERVICE_USER (no login, no home)..."
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        --gid "$SERVICE_GROUP" "$SERVICE_USER"
fi

# --- 3. stop the existing service before touching its files, if present --
if systemctl list-unit-files 2>/dev/null | grep -q '^opslab-agent\.service'; then
    log "Stopping existing opslab-agent service for upgrade..."
    systemctl stop opslab-agent.service || true
fi

# --- 4. install the Agent's own code -------------------------------------
log "Installing Agent code to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
# Only what's needed to run — not tests/, README, or service_files (those
# are installer inputs, not runtime files).
rsync -a --delete \
    --exclude 'tests' --exclude '__pycache__' --exclude '*.pyc' \
    "$PROJECT_ROOT/agent/" "$INSTALL_DIR/agent/"
cp "$PROJECT_ROOT/requirements.txt" "$INSTALL_DIR/requirements.txt"

log "Creating/updating the Agent's virtualenv..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"

chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

# --- 5. data directory (settings, downloads, recovery points) ------------
log "Setting up $DATA_DIR..."
mkdir -p "$DATA_DIR"
chown "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
chmod 750 "$DATA_DIR"

CAN_START=false
if [[ -f "$DATA_DIR/settings.json" ]]; then
    CAN_START=true  # already registered (or at least previously configured) — leave settings.json alone
elif [[ -n "$ADMIN_URL" && -n "$REGISTRATION_TOKEN" ]]; then
    log "Writing initial settings.json with the provided admin URL and enrollment token..."
    # A minimal settings.json — AgentSettings.from_dict() fills in every
    # other field's default the first time agent.main loads it, and
    # identity.ensure_registered() consumes+clears registration_token on
    # first successful run.
    cat > "$DATA_DIR/settings.json" <<JSON
{
  "admin_url": "$ADMIN_URL",
  "registration_token": "$REGISTRATION_TOKEN"
}
JSON
    chown "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR/settings.json"
    chmod 640 "$DATA_DIR/settings.json"  # contains a one-time secret token until first run consumes it
    CAN_START=true
else
    warn "No settings.json exists yet and --admin-url/--registration-token were not both given."
    warn "The service will be installed and enabled, but NOT started, to avoid crash-looping"
    warn "with no way to register. Finish setup with either:"
    warn "  sudo $0 --admin-url <url> --registration-token <token>"
    warn "or by writing $DATA_DIR/settings.json by hand (see settings.example.json), then:"
    warn "  sudo systemctl start opslab-agent"
fi

# --- 6. systemd unit -------------------------------------------------------
log "Installing systemd unit..."
cp "$PROJECT_ROOT/service_files/systemd/$SYSTEMD_UNIT_SRC_NAME" "$SYSTEMD_UNIT_DEST"
systemctl daemon-reload

if [[ "$CAN_START" == true ]]; then
    systemctl enable --now opslab-agent.service
    log "opslab-agent service enabled and started."
    log "Check status with: systemctl status opslab-agent"
    log "Check logs with:   journalctl -u opslab-agent -f"
else
    systemctl enable opslab-agent.service
    log "opslab-agent service installed and enabled (not started — see warnings above)."
fi

if [[ "$REINSTALL" == true ]]; then
    log "Upgrade complete."
else
    log "Install complete."
fi
