#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Defaults (overridable via .env or CLI flags) ---------------------------

OUT_DIR="${BACKUP_DIR:-backups}"
KEEP_COUNT="${BACKUP_KEEP:-14}"
CONTAINER_OVERRIDE=""
BACKUP_KEY=true
QUIET=false

usage() {
  cat <<'EOF'
Usage: ./nodewave/backup.sh [OPTIONS]

Create an atomic, integrity-verified PostgreSQL cluster backup (pg_dumpall)
along with the pgsodium encryption root key and automatic retention pruning.

Options:
  -o, --out-dir <dir>       Backup destination directory (default: ./backups)
  -k, --keep <number>       Number of recent backups to retain; 0 = keep all (default: 14)
  -c, --container <name>    Explicit Postgres container name (auto-detected by default)
      --no-key              Skip backing up pgsodium_root.key
  -q, --quiet               Suppress progress messages (prints only backup path on success)
  -h, --help                Show this help message

Environment variables (.env):
  BACKUP_DIR                Default output directory (default: backups)
  BACKUP_KEEP               Default retention count (default: 14)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
  -o | --out-dir)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    OUT_DIR="$2"
    shift 2
    ;;
  --out-dir=*)
    OUT_DIR="${1#*=}"
    shift
    ;;
  -k | --keep)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    KEEP_COUNT="$2"
    shift 2
    ;;
  --keep=*)
    KEEP_COUNT="${1#*=}"
    shift
    ;;
  -c | --container)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    CONTAINER_OVERRIDE="$2"
    shift 2
    ;;
  --container=*)
    CONTAINER_OVERRIDE="${1#*=}"
    shift
    ;;
  --no-key)
    BACKUP_KEY=false
    shift
    ;;
  -q | --quiet)
    QUIET=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Error: Unknown option '$1'. Run with --help for usage." >&2
    exit 1
    ;;
  esac
done

[[ "$KEEP_COUNT" =~ ^[0-9]+$ ]] || {
  echo "Error: --keep must be a non-negative integer." >&2
  exit 1
}

log() {
  [ "$QUIET" = true ] || printf '%s\n' "$*"
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

env_get() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  awk -v k="$key" '
    index($0, k "=") == 1 {
      val = substr($0, length(k) + 2)
      sub(/\r$/, "", val)
    }
    END { print val }
  ' "$file"
}

# --- Resolve Project Name & Target DB Container -----------------------------

PROJECT_NAME=""
for env_candidate in .env .env.production .env.development; do
  if [ -f "$env_candidate" ]; then
    PROJECT_NAME=$(env_get "COMPOSE_PROJECT_NAME" "$env_candidate")
    [ -n "$PROJECT_NAME" ] && break
  fi
done
[ -z "$PROJECT_NAME" ] && PROJECT_NAME="supabase"

DB_CONTAINER=""
if [ -n "$CONTAINER_OVERRIDE" ]; then
  DB_CONTAINER="$CONTAINER_OVERRIDE"
elif [ -f .env ] && docker compose ps --status running --services 2>/dev/null | grep -qx "db"; then
  DB_CONTAINER=$(docker compose ps -q db 2>/dev/null | head -n 1)
else
  # Fallback for submodule setups (e.g. parent repo owns docker-compose)
  DB_CONTAINER=$(docker ps --filter "status=running" --format '{{.Names}}\t{{.Image}}' |
    awk -F'\t' '$1 == "supabase-db" || $1 ~ /-db(-1)?$/ || $2 ~ /supabase\/postgres/ { print $1; exit }')
fi

[ -n "$DB_CONTAINER" ] || die "No running Supabase Postgres container found. Start the stack or pass --container <name>."

DB_STATUS=$(docker inspect -f '{{.State.Status}}' "$DB_CONTAINER" 2>/dev/null || echo "missing")
[ "$DB_STATUS" = "running" ] || die "Container '$DB_CONTAINER' is not running (status: $DB_STATUS)."

# --- Prepare Output Paths & Atomic Cleanup Trap -----------------------------

mkdir -p "$OUT_DIR"
STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
BASE_NAME="${PROJECT_NAME}-db-${STAMP}"
FINAL_SQL="${OUT_DIR}/${BASE_NAME}.sql.gz"
TMP_SQL="${OUT_DIR}/.${BASE_NAME}.sql.gz.tmp"
FINAL_SHA="${FINAL_SQL}.sha256"
FINAL_KEY="${OUT_DIR}/${BASE_NAME}.pgsodium.key"

cleanup() {
  rm -f "$TMP_SQL"
}
trap cleanup EXIT

# --- Run Database Dump & Verify Integrity -----------------------------------

START_TS=$(date +%s)
log "==> Backing up database from container '${DB_CONTAINER}'..."

if ! docker exec -i "$DB_CONTAINER" pg_dumpall -U supabase_admin --clean --if-exists | gzip -9 >"$TMP_SQL"; then
  die "pg_dumpall failed; aborted without writing a partial backup."
fi

# Verify gzip stream integrity and non-empty payload
gzip -t "$TMP_SQL" || die "Backup archive failed gzip integrity verification."
UNCOMPRESSED_BYTES=$(gzip -dc "$TMP_SQL" | head -c 1024 | wc -c | tr -d ' ')
[ "$UNCOMPRESSED_BYTES" -gt 0 ] || die "Backup archive is empty."

chmod 600 "$TMP_SQL"
mv "$TMP_SQL" "$FINAL_SQL"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$OUT_DIR" && sha256sum "$(basename "$FINAL_SQL")") >"$FINAL_SHA"
  chmod 600 "$FINAL_SHA"
elif command -v shasum >/dev/null 2>&1; then
  (cd "$OUT_DIR" && shasum -a 256 "$(basename "$FINAL_SQL")") >"$FINAL_SHA"
  chmod 600 "$FINAL_SHA"
fi

# --- Back Up pgsodium Root Key (for Supabase Vault Secrets) -----------------

KEY_SAVED=false
if [ "$BACKUP_KEY" = true ]; then
  if docker exec "$DB_CONTAINER" test -f /etc/postgresql-custom/pgsodium_root.key 2>/dev/null; then
    docker cp "${DB_CONTAINER}:/etc/postgresql-custom/pgsodium_root.key" "$FINAL_KEY"
    chmod 600 "$FINAL_KEY"
    KEY_SAVED=true
  fi
fi

# --- Prune Old Backups ------------------------------------------------------

PRUNED=0
if [ "$KEEP_COUNT" -gt 0 ]; then
  shopt -s nullglob
  # Sort newest first by filename timestamp
  mapfile -t EXISTING < <(printf '%s\n' "${OUT_DIR}/${PROJECT_NAME}-db-"*.sql.gz | sort -r)
  shopt -u nullglob

  if [ "${#EXISTING[@]}" -gt "$KEEP_COUNT" ]; then
    for OLD_SQL in "${EXISTING[@]:$KEEP_COUNT}"; do
      OLD_PREFIX="${OLD_SQL%.sql.gz}"
      rm -f "$OLD_SQL" "${OLD_SQL}.sha256" "${OLD_PREFIX}.pgsodium.key"
      PRUNED=$((PRUNED + 1))
    done
  fi
fi

# --- Report -----------------------------------------------------------------

ELAPSED=$(($(date +%s) - START_TS))
SIZE_HUMAN=$(du -sh "$FINAL_SQL" | cut -f1)

if [ "$QUIET" = true ]; then
  printf '%s\n' "$FINAL_SQL"
else
  log "    Archive : ${FINAL_SQL} (${SIZE_HUMAN}, ${ELAPSED}s)"
  [ "$KEY_SAVED" = true ] && log "    VaultKey: ${FINAL_KEY}"
  [ "$PRUNED" -gt 0 ] && log "    Pruned  : ${PRUNED} old backup(s) (retaining latest ${KEEP_COUNT})"
fi
