#!/usr/bin/env bash
# Restores a PostgreSQL backup produced by backup.sh. Intended for disaster
# recovery drills — run this against a scratch database, never directly
# against production, to verify backups are actually restorable.
#
# Usage: DATABASE_URL=postgresql://user:pass@host:5432/db ./restore.sh /backups/dedicated_sv_store_20260101T000000Z.sql.gz
set -euo pipefail

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL must be set" >&2
  exit 1
fi

BACKUP_FILE="${1:-}"
if [ -z "$BACKUP_FILE" ] || [ ! -f "$BACKUP_FILE" ]; then
  echo "Usage: DATABASE_URL=... ./restore.sh <backup-file.sql.gz>" >&2
  exit 1
fi

echo "Restoring $BACKUP_FILE into $DATABASE_URL"
gunzip -c "$BACKUP_FILE" | psql "$DATABASE_URL"
echo "Restore complete."
