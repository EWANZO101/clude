#!/bin/bash

set -e

echo "================================="
echo " FIXING REAL NGINX CONFLICTS"
echo "================================="

BACKUP="/root/nginx-before-conflict-fix-$(date +%s)"

mkdir -p "$BACKUP"

cp -a /etc/nginx/sites-enabled "$BACKUP/"

echo "Backup: $BACKUP"


echo
echo "[1] Removing old stocktool duplicate enabled file"

if [ -f /etc/nginx/sites-enabled/stocktool ]; then
    mv /etc/nginx/sites-enabled/stocktool \
    /etc/nginx/sites-backup-stocktool-disabled
fi


echo
echo "[2] Removing stale backup configs from nginx load"

mkdir -p /etc/nginx/sites-backup

mv /etc/nginx/sites-enabled/*.backup.* \
/etc/nginx/sites-backup/ 2>/dev/null || true


echo
echo "[3] Checking web duplicate"

grep -R "server_name.*web.opslabsystems.cloud" \
/etc/nginx/sites-enabled/ || true


echo
echo "[4] nginx test"

nginx -t


echo
echo "[5] Reload"

systemctl reload nginx


echo
echo "DONE"
