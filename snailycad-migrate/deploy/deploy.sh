#!/usr/bin/env bash
# Deploys SnailyCAD Migration Platform on a Linux host (systemd + optional Nginx).
# Run from the project root as root: ./deploy/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

echo "== Deploying from: $PROJECT_DIR"

# --- venv + deps ---------------------------------------------------------
if [ ! -d "venv" ]; then
    python3 -m venv venv
    echo "== venv created"
fi
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q -r requirements.txt
echo "== dependencies installed"

# --- .env ------------------------------------------------------------------
if [ ! -f ".env" ]; then
    cp .env.example .env
    SECRET=$(./venv/bin/python3 -c "import secrets; print(secrets.token_hex(32))")
    sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$SECRET/" .env
    sed -i "s/^FLASK_ENV=.*/FLASK_ENV=production/" .env
    echo "== .env created with a generated SECRET_KEY — review DATABASE_URL/MAIL_* before going live"
else
    echo "== .env already exists, leaving it alone"
fi

# --- db ----------------------------------------------------------------
export FLASK_APP=run.py
export FLASK_ENV=production
mkdir -p instance
if [ ! -d "migrations" ]; then ./venv/bin/flask db init; fi
if [ -z "$(ls -A migrations/versions 2>/dev/null)" ]; then ./venv/bin/flask db migrate -m "initial schema" || true; fi
./venv/bin/flask db upgrade
echo "== database ready"

# --- systemd -----------------------------------------------------------
cp deploy/snailycad-migrate.service /etc/systemd/system/snailycad-migrate.service
cp deploy/snailycad-migrate-cleanup.service /etc/systemd/system/snailycad-migrate-cleanup.service
cp deploy/snailycad-migrate-cleanup.timer /etc/systemd/system/snailycad-migrate-cleanup.timer

# these units assume /root/snailycad-migrate — fix up if deployed elsewhere
sed -i "s#/root/snailycad-migrate#$PROJECT_DIR#g" /etc/systemd/system/snailycad-migrate.service
sed -i "s#/root/snailycad-migrate#$PROJECT_DIR#g" /etc/systemd/system/snailycad-migrate-cleanup.service

systemctl daemon-reload
systemctl enable --now snailycad-migrate.service
systemctl enable --now snailycad-migrate-cleanup.timer
echo "== systemd services enabled and started"

# --- nginx (optional) ----------------------------------------------------
read -p "Install Nginx reverse proxy config? [y/N] " -n 1 -r INSTALL_NGINX
echo
if [[ "$INSTALL_NGINX" =~ ^[Yy]$ ]]; then
    read -p "Domain name (e.g. cloudloader.example.com): " DOMAIN
    cp deploy/nginx.conf.example "/etc/nginx/sites-available/snailycad-migrate"
    sed -i "s/cloudloader.example.com/$DOMAIN/g" "/etc/nginx/sites-available/snailycad-migrate"
    sed -i "s#/root/snailycad-migrate#$PROJECT_DIR#g" "/etc/nginx/sites-available/snailycad-migrate"
    ln -sf "/etc/nginx/sites-available/snailycad-migrate" "/etc/nginx/sites-enabled/snailycad-migrate"
    nginx -t && systemctl reload nginx
    echo "== Nginx site installed for $DOMAIN"
    echo "== Run: certbot --nginx -d $DOMAIN   (to get TLS)"
fi

echo ""
echo "== Deploy complete."
echo "== Create your first admin: ./venv/bin/flask create-admin"
echo "== Check status: systemctl status snailycad-migrate"
