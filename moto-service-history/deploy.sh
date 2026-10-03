#!/usr/bin/env bash
# Deploy Moto Service History onto a systemd + gunicorn + nginx VPS.
# Run as root. Assumes the project has already been unzipped to $APP_DIR.
set -euo pipefail

APP_DIR="/opt/moto-service-history"
APP_USER="www-data"
SERVICE_NAME="moto-service-history"
DOMAIN="${1:-service.opslabsystems.cloud}"
PORT="8011"

echo "==> Deploying Moto Service History to $DOMAIN (port $PORT)"

if [ "$(pwd)" != "$APP_DIR" ]; then
  mkdir -p "$APP_DIR"
  rsync -a --exclude 'instance/uploads' --exclude '.git' ./ "$APP_DIR"/
fi

cd "$APP_DIR"

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip -q
pip install -r requirements.txt -q

mkdir -p instance/uploads
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

if [ ! -f .env ]; then
  cp .env.example .env
  SECRET=$(python3 -c "import secrets;print(secrets.token_hex(32))")
  sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$SECRET/" .env
  echo "==> Generated .env — set DVSA MOT credentials from Admin > Settings once the app is live, or edit .env now."
fi

set -a
source .env
set +a
export FLASK_APP=wsgi.py
flask db upgrade || echo "==> Migration upgrade skipped/failed — app will still create tables on first boot via create_all()."

cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Moto Service History (gunicorn)
After=network.target

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:${PORT} wsgi:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

cat > /etc/nginx/sites-available/${SERVICE_NAME} <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 30M;

    location /static/ {
        alias ${APP_DIR}/app/static/;
    }

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/${SERVICE_NAME} /etc/nginx/sites-enabled/${SERVICE_NAME}
nginx -t && systemctl reload nginx

echo "==> Done. ${SERVICE_NAME} is live behind nginx on http://${DOMAIN}"
echo "==> Run 'certbot --nginx -d ${DOMAIN}' to add HTTPS."
echo "==> Default admin login: admin / changeme123 — change this immediately."
