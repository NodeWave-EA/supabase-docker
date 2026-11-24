#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Helpers ----------------------------------------------------------------

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}
info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }

# Normalize shorthand environment names (dev -> development, prod -> production)
normalize_env_name() {
  local raw="${1#.env.}"
  case "$raw" in
  dev | development) printf 'development\n' ;;
  prod | production) printf 'production\n' ;;
  stage | staging) printf 'staging\n' ;;
  test | testing) printf 'test\n' ;;
  local) printf 'local\n' ;;
  *) printf '%s\n' "$raw" ;;
  esac
}

# Resolve symlinks to the underlying target file path (macOS & Linux compatible)
resolve_env_file() {
  local f="${1:-.env}"
  local target dir
  while [ -L "$f" ]; do
    target=$(readlink "$f")
    if [[ "$target" = /* ]]; then
      f="$target"
    else
      dir=$(dirname "$f")
      f="${dir}/${target}"
    fi
  done
  printf '%s\n' "$f"
}

# Return active environment name if .env is a symlink to .env.<name>
active_env_name() {
  if [ -L .env ]; then
    local target
    target=$(basename "$(readlink .env)")
    if [[ "$target" == .env.* ]]; then
      printf '%s\n' "${target#.env.}"
      return 0
    fi
  fi
  return 1
}

# Safely read a KEY=VALUE from an env file without executing shell substitutions
env_get() {
  local key="$1" file="${2:-.env}"
  [ -f "$file" ] || return 0
  awk -v k="$key" '
    index($0, k "=") == 1 {
      val = substr($0, length(k) + 2)
      sub(/\r$/, "", val)
    }
    END { print val }
  ' "$file"
}

# Set or append KEY=VALUE in .env safely while preserving symlinks
env_set() {
  local key="$1" val="$2" file="${3:-.env}"
  local target tmp
  target=$(resolve_env_file "$file")
  tmp=$(mktemp "$(dirname "$target")/.env.tmp.XXXXXX")

  awk -v k="$key" -v v="$val" '
    BEGIN { found = 0 }
    index($0, k "=") == 1 {
      print k "=" v
      found = 1
      next
    }
    { print }
    END {
      if (!found) print k "=" v
    }
  ' "$target" >"$tmp"

  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$target"
}

# Run upstream scripts that use `sed -i.old ... .env` without breaking .env symlinks
run_upstream_env_mutator() {
  local link_target="" real_target=""
  if [ -L .env ]; then
    link_target=$(readlink .env)
    real_target=$(resolve_env_file .env)
    rm -f .env
    cp -a "$real_target" .env
  fi

  "$@"

  rm -f .env.old docker-compose.yml.old
  if [ -n "$link_target" ]; then
    chmod 600 .env 2>/dev/null || true
    mv .env "$real_target"
    ln -sfn "$link_target" .env
  fi
}

ensure_git_excludes() {
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
  [ -n "$git_dir" ] || return 0
  [[ "$git_dir" = /* ]] || git_dir="${REPO_ROOT}/${git_dir}"
  mkdir -p "${git_dir}/info"

  for pattern in \
    ".env" \
    ".env.development" \
    ".env.production" \
    ".env.staging" \
    ".env.local" \
    ".env.clients" \
    ".env.clients.*" \
    ".nodewave-upgrade-state" \
    "docker-compose.instance.yml" \
    "backups/"; do
    if ! grep -qxF "$pattern" "${git_dir}/info/exclude" 2>/dev/null; then
      echo "$pattern" >>"${git_dir}/info/exclude"
    fi
  done
}

require_env() {
  if [ -L .env ] && [ ! -e .env ]; then
    die ".env is a broken symlink pointing to '$(readlink .env)'. Run './nodewave/manage.sh use' to switch to a valid environment."
  fi
  [ -f .env ] || die ".env not found. Run './nodewave/manage.sh bootstrap' first."
}

sync_client_env_files() {
  local active_name=""
  cmd_env --format all >.env.clients
  chmod 600 .env.clients

  if active_name=$(active_env_name); then
    cp -a .env.clients ".env.clients.${active_name}"
    chmod 600 ".env.clients.${active_name}"
  fi
}

# --- Command: bootstrap -----------------------------------------------------

cmd_bootstrap() {
  local DOMAIN=""
  local PROJECT_NAME=""
  local ENV_PROFILE=""
  local PORT_OFFSET=0
  local SITE_URL_OVERRIDE=""
  local CADDY_MODE="auto" # auto | enabled | disabled
  local LOCAL_MODE=false
  local NON_INTERACTIVE=false
  local FORCE=false
  local AUTO_START=false
  local SKIP_AUTH_KEYS=false
  local EXTRA_PROFILES=()

  while [ $# -gt 0 ]; do
    case "$1" in
    -e | --env)
      [ $# -ge 2 ] || die "$1 requires a value (e.g. development, production)."
      ENV_PROFILE=$(normalize_env_name "$2")
      shift 2
      ;;
    --env=*)
      ENV_PROFILE=$(normalize_env_name "${1#*=}")
      shift
      ;;
    -d | --domain)
      [ $# -ge 2 ] || die "$1 requires a value."
      DOMAIN="$2"
      shift 2
      ;;
    --domain=*)
      DOMAIN="${1#*=}"
      shift
      ;;
    --local)
      LOCAL_MODE=true
      DOMAIN="localhost"
      CADDY_MODE="disabled"
      shift
      ;;
    -p | --project-name)
      [ $# -ge 2 ] || die "$1 requires a value."
      PROJECT_NAME="$2"
      shift 2
      ;;
    --project-name=*)
      PROJECT_NAME="${1#*=}"
      shift
      ;;
    -o | --port-offset)
      [ $# -ge 2 ] || die "$1 requires a value."
      PORT_OFFSET="$2"
      shift 2
      ;;
    --port-offset=*)
      PORT_OFFSET="${1#*=}"
      shift
      ;;
    --site-url)
      [ $# -ge 2 ] || die "$1 requires a value."
      SITE_URL_OVERRIDE="$2"
      shift 2
      ;;
    --pg17)
      EXTRA_PROFILES+=("docker-compose.pg17.yml")
      shift
      ;;
    --s3)
      EXTRA_PROFILES+=("docker-compose.s3.yml")
      shift
      ;;
    --rustfs)
      EXTRA_PROFILES+=("docker-compose.rustfs.yml")
      shift
      ;;
    --kong)
      EXTRA_PROFILES+=("docker-compose.kong.yml")
      shift
      ;;
    --logs)
      EXTRA_PROFILES+=("docker-compose.logs.yml")
      shift
      ;;
    --no-caddy)
      CADDY_MODE="disabled"
      shift
      ;;
    --with-caddy)
      CADDY_MODE="enabled"
      shift
      ;;
    --skip-auth-keys)
      SKIP_AUTH_KEYS=true
      shift
      ;;
    --start)
      AUTO_START=true
      shift
      ;;
    -f | --force)
      FORCE=true
      shift
      ;;
    -y | --yes)
      NON_INTERACTIVE=true
      shift
      ;;
    -h | --help)
      cat <<'EOF'
Usage: ./nodewave/manage.sh bootstrap [OPTIONS]

First-clone setup for a Nodewave Supabase instance:
  1. Initializes .env (or .env.<env> with .env symlink) from upstream + Nodewave defaults
  2. Generates JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY, DB & Dashboard passwords
  3. Generates ES256 asymmetric keypair (JWT_KEYS/JWT_JWKS) & opaque API keys
  4. Configures ports, Compose overlays, and per-instance container isolation
  5. Prints & saves (.env.clients) ready-to-use Frontend/Backend/DB credentials

Options:
  -e, --env <name>              Create .env.<name> (e.g. development, production) and symlink .env -> .env.<name>
      --local                   Configure for local development (http://localhost:8000, no Caddy)
  -d, --domain <domain>         Public domain (e.g. alpha.nodewave.net or localhost)
  -p, --project-name <name>     Compose project & container prefix (e.g. supabase-alpha)
  -o, --port-offset <number>    Offset added to default host ports (default: 0)
      --site-url <url>          Frontend app URL for auth redirects (default: http://localhost:3000 or https://<domain>)
      --pg17                    Include Postgres 17 override
      --s3                      Include MinIO S3 storage override
      --rustfs                  Include RustFS S3 storage override
      --kong                    Use Kong API gateway instead of default Envoy
      --logs                    Include Logflare/Vector analytics override
      --no-caddy                Disable bundled Caddy TLS proxy
      --with-caddy              Force-enable bundled Caddy TLS proxy
      --skip-auth-keys          Skip asymmetric ES256 & opaque API key generation
      --start                   Start containers immediately after setup
  -f, --force                   Back up existing .env file and re-bootstrap
  -y, --yes                     Non-interactive mode
EOF
      return 0
      ;;
    *)
      die "Unknown bootstrap option '$1'. Run './nodewave/manage.sh bootstrap --help'."
      ;;
    esac
  done

  command -v openssl >/dev/null 2>&1 || die "openssl is required."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

  [[ "$PORT_OFFSET" =~ ^[0-9]+$ ]] || die "--port-offset must be a non-negative integer."

  local GW_HTTP_PORT=$((8000 + PORT_OFFSET))
  local GW_HTTPS_PORT=$((8443 + PORT_OFFSET))
  local PG_PORT=$((5432 + PORT_OFFSET))
  local POOLER_TX_PORT=$((6543 + PORT_OFFSET))
  [ "$GW_HTTPS_PORT" -le 65535 ] || die "--port-offset $PORT_OFFSET exceeds max TCP port 65535."

  # Resolve domain
  if [ -z "$DOMAIN" ]; then
    if [ "$ENV_PROFILE" = "development" ] || [ "$ENV_PROFILE" = "local" ]; then
      DOMAIN="localhost"
      LOCAL_MODE=true
      [ "$CADDY_MODE" = "auto" ] && CADDY_MODE="disabled"
    elif [ "$NON_INTERACTIVE" = true ]; then
      die "--domain or --local is required when using --yes."
    else
      read -rp "Enter domain (leave blank or enter 'localhost' for local dev): " DOMAIN
      [ -z "$DOMAIN" ] && DOMAIN="localhost"
    fi
  fi

  case "$DOMAIN" in
  localhost | 127.0.0.1 | *.localhost)
    LOCAL_MODE=true
    [ "$CADDY_MODE" = "auto" ] && CADDY_MODE="disabled"
    ;;
  esac

  # If .env is already a symlink and --env wasn't passed, inherit its profile name
  if [ -z "$ENV_PROFILE" ] && active_env_name >/dev/null 2>&1; then
    ENV_PROFILE=$(active_env_name)
  fi

  local TARGET_FILE=".env"
  [ -n "$ENV_PROFILE" ] && TARGET_FILE=".env.${ENV_PROFILE}"

  if [ -e "$TARGET_FILE" ] || [ -L "$TARGET_FILE" ]; then
    if [ "$FORCE" = true ]; then
      local bak="${TARGET_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
      cp -L "$TARGET_FILE" "$bak" 2>/dev/null || true
      rm -f "$TARGET_FILE"
      warn "Existing ${TARGET_FILE} backed up to ${bak}"
    else
      die "${TARGET_FILE} already exists. Pass --force to back it up and re-bootstrap, or run './nodewave/manage.sh use' to switch environments."
    fi
  fi

  # Protect an existing non-symlink .env when bootstrapping a new named profile
  if [ -n "$ENV_PROFILE" ] && [ -f .env ] && [ ! -L .env ]; then
    local legacy_bak=".env.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    mv .env "$legacy_bak"
    warn "Moved existing standalone .env to ${legacy_bak} before symlinking .env -> ${TARGET_FILE}"
  fi

  # Resolve Caddy mode
  local USE_CADDY=true
  case "$CADDY_MODE" in
  enabled) USE_CADDY=true ;;
  disabled) USE_CADDY=false ;;
  auto) [ "$PORT_OFFSET" -gt 0 ] && USE_CADDY=false || USE_CADDY=true ;;
  esac

  # Resolve project name
  local MULTI_INSTANCE=false
  if [ "$PORT_OFFSET" -gt 0 ] || [ -n "$PROJECT_NAME" ]; then
    MULTI_INSTANCE=true
  fi

  if [ -z "$PROJECT_NAME" ]; then
    if [ "$PORT_OFFSET" -gt 0 ]; then
      local sanitized
      sanitized=$(printf "%s" "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/-\+/-/g; s/^-//; s/-$//')
      PROJECT_NAME="supabase-${sanitized}"
    else
      PROJECT_NAME="supabase"
    fi
  fi

  [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Invalid --project-name '$PROJECT_NAME'."

  # Pre-flight port check
  if command -v ss >/dev/null 2>&1; then
    local listening
    listening=$(ss -tlnH 2>/dev/null | awk '{print $4}' || true)
    for p in "$GW_HTTP_PORT" "$GW_HTTPS_PORT" "$PG_PORT" "$POOLER_TX_PORT"; do
      if printf "%s\n" "$listening" | grep -Eq "(:|\])${p}$"; then
        die "Host port ${p} is already in use. Re-run with a higher --port-offset."
      fi
    done
  fi

  info "Initializing ${TARGET_FILE} from upstream and Nodewave defaults"
  cp .env.example "$TARGET_FILE"
  [ -f .env.nodewave.example ] && cat .env.nodewave.example >>"$TARGET_FILE"
  chmod 600 "$TARGET_FILE"

  if [ -n "$ENV_PROFILE" ]; then
    ln -sfn "$TARGET_FILE" .env
    info "Linked .env -> ${TARGET_FILE}"
  fi

  local PUBLIC_URL SITE_URL_VAL
  if [ "$LOCAL_MODE" = true ]; then
    PUBLIC_URL="http://${DOMAIN}:${GW_HTTP_PORT}"
    SITE_URL_VAL="${SITE_URL_OVERRIDE:-http://localhost:3000}"
  else
    PUBLIC_URL="https://${DOMAIN}"
    SITE_URL_VAL="${SITE_URL_OVERRIDE:-https://${DOMAIN}}"
  fi

  env_set "SUPABASE_DOMAIN" "$DOMAIN"
  env_set "PROXY_DOMAIN" "$DOMAIN"
  env_set "SUPABASE_PUBLIC_URL" "$PUBLIC_URL"
  env_set "API_EXTERNAL_URL" "$PUBLIC_URL"
  env_set "SITE_URL" "$SITE_URL_VAL"

  info "Generating legacy symmetric secrets & passwords (utils/generate-keys.sh)"
  run_upstream_env_mutator sh ./utils/generate-keys.sh --update-env >/dev/null

  if [ "$SKIP_AUTH_KEYS" = false ]; then
    info "Generating asymmetric ES256 JWKS & opaque API keys (utils/add-new-auth-keys.sh)"
    run_upstream_env_mutator sh ./utils/add-new-auth-keys.sh --update-env >/dev/null
    # Keep upstream docker-compose.yml clean; docker-compose.nodewave.yml already maps JWT_KEYS/JWT_JWKS
    if git ls-files --error-unmatch docker-compose.yml >/dev/null 2>&1; then
      git checkout -- docker-compose.yml 2>/dev/null || true
    fi
  fi

  # Assemble COMPOSE_FILE chain
  local COMPOSE_CHAIN="docker-compose.yml"
  for extra in "${EXTRA_PROFILES[@]}"; do
    [ -f "$extra" ] || die "Requested compose file '$extra' not found."
    COMPOSE_CHAIN="${COMPOSE_CHAIN}:${extra}"
  done

  if [ "$USE_CADDY" = true ]; then
    COMPOSE_CHAIN="${COMPOSE_CHAIN}:docker-compose.caddy.yml"
  fi

  [ -f docker-compose.nodewave.yml ] && COMPOSE_CHAIN="${COMPOSE_CHAIN}:docker-compose.nodewave.yml"
  if [ "$USE_CADDY" = true ] && [ -f docker-compose.caddy.nodewave.yml ]; then
    COMPOSE_CHAIN="${COMPOSE_CHAIN}:docker-compose.caddy.nodewave.yml"
  fi

  # Per-instance container_name isolation when running multiple instances
  if [ "$MULTI_INSTANCE" = true ]; then
    local INSTANCE_OVERRIDE="docker-compose.instance.yml"
    local SERVICES
    SERVICES=$(COMPOSE_FILE="$COMPOSE_CHAIN" docker compose config --services 2>/dev/null ||
      awk '/^services:/{in_svc=1; next} in_svc && /^[^[:space:]]/{in_svc=0} in_svc && /^  [a-zA-Z0-9_-]+:/{sub(/^  /,""); sub(/:.*/,""); print}' docker-compose.yml)

    {
      echo "# Auto-generated by nodewave/manage.sh for project '${PROJECT_NAME}'"
      echo "services:"
      for svc in $SERVICES; do
        echo "  ${svc}:"
        echo "    container_name: \${COMPOSE_PROJECT_NAME}-${svc}"
      done
    } >"$INSTANCE_OVERRIDE"

    COMPOSE_CHAIN="${COMPOSE_CHAIN}:${INSTANCE_OVERRIDE}"
  fi

  ensure_git_excludes

  # Write final instance & port configuration
  env_set "COMPOSE_PROJECT_NAME" "$PROJECT_NAME"
  env_set "COMPOSE_FILE" "$COMPOSE_CHAIN"
  env_set "API_GW_HTTP_PORT" "127.0.0.1:${GW_HTTP_PORT}"
  env_set "KONG_HTTP_PORT" "127.0.0.1:${GW_HTTP_PORT}"
  env_set "KONG_HTTPS_PORT" "127.0.0.1:${GW_HTTPS_PORT}"
  env_set "POSTGRES_PORT" "${PG_PORT}"
  env_set "POOLER_PROXY_PORT_TRANSACTION" "127.0.0.1:${POOLER_TX_PORT}"

  local UPSTREAM_TAG="unknown"
  if [ -f .upstream-version ]; then
    UPSTREAM_TAG=$(tr -d '[:space:]' <.upstream-version)
    printf "ref=%s\n" "$UPSTREAM_TAG" >.supabase-version
  fi

  sync_client_env_files

  local ACTIVE_LABEL=".env"
  [ -n "$ENV_PROFILE" ] && ACTIVE_LABEL=".env -> ${TARGET_FILE}"

  cat <<EOF

====================================================================
Nodewave Supabase Bootstrap Complete
====================================================================
Active Env    : ${ACTIVE_LABEL}
Project Name  : ${PROJECT_NAME}
Upstream Tag  : ${UPSTREAM_TAG}
Public URL    : ${PUBLIC_URL}
Site URL      : ${SITE_URL_VAL}
Gateway HTTP  : 127.0.0.1:${GW_HTTP_PORT}
Postgres Port : ${PG_PORT}
Pooler (Tx)   : 127.0.0.1:${POOLER_TX_PORT}
Bundled Caddy : ${USE_CADDY}
Client Keys   : Saved to .env.clients (git-ignored)
====================================================================
EOF

  cmd_env --format all

  if [ "$AUTO_START" = true ]; then
    info "Starting Supabase stack"
    sh run.sh start
  elif [ "$NON_INTERACTIVE" = false ] && [ -t 0 ]; then
    printf "\nStart Supabase containers now? (Y/n) "
    read -r REPLY
    case "$REPLY" in
    [Nn]*) echo "Skipped start. Run './nodewave/manage.sh start' when ready." ;;
    *) sh run.sh start ;;
    esac
  fi
}

# --- Command: use (Environment Symlink Switcher) -----------------------------

cmd_use() {
  local TARGET_RAW=""
  local RESTART_AFTER=false
  local CREATE_IF_MISSING=false

  while [ $# -gt 0 ]; do
    case "$1" in
    --restart | --up)
      RESTART_AFTER=true
      shift
      ;;
    --create)
      CREATE_IF_MISSING=true
      shift
      ;;
    -l | --list)
      TARGET_RAW="--list"
      shift
      ;;
    -h | --help)
      cat <<'EOF'
Usage: ./nodewave/manage.sh use [development|production|<name>] [OPTIONS]

Switch the active .env symlink to a target environment file (e.g. .env.development,
.env.production) and refresh .env.clients.

Options:
  -l, --list       List available .env.* profiles and show the active symlink target
      --create     Initialize .env.<name> from the current .env if it does not exist yet
      --restart    Restart Supabase containers immediately after switching .env
EOF
      return 0
      ;;
    -*)
      die "Unknown option '$1' for use. Run './nodewave/manage.sh use --help'."
      ;;
    *)
      TARGET_RAW="$1"
      shift
      ;;
    esac
  done

  ensure_git_excludes

  # Discover available .env.<profile> files (excluding backups, templates & .env.clients*)
  local PROFILES=()
  local f base name
  for f in .env.*; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
    .env.example | .env.nodewave.example | .env.old | .env.clients | .env.clients.* | *.bak | *.backup.* | *.tmp.*)
      continue
      ;;
    esac
    name="${base#.env.}"
    PROFILES+=("$name")
  done

  local CURRENT_ACTIVE=""
  CURRENT_ACTIVE=$(active_env_name || true)

  if [ "$TARGET_RAW" = "--list" ] || [ -z "$TARGET_RAW" ]; then
    info "Available Environment Profiles"
    if [ "${#PROFILES[@]}" -eq 0 ]; then
      echo "    No named .env.<profile> files found yet."
      if [ -f .env ] && [ ! -L .env ]; then
        echo "    Current .env is a standalone file (not symlinked)."
      fi
    else
      for i in "${!PROFILES[@]}"; do
        local p="${PROFILES[$i]}"
        local mark=""
        [ "$p" = "$CURRENT_ACTIVE" ] && mark=" <-- active (.env -> .env.${p})"
        printf '    [%d] %-14s (.env.%s)%s\n' $((i + 1)) "$p" "$p" "$mark"
      done
    fi

    [ "$TARGET_RAW" = "--list" ] && return 0
    [ -t 0 ] || die "Specify an environment name (e.g. './nodewave/manage.sh use production')."

    echo ""
    printf "Enter number or environment name (e.g. development, production): "
    read -r CHOICE
    [ -n "$CHOICE" ] || die "No environment selected."

    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#PROFILES[@]}" ]; then
      TARGET_RAW="${PROFILES[$((CHOICE - 1))]}"
    else
      TARGET_RAW="$CHOICE"
    fi
  fi

  local ENV_NAME TARGET_FILE
  ENV_NAME=$(normalize_env_name "$TARGET_RAW")
  TARGET_FILE=".env.${ENV_NAME}"

  # If .env is currently a standalone regular file, offer to adopt it into .env.<name>
  if [ -f .env ] && [ ! -L .env ]; then
    if [ ! -e "$TARGET_FILE" ]; then
      if [ -t 0 ]; then
        printf "Current .env is a standalone file. Move it to %s and symlink .env -> %s? [Y/n]: " "$TARGET_FILE" "$TARGET_FILE"
        read -r ADOPT_REPLY
        case "$ADOPT_REPLY" in
        [Nn]*)
          local bak=".env.backup.$(date -u +%Y%m%dT%H%M%SZ)"
          mv .env "$bak"
          warn "Backed up standalone .env to ${bak}"
          ;;
        *)
          mv .env "$TARGET_FILE"
          chmod 600 "$TARGET_FILE"
          info "Migrated standalone .env -> ${TARGET_FILE}"
          ;;
        esac
      else
        mv .env "$TARGET_FILE"
        chmod 600 "$TARGET_FILE"
      fi
    else
      local bak=".env.backup.$(date -u +%Y%m%dT%H%M%SZ)"
      mv .env "$bak"
      warn "Backed up standalone .env to ${bak}"
    fi
  fi

  # Handle missing target profile
  if [ ! -f "$TARGET_FILE" ]; then
    if [ "$CREATE_IF_MISSING" = true ] && [ -f .env ]; then
      cp -L .env "$TARGET_FILE"
      chmod 600 "$TARGET_FILE"
      info "Cloned active environment into ${TARGET_FILE}"
    elif [ -t 0 ]; then
      warn "${TARGET_FILE} does not exist yet."
      printf "Create %s by: [1] Cloning current .env, [2] Running fresh bootstrap, or [3] Cancel? [1/2/3]: " "$TARGET_FILE"
      read -r CREATE_CHOICE
      case "$CREATE_CHOICE" in
      1)
        [ -f .env ] || die "No active .env exists to clone from. Choose option [2] to bootstrap."
        cp -L .env "$TARGET_FILE"
        chmod 600 "$TARGET_FILE"
        info "Cloned current .env -> ${TARGET_FILE} (review domain, ports & secrets in ${TARGET_FILE})."
        ;;
      2)
        cmd_bootstrap --env "$ENV_NAME"
        return 0
        ;;
      *)
        die "Aborted."
        ;;
      esac
    else
      die "${TARGET_FILE} does not exist. Run './nodewave/manage.sh bootstrap --env ${ENV_NAME}' or pass --create."
    fi
  fi

  ln -sfn "$TARGET_FILE" .env
  sync_client_env_files

  local PUB_URL
  PUB_URL=$(env_get "SUPABASE_PUBLIC_URL" ".env")
  info "Switched active environment: .env -> ${TARGET_FILE} (${PUB_URL:-no URL set})"
  echo "    Refreshed .env.clients and .env.clients.${ENV_NAME}"

  if [ "$RESTART_AFTER" = true ]; then
    info "Restarting Supabase stack with ${TARGET_FILE}"
    sh run.sh start
  else
    echo "    Run './nodewave/manage.sh start' (or your parent compose stack) to apply changes to containers."
  fi
}

# --- Command: env -----------------------------------------------------------

cmd_env() {
  local FORMAT="all"
  local ENV_SELECT=""

  while [ $# -gt 0 ]; do
    case "$1" in
    --format)
      [ $# -ge 2 ] || die "--format requires a value (all|nextjs|nuxt|vite|backend|json)."
      FORMAT="$2"
      shift 2
      ;;
    --format=*)
      FORMAT="${1#*=}"
      shift
      ;;
    -e | --env)
      [ $# -ge 2 ] || die "$1 requires an environment name (e.g. development, production)."
      ENV_SELECT=$(normalize_env_name "$2")
      shift 2
      ;;
    --env=*)
      ENV_SELECT=$(normalize_env_name "${1#*=}")
      shift
      ;;
    -h | --help)
      cat <<'EOF'
Usage: ./nodewave/manage.sh env [--format all|nextjs|nuxt|vite|backend|json] [--env <name>]

Print environment variables required by Frontend (Next.js, Nuxt, Vite),
Backend, Database/ORM, and S3 clients to connect to this Supabase instance.
EOF
      return 0
      ;;
    *)
      die "Unknown option '$1' for env."
      ;;
    esac
  done

  local SOURCE_ENV=".env"
  if [ -n "$ENV_SELECT" ]; then
    SOURCE_ENV=".env.${ENV_SELECT}"
    [ -f "$SOURCE_ENV" ] || die "Environment file '${SOURCE_ENV}' not found."
  else
    require_env
  fi

  local PUBLIC_URL DOMAIN ANON_KEY SERVICE_ROLE_KEY PUBLISHABLE_KEY SECRET_KEY JWT_SECRET
  local PG_PASS PG_PORT POOLER_PORT POOLER_TENANT DB_HOST
  local S3_ID S3_SECRET S3_BUCKET S3_REGION DASH_USER DASH_PASS

  PUBLIC_URL=$(env_get "SUPABASE_PUBLIC_URL" "$SOURCE_ENV")
  DOMAIN=$(env_get "SUPABASE_DOMAIN" "$SOURCE_ENV")
  [ -z "$DOMAIN" ] && DOMAIN="localhost"
  ANON_KEY=$(env_get "ANON_KEY" "$SOURCE_ENV")
  SERVICE_ROLE_KEY=$(env_get "SERVICE_ROLE_KEY" "$SOURCE_ENV")
  PUBLISHABLE_KEY=$(env_get "SUPABASE_PUBLISHABLE_KEY" "$SOURCE_ENV")
  SECRET_KEY=$(env_get "SUPABASE_SECRET_KEY" "$SOURCE_ENV")
  JWT_SECRET=$(env_get "JWT_SECRET" "$SOURCE_ENV")

  PG_PASS=$(env_get "POSTGRES_PASSWORD" "$SOURCE_ENV")
  PG_PORT=$(env_get "POSTGRES_PORT" "$SOURCE_ENV")
  [ -z "$PG_PORT" ] && PG_PORT="5432"
  POOLER_PORT=$(env_get "POOLER_PROXY_PORT_TRANSACTION" "$SOURCE_ENV" | awk -F: '{print $NF}')
  [ -z "$POOLER_PORT" ] && POOLER_PORT="6543"
  POOLER_TENANT=$(env_get "POOLER_TENANT_ID" "$SOURCE_ENV")

  case "$DOMAIN" in
  localhost | 127.0.0.1 | *.localhost) DB_HOST="127.0.0.1" ;;
  *) DB_HOST="$DOMAIN" ;;
  esac

  local DIRECT_URL="postgresql://postgres:${PG_PASS}@${DB_HOST}:${PG_PORT}/postgres"
  local DATABASE_URL="postgresql://postgres.${POOLER_TENANT}:${PG_PASS}@${DB_HOST}:${POOLER_PORT}/postgres?pgbouncer=true"

  S3_ID=$(env_get "S3_PROTOCOL_ACCESS_KEY_ID" "$SOURCE_ENV")
  S3_SECRET=$(env_get "S3_PROTOCOL_ACCESS_KEY_SECRET" "$SOURCE_ENV")
  S3_BUCKET=$(env_get "GLOBAL_S3_BUCKET" "$SOURCE_ENV")
  S3_REGION=$(env_get "REGION" "$SOURCE_ENV")
  DASH_USER=$(env_get "DASHBOARD_USERNAME" "$SOURCE_ENV")
  DASH_PASS=$(env_get "DASHBOARD_PASSWORD" "$SOURCE_ENV")

  case "$FORMAT" in
  nextjs)
    cat <<EOF
NEXT_PUBLIC_SUPABASE_URL=${PUBLIC_URL}
NEXT_PUBLIC_SUPABASE_ANON_KEY=${ANON_KEY}
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}
SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
SUPABASE_SECRET_KEY=${SECRET_KEY}
SUPABASE_JWT_SECRET=${JWT_SECRET}
DATABASE_URL="${DATABASE_URL}"
DIRECT_URL="${DIRECT_URL}"
EOF
    ;;
  nuxt)
    cat <<EOF
SUPABASE_URL=${PUBLIC_URL}
SUPABASE_KEY=${ANON_KEY}
SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}
SUPABASE_SERVICE_KEY=${SERVICE_ROLE_KEY}
SUPABASE_SECRET_KEY=${SECRET_KEY}
SUPABASE_JWT_SECRET=${JWT_SECRET}
DATABASE_URL="${DATABASE_URL}"
DIRECT_URL="${DIRECT_URL}"
EOF
    ;;
  vite)
    cat <<EOF
VITE_SUPABASE_URL=${PUBLIC_URL}
VITE_SUPABASE_ANON_KEY=${ANON_KEY}
VITE_SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}
EOF
    ;;
  backend)
    cat <<EOF
SUPABASE_URL=${PUBLIC_URL}
SUPABASE_ANON_KEY=${ANON_KEY}
SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}
SUPABASE_SECRET_KEY=${SECRET_KEY}
SUPABASE_JWT_SECRET=${JWT_SECRET}
DATABASE_URL="${DATABASE_URL}"
DIRECT_URL="${DIRECT_URL}"
S3_ENDPOINT=${PUBLIC_URL}/storage/v1/s3
S3_REGION=${S3_REGION}
S3_ACCESS_KEY_ID=${S3_ID}
S3_SECRET_ACCESS_KEY=${S3_SECRET}
S3_BUCKET=${S3_BUCKET}
EOF
    ;;
  json)
    cat <<EOF
{
  "supabaseUrl": "${PUBLIC_URL}",
  "anonKey": "${ANON_KEY}",
  "serviceRoleKey": "${SERVICE_ROLE_KEY}",
  "publishableKey": "${PUBLISHABLE_KEY}",
  "secretKey": "${SECRET_KEY}",
  "jwtSecret": "${JWT_SECRET}",
  "databaseUrl": "${DATABASE_URL}",
  "directUrl": "${DIRECT_URL}",
  "s3": {
    "endpoint": "${PUBLIC_URL}/storage/v1/s3",
    "region": "${S3_REGION}",
    "accessKeyId": "${S3_ID}",
    "secretAccessKey": "${S3_SECRET}",
    "bucket": "${S3_BUCKET}"
  },
  "studio": {
    "url": "${PUBLIC_URL}",
    "username": "${DASH_USER}",
    "password": "${DASH_PASS}"
  }
}
EOF
    ;;
  all)
    cat <<EOF

# ====================================================================
# 1. FRONTEND APPS (Next.js / Nuxt / Vite / React / Mobile)
# ====================================================================
# Next.js:
NEXT_PUBLIC_SUPABASE_URL=${PUBLIC_URL}
NEXT_PUBLIC_SUPABASE_ANON_KEY=${ANON_KEY}
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}

# Nuxt (@nuxtjs/supabase):
SUPABASE_URL=${PUBLIC_URL}
SUPABASE_KEY=${ANON_KEY}
SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}
SUPABASE_SERVICE_KEY=${SERVICE_ROLE_KEY}
SUPABASE_SECRET_KEY=${SECRET_KEY}

# Vite / SPA:
VITE_SUPABASE_URL=${PUBLIC_URL}
VITE_SUPABASE_ANON_KEY=${ANON_KEY}
VITE_SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}

# ====================================================================
# 2. BACKEND / API / WORKERS (Node / Python / Go / Rust)
# ====================================================================
SUPABASE_URL=${PUBLIC_URL}
SUPABASE_ANON_KEY=${ANON_KEY}
SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
SUPABASE_PUBLISHABLE_KEY=${PUBLISHABLE_KEY}
SUPABASE_SECRET_KEY=${SECRET_KEY}
SUPABASE_JWT_SECRET=${JWT_SECRET}

# ====================================================================
# 3. DATABASE & POOLER (Prisma / Drizzle / SQL Clients)
# ====================================================================
# Transaction Pooler (Supavisor - recommended for serverless/apps):
DATABASE_URL="${DATABASE_URL}"
# Direct / Session Connection (migrations & schema push):
DIRECT_URL="${DIRECT_URL}"

# ====================================================================
# 4. S3 STORAGE PROTOCOL
# ====================================================================
S3_ENDPOINT=${PUBLIC_URL}/storage/v1/s3
S3_REGION=${S3_REGION}
S3_ACCESS_KEY_ID=${S3_ID}
S3_SECRET_ACCESS_KEY=${S3_SECRET}
S3_BUCKET=${S3_BUCKET}

# ====================================================================
# 5. SUPABASE STUDIO DASHBOARD (Keep Private)
# ====================================================================
STUDIO_URL=${PUBLIC_URL}
DASHBOARD_USERNAME=${DASH_USER}
DASHBOARD_PASSWORD=${DASH_PASS}
EOF
    ;;
  *)
    die "Unknown format '$FORMAT'. Expected: all | nextjs | nuxt | vite | backend | json"
    ;;
  esac
}

# --- Command: rotate-keys ---------------------------------------------------

cmd_rotate_keys() {
  require_env
  local MODE="${1:---api}"
  case "$MODE" in
  --api)
    info "Rotating opaque API keys (SUPABASE_PUBLISHABLE_KEY & SUPABASE_SECRET_KEY)"
    run_upstream_env_mutator sh ./utils/rotate-new-api-keys.sh --update-env
    ;;
  --auth)
    info "Rotating asymmetric ES256 JWKS & opaque API keys"
    run_upstream_env_mutator sh ./utils/add-new-auth-keys.sh --update-env
    git checkout -- docker-compose.yml 2>/dev/null || true
    ;;
  --db)
    info "Rotating Postgres role passwords"
    run_upstream_env_mutator sh ./utils/db-passwd.sh
    ;;
  --all)
    info "Rotating asymmetric auth keys, opaque API keys, and DB passwords"
    run_upstream_env_mutator sh ./utils/add-new-auth-keys.sh --update-env
    git checkout -- docker-compose.yml 2>/dev/null || true
    run_upstream_env_mutator sh ./utils/db-passwd.sh
    ;;
  -h | --help)
    cat <<'EOF'
Usage: ./nodewave/manage.sh rotate-keys [--api | --auth | --db | --all]
  --api   Rotate SUPABASE_PUBLISHABLE_KEY & SUPABASE_SECRET_KEY (default)
  --auth  Regenerate ES256 JWT_KEYS/JWT_JWKS & opaque API keys
  --db    Rotate internal Postgres role passwords & update active .env
  --all   Rotate auth keys, API keys, and DB passwords
EOF
    return 0
    ;;
  *)
    die "Unknown option '$MODE' for rotate-keys."
    ;;
  esac

  sync_client_env_files
  echo "Updated .env.clients. Run './nodewave/manage.sh restart' to apply changes to containers."
}

# --- Command: profile -------------------------------------------------------

cmd_profile() {
  require_env
  local ACTION="${1:-list}"
  local NAME="${2:-}"
  local CURRENT
  CURRENT=$(env_get "COMPOSE_FILE")
  [ -z "$CURRENT" ] && CURRENT="docker-compose.yml"

  case "$ACTION" in
  list)
    echo "Active COMPOSE_FILE chain:"
    printf '%s\n' "$CURRENT" | tr ':' '\n' | nl -w2 -s'. '
    echo ""
    echo "Available compose overlays in repo:"
    ls -1 docker-compose.*.yml 2>/dev/null | sed 's/^/  - /'
    ;;
  add)
    [ -n "$NAME" ] || die "Specify an overlay name or filename (e.g. pg17, rustfs, s3, kong, logs)."
    local FILE="$NAME"
    [[ "$FILE" == docker-compose.* ]] || FILE="docker-compose.${NAME}.yml"
    [ -f "$FILE" ] || die "Overlay file '$FILE' does not exist."
    case ":$CURRENT:" in
    *":$FILE:"*) echo "'$FILE' is already enabled." ;;
    *)
      env_set "COMPOSE_FILE" "${CURRENT}:${FILE}"
      echo "Enabled '$FILE'. Run './nodewave/manage.sh start' to apply."
      ;;
    esac
    ;;
  remove | rm)
    [ -n "$NAME" ] || die "Specify an overlay name or filename to remove."
    local FILE="$NAME"
    [[ "$FILE" == docker-compose.* ]] || FILE="docker-compose.${NAME}.yml"
    [ "$FILE" != "docker-compose.yml" ] || die "Cannot remove base docker-compose.yml."
    local UPDATED
    UPDATED=$(printf '%s\n' "$CURRENT" | tr ':' '\n' | grep -vxF "$FILE" | paste -sd: -)
    env_set "COMPOSE_FILE" "$UPDATED"
    echo "Removed '$FILE'. Run './nodewave/manage.sh start' to apply."
    ;;
  *)
    die "Usage: ./nodewave/manage.sh profile [list | add <name> | remove <name>]"
    ;;
  esac
}

# --- Command: upgrade -------------------------------------------------------

cmd_upgrade() {
  if [ -x "${REPO_ROOT}/nodewave/upgrade.sh" ]; then
    exec "${REPO_ROOT}/nodewave/upgrade.sh" "$@"
  elif [ -f "${REPO_ROOT}/nodewave/upgrade.sh" ]; then
    exec bash "${REPO_ROOT}/nodewave/upgrade.sh" "$@"
  else
    die "nodewave/upgrade.sh not found."
  fi
}

# --- Command: doctor --------------------------------------------------------

cmd_doctor() {
  info "Running Nodewave Supabase diagnostics"
  local ISSUES=0

  if [ -L .env ] && [ ! -e .env ]; then
    echo "[FAIL] .env is a broken symlink -> $(readlink .env)"
    return 1
  elif [ ! -f .env ]; then
    echo "[FAIL] .env file is missing (run './nodewave/manage.sh bootstrap')"
    return 1
  fi

  if [ -L .env ]; then
    echo "[ OK ] Active environment symlink: .env -> $(readlink .env)"
  else
    echo "[ OK ] .env exists (standalone file)"
  fi

  for placeholder in "your-super-secret" "this_password_is_insecure" "supabase-demo"; do
    if grep -q "$placeholder" .env; then
      echo "[WARN] Default placeholder '$placeholder' detected in active .env"
      ISSUES=$((ISSUES + 1))
    fi
  done

  if [ -n "$(env_get SUPABASE_PUBLISHABLE_KEY)" ] && [ -n "$(env_get JWT_KEYS)" ]; then
    echo "[ OK ] Asymmetric ES256 & opaque API keys configured"
  else
    echo "[WARN] Asymmetric auth keys missing (run './nodewave/manage.sh rotate-keys --auth')"
    ISSUES=$((ISSUES + 1))
  fi

  local CF
  CF=$(env_get "COMPOSE_FILE")
  for f in $(printf '%s' "$CF" | tr ':' ' '); do
    if [ ! -f "$f" ]; then
      echo "[FAIL] COMPOSE_FILE references missing file: $f"
      ISSUES=$((ISSUES + 1))
    fi
  done
  echo "[ OK ] COMPOSE_FILE chain verified ($CF)"

  if git diff --quiet docker-compose.yml run.sh update.sh 2>/dev/null; then
    echo "[ OK ] Upstream core files are unmodified"
  else
    echo "[WARN] Local modifications detected in upstream core files (docker-compose.yml / run.sh / update.sh)"
    ISSUES=$((ISSUES + 1))
  fi

  echo ""
  sh run.sh status || true
  echo ""
  [ "$ISSUES" -eq 0 ] && echo "All checks passed." || warn "Completed with $ISSUES warning(s)."
}

# --- Main Dispatcher --------------------------------------------------------

usage() {
  cat <<'EOF'
Nodewave Supabase Management Overlay

Usage: ./nodewave/manage.sh <command> [options]

Setup & Environment Management:
  bootstrap [opts]        First-clone setup (supports --env development|production symlink setup)
  use [env] [opts]        Switch active .env symlink (development, production, staging, etc.)
  env [--format <fmt>]    Print client env vars (all|nextjs|nuxt|vite|backend|json) [--env <name>]
  rotate-keys [mode]      Rotate API keys (--api), ES256 auth keys (--auth), or DB password (--db)

Lifecycle & Operations:
  start                   Start all Supabase services (via run.sh)
  stop                    Stop all Supabase services
  restart                 Restart all Supabase services
  status                  Show service health and ports
  logs [service]          Follow container logs (all services or specific service)
  pull                    Pull container images for active COMPOSE_FILE
  backup [opts]           Create atomic pg_dumpall + Vault key backup in backups/
  upgrade [ver] [opts]    Interactive version upgrader (standalone & submodule aware)

Overlays & Maintenance:
  profile [list|add|rm]   Manage Compose overlays (pg17, rustfs, s3, kong, logs, etc.)
  reassign-owner          Reassign public schema objects from supabase_admin to postgres
  upgrade-pg17            Run Postgres 15 -> 17 major version upgrade
  doctor                  Verify active .env symlink, keys, ports, and container health
  reset                   Stop services and wipe local volumes (destructive)
EOF
}

CMD="${1:-help}"
[ $# -gt 0 ] && shift

case "$CMD" in
bootstrap | init) cmd_bootstrap "$@" ;;
use | switch | switch-env) cmd_use "$@" ;;
envs) cmd_use --list ;;
env | keys | print-env) cmd_env "$@" ;;
rotate-keys) cmd_rotate_keys "$@" ;;
profile) cmd_profile "$@" ;;
upgrade) cmd_upgrade "$@" ;;
doctor) cmd_doctor "$@" ;;
start | up)
  require_env
  sh run.sh start "$@"
  ;;
stop | down)
  require_env
  sh run.sh stop "$@"
  ;;
restart)
  require_env
  sh run.sh restart "$@"
  ;;
status | ps)
  require_env
  sh run.sh status "$@"
  ;;
logs)
  require_env
  docker compose logs -f --tail=100 "$@"
  ;;
pull)
  require_env
  sh run.sh pull "$@"
  ;;
backup) ./nodewave/backup.sh "$@" ;;
reassign-owner)
  require_env
  sh ./utils/reassign-owner.sh "$@"
  ;;
upgrade-pg17)
  require_env
  sudo bash ./utils/upgrade-pg17.sh "$@"
  ;;
reset)
  require_env
  sh reset.sh "$@"
  ;;
-h | --help | help) usage ;;
*) die "Unknown command '$CMD'. Run './nodewave/manage.sh --help' for usage." ;;
esac
