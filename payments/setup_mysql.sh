#!/bin/bash
# One-time MySQL setup for a real, persistent deployment.
#
# Creates a dedicated database + user for the app and prints the
# DATABASE_URL to put in your .env file. Run this once, before the first
# install.sh run (or any time you're moving off SQLite).
#
# Requires: MySQL server already installed and running on this machine
# (apt install mysql-server / default-mysql-server, then start it).
# This script only creates the database and user inside it — it does not
# install or start MySQL itself.

set -e

DB_NAME="${DB_NAME:-platform}"
DB_USER="${DB_USER:-platform_user}"
DB_PASS="${DB_PASS:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')}"
DB_HOST="${DB_HOST:-localhost}"

echo "==> Creating database '$DB_NAME' and user '$DB_USER'..."

mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}';
FLUSH PRIVILEGES;
SQL

echo ""
echo "==> Done. Add this to your .env file:"
echo ""
echo "DATABASE_URL=mysql+pymysql://${DB_USER}:${DB_PASS}@${DB_HOST}/${DB_NAME}?charset=utf8mb4"
echo ""
echo "Then run install.sh — it will create the app's tables inside this new,"
echo "persistent database. Because this database lives outside the app's own"
echo "directory (it's a separate MySQL server process), redeploying or"
echo "replacing the app's code will never touch your data again."
echo ""
echo "!! Save the password above somewhere safe — it isn't stored anywhere else."
