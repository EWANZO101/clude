#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Cioda's Commission Site — Full Setup Script
# Run this from /root after uploading cioda-commissions.zip
# Usage: bash setup.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e

DOMAIN="order.ciodrawz.space"
APP_DIR="/root/cioda-commissions"
VENV_DIR="/root/venv"
PORT="5025"
SERVICE_NAME="cioda-commissions"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║       Cioda's Commission Site — Setup            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── 1. Unzip ──────────────────────────────────────────────────────────────────
echo "[ 1/8 ] Unzipping app..."
if [ ! -f "/root/cioda-commissions.zip" ]; then
    echo "ERROR: cioda-commissions.zip not found in /root/"
    echo "Please upload it first, then re-run this script."
    exit 1
fi
cd /root
unzip -o cioda-commissions.zip -d /root > /dev/null
echo "       Done."

# ── 2. Python venv + dependencies ────────────────────────────────────────────
echo "[ 2/8 ] Setting up Python virtual environment..."
apt install -y python3-venv python3-full > /dev/null 2>&1
python3 -m venv "$VENV_DIR" > /dev/null 2>&1
"$VENV_DIR/bin/pip" install --upgrade pip > /dev/null 2>&1
"$VENV_DIR/bin/pip" install flask flask-sqlalchemy requests gunicorn > /dev/null 2>&1
echo "       Done."

# ── 3. Database directory ─────────────────────────────────────────────────────
echo "[ 3/8 ] Creating persistent database directory..."
mkdir -p /root/cioda_data
echo "       Done. (DB will live at /root/cioda_data/commissions.db)"

# ── 4. Run database migrations ────────────────────────────────────────────────
echo "[ 4/8 ] Running database migrations..."
"$VENV_DIR/bin/python3" - << 'PYEOF'
import sqlite3, os

db_path = os.path.expanduser('~/cioda_data/commissions.db')
con = sqlite3.connect(db_path)
cur = con.cursor()

migrations = [
    "ALTER TABLE site_settings ADD COLUMN discord_webhook_status VARCHAR(500) DEFAULT ''",
    "ALTER TABLE site_settings ADD COLUMN discord_webhook_tickets VARCHAR(500) DEFAULT ''",
    "ALTER TABLE \"order\" ADD COLUMN customer_instagram VARCHAR(100) DEFAULT ''",
    "ALTER TABLE \"order\" ADD COLUMN payment_method VARCHAR(50) DEFAULT ''",
    "ALTER TABLE \"order\" ADD COLUMN payment_username VARCHAR(200) DEFAULT ''",
    "ALTER TABLE commission_request ADD COLUMN customer_instagram VARCHAR(100) DEFAULT ''",
    "ALTER TABLE commission_request ADD COLUMN payment_method VARCHAR(50) DEFAULT ''",
    "ALTER TABLE commission_request ADD COLUMN payment_username VARCHAR(200) DEFAULT ''",
]

for sql in migrations:
    try:
        cur.execute(sql)
    except Exception:
        pass  # Column already exists, safe to skip

con.commit()
con.close()
print("       Migrations applied.")
PYEOF

# ── 5. Install nginx ──────────────────────────────────────────────────────────
echo "[ 5/8 ] Installing nginx..."
apt install -y nginx > /dev/null 2>&1
echo "       Done."

# ── 6. Write nginx config ─────────────────────────────────────────────────────
echo "[ 6/8 ] Writing nginx config..."
cat > /etc/nginx/sites-available/$SERVICE_NAME << NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    access_log /var/log/nginx/cioda-commissions.access.log;
    error_log  /var/log/nginx/cioda-commissions.error.log;

    client_max_body_size 16M;

    location /static/ {
        alias $APP_DIR/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location / {
        proxy_pass         http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout    120s;
        proxy_read_timeout    120s;
    }
}
NGINXEOF

# Enable site, disable default
ln -sf /etc/nginx/sites-available/$SERVICE_NAME /etc/nginx/sites-enabled/$SERVICE_NAME
rm -f /etc/nginx/sites-enabled/default

nginx -t > /dev/null 2>&1
systemctl reload nginx
echo "       Done."

# ── 7. SSL certificate ────────────────────────────────────────────────────────
echo "[ 7/8 ] Getting SSL certificate from Let's Encrypt..."
apt install -y certbot python3-certbot-nginx > /dev/null 2>&1
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "cioda@ciodrawz.space" --redirect
echo "       Done."

# ── 8. Systemd service ────────────────────────────────────────────────────────
echo "[ 8/8 ] Setting up systemd service (auto-start on boot)..."
cat > /etc/systemd/system/$SERVICE_NAME.service << SERVICEEOF
[Unit]
Description=Cioda's Commission Site
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
Environment="PATH=$VENV_DIR/bin"
ExecStart=$VENV_DIR/bin/gunicorn -w 4 -b 127.0.0.1:$PORT --timeout 120 app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME
echo "       Done."

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║               Setup Complete! ✓                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Site:   https://$DOMAIN"
echo "  Admin:  https://$DOMAIN/admin"
echo "           Username: ciodrawz"
echo "           Password: ciodrawz2026!11"
echo ""
echo "  Useful commands:"
echo "    Check status:   systemctl status $SERVICE_NAME"
echo "    View logs:      journalctl -u $SERVICE_NAME -f"
echo "    Restart app:    systemctl restart $SERVICE_NAME"
echo "    Nginx logs:     tail -f /var/log/nginx/cioda-commissions.error.log"
echo ""
