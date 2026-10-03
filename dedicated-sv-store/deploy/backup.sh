#!/usr/bin/env bash
# Nightly PostgreSQL backup with retention. Intended to run via cron/systemd
# timer on the host, or as a scheduled job against the postgres container.
#
# Usage: DATABASE_URL=postgresql://user:pass@host:5432/db BACKUP_DIR=/backups ./backup.sh
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL must be set" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
DEST="$BACKUP_DIR/dedicated_sv_store_${TIMESTAMP}.sql.gz"

echo "Backing up database to $DEST"
pg_dump "$DATABASE_URL" | gzip > "$DEST"

echo "Pruning backups older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -name "dedicated_sv_store_*.sql.gz" -mtime "+${RETENTION_DAYS}" -delete

echo "Backup complete: $DEST"
