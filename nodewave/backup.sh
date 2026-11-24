#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p backups
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
OUT="backups/supabase-db-${STAMP}.sql.gz"

docker compose exec -T db pg_dumpall -U supabase_admin | gzip > "$OUT"
echo "Database backup saved to $OUT"
