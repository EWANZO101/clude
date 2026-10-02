#!/bin/bash
set -e

echo "== OpsLab Server Panel installer =="

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INSTALL_DIR"

echo "-> Installing system packages"
apt update -y
apt install -y python3 python3-venv python3-pip

echo "-> Creating virtualenv"
python3 -m venv venv
source venv/bin/activate

echo "-> Installing Python dependencies"
pip install --upgrade pip
pip install -r requirements.txt

if [ ! -f .env ]; then
  echo "-> Generating .env"
  SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  cat > .env <<ENV
SECRET_KEY=${SECRET}
PANEL_PORT=9500
SESSION_COOKIE_SECURE=false
ENV
fi

mkdir -p database logs

echo "-> Opening firewall port 9500 (if ufw is active)"
if command -v ufw >/dev/null 2>&1; then
  ufw allow 9500/tcp || true
fi

echo "-> Install complete."
echo "Run manually with:  source venv/bin/activate && python app.py"
echo "Or install the systemd service - see systemd/opslab-panel.service"
