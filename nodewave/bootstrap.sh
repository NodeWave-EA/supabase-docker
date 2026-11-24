#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DOMAIN=""
PROJECT_NAME=""
PORT_OFFSET=0
CADDY_MODE="auto" # auto | enabled | disabled
NON_INTERACTIVE=false

usage() {
  cat <<'EOF'
Usage: ./nodewave/bootstrap.sh [OPTIONS]

Bootstrap a self-hosted Supabase instance from the Nodewave template.

Options:
  -d, --domain <domain>         Public domain for this instance (e.g. alpha.nodewave.net)
  -p, --project-name <name>     Docker Compose project & container prefix (e.g. supabase-alpha)
  -o, --port-offset <number>    Integer offset added to default host ports (default: 0)
                                  API Gateway HTTP : 127.0.0.1:(8000 + offset)
                                  Kong HTTPS       : 127.0.0.1:(8443 + offset)
                                  Postgres         : (5432 + offset)
                                  Supavisor Pooler : 127.0.0.1:(6543 + offset)
      --no-caddy                Disable bundled Caddy container (use when behind a shared host proxy)
      --with-caddy              Force-enable bundled Caddy container even when --port-offset > 0
  -y, --yes                     Non-interactive mode (requires --domain)
  -h, --help                    Show this help message

Examples:
  # Single instance on a dedicated VPS (interactive domain prompt, bundled Caddy on 80/443)
  ./nodewave/bootstrap.sh

  # Multi-instance deployment on a shared VPS (unattended)
  ./nodewave/bootstrap.sh -d alpha.nodewave.net -p supabase-alpha -o 1 -y
  ./nodewave/bootstrap.sh -d beta.nodewave.net  -p supabase-beta  -o 2 -y
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
  -d | --domain)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    DOMAIN="$2"
    shift 2
    ;;
  --domain=*)
    DOMAIN="${1#*=}"
    shift
    ;;
  -p | --project-name)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    PROJECT_NAME="$2"
    shift 2
    ;;
  --project-name=*)
    PROJECT_NAME="${1#*=}"
    shift
    ;;
  -o | --port-offset)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    PORT_OFFSET="$2"
    shift 2
    ;;
  --port-offset=*)
    PORT_OFFSET="${1#*=}"
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
  -y | --yes)
    NON_INTERACTIVE=true
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

if [ -f .env ]; then
  echo "Error: .env already exists in $(pwd). Remove or back it up before re-running bootstrap." >&2
  exit 1
fi

# Validate port offset
if ! [[ "$PORT_OFFSET" =~ ^[0-9]+$ ]]; then
  echo "Error: --port-offset must be a non-negative integer (got '$PORT_OFFSET')." >&2
  exit 1
fi

GW_HTTP_PORT=$((8000 + PORT_OFFSET))
GW_HTTPS_PORT=$((8443 + PORT_OFFSET))
PG_PORT=$((5432 + PORT_OFFSET))
POOLER_TX_PORT=$((6543 + PORT_OFFSET))

if [ "$GW_HTTPS_PORT" -gt 65535 ]; then
  echo "Error: --port-offset $PORT_OFFSET pushes port numbers above 65535." >&2
  exit 1
fi

# Resolve domain
if [ -z "$DOMAIN" ]; then
  if [ "$NON_INTERACTIVE" = true ]; then
    echo "Error: --domain is required when running with --yes." >&2
    exit 1
  fi
  read -rp "Enter public Supabase domain (e.g. supabase.nodewave.net): " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
  echo "Error: Domain cannot be empty." >&2
  exit 1
fi

# Resolve & validate Docker Compose project name
MULTI_INSTANCE=false
if [ "$PORT_OFFSET" -gt 0 ] || [ -n "$PROJECT_NAME" ]; then
  MULTI_INSTANCE=true
fi

if [ -z "$PROJECT_NAME" ]; then
  if [ "$PORT_OFFSET" -gt 0 ]; then
    SANITIZED_DOMAIN=$(printf "%s" "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/-\+/-/g; s/^-//; s/-$//')
    PROJECT_NAME="supabase-${SANITIZED_DOMAIN}"
  else
    PROJECT_NAME="supabase"
  fi
fi

if ! [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
  echo "Error: --project-name must start with [a-z0-9] and contain only lowercase letters, numbers, '-' or '_' (got '$PROJECT_NAME')." >&2
  exit 1
fi

# Resolve Caddy mode (default: enabled when offset == 0, disabled when offset > 0)
case "$CADDY_MODE" in
enabled)
  USE_CADDY=true
  ;;
disabled)
  USE_CADDY=false
  ;;
auto)
  if [ "$PORT_OFFSET" -gt 0 ]; then
    USE_CADDY=false
  else
    USE_CADDY=true
  fi
  ;;
esac

# Check for host port collisions before generating files
if command -v ss >/dev/null 2>&1; then
  LISTENING_PORTS=$(ss -tlnH 2>/dev/null | awk '{print $4}' || true)
  for CHECK_PORT in "$GW_HTTP_PORT" "$GW_HTTPS_PORT" "$PG_PORT" "$POOLER_TX_PORT"; do
    if printf "%s\n" "$LISTENING_PORTS" | grep -Eq "(:|\])${CHECK_PORT}$"; then
      echo "Error: Host port ${CHECK_PORT} is already in use. Choose a higher --port-offset (current: ${PORT_OFFSET})." >&2
      exit 1
    fi
  done
fi

# Initialize .env from upstream + Nodewave defaults
cp .env.example .env
cat .env.nodewave.example >>.env
sed -i.bak "s|supabase.example.com|${DOMAIN}|g" .env
rm -f .env.bak

# Generate fresh JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY, and DB passwords
if [ -x ./utils/generate-keys.sh ]; then
  ./utils/generate-keys.sh
elif [ -f ./utils/generate-keys.sh ]; then
  sh ./utils/generate-keys.sh
fi

# Build COMPOSE_FILE chain
if [ "$USE_CADDY" = true ]; then
  COMPOSE_CHAIN="docker-compose.yml:docker-compose.caddy.yml:docker-compose.nodewave.yml"
else
  COMPOSE_CHAIN="docker-compose.yml:docker-compose.nodewave.yml"
fi

# Generate per-instance container_name overrides when running multiple instances on one host
if [ "$MULTI_INSTANCE" = true ]; then
  INSTANCE_OVERRIDE="docker-compose.instance.yml"
  SERVICES=$(COMPOSE_FILE="$COMPOSE_CHAIN" docker compose config --services 2>/dev/null ||
    awk '/^services:/{in_svc=1; next} in_svc && /^[^[:space:]]/{in_svc=0} in_svc && /^  [a-zA-Z0-9_-]+:/{sub(/^  /,""); sub(/:.*/,""); print}' docker-compose.yml)

  {
    echo "# Auto-generated by nodewave/bootstrap.sh for project '${PROJECT_NAME}'"
    echo "services:"
    for SVC in $SERVICES; do
      echo "  ${SVC}:"
      echo "    container_name: \${COMPOSE_PROJECT_NAME}-${SVC}"
    done
  } >"$INSTANCE_OVERRIDE"

  COMPOSE_CHAIN="${COMPOSE_CHAIN}:${INSTANCE_OVERRIDE}"

  # Keep auto-generated instance override invisible to git status
  if [ -d .git/info ] && ! grep -qxF "$INSTANCE_OVERRIDE" .git/info/exclude 2>/dev/null; then
    echo "$INSTANCE_OVERRIDE" >>.git/info/exclude
  fi
fi

# Append final instance overrides (Docker Compose uses the last definition of duplicate keys)
cat >>.env <<EOF

############
# Nodewave Instance Configuration (${PROJECT_NAME})
############
COMPOSE_PROJECT_NAME=${PROJECT_NAME}
COMPOSE_FILE=${COMPOSE_CHAIN}

API_GW_HTTP_PORT=127.0.0.1:${GW_HTTP_PORT}
KONG_HTTP_PORT=127.0.0.1:${GW_HTTP_PORT}
KONG_HTTPS_PORT=127.0.0.1:${GW_HTTPS_PORT}
POSTGRES_PORT=${PG_PORT}
POOLER_PROXY_PORT_TRANSACTION=127.0.0.1:${POOLER_TX_PORT}
EOF

# Record synced upstream tag so upstream update.sh tracks the exact baseline
UPSTREAM_TAG=$(tr -d '[:space:]' <.upstream-version)
printf "ref=%s\n" "$UPSTREAM_TAG" >.supabase-version

cat <<EOF

============================================================
Nodewave Supabase Bootstrap Complete
============================================================
Project Name : ${PROJECT_NAME}
Upstream Tag : ${UPSTREAM_TAG}
Public URL   : https://${DOMAIN}
Gateway HTTP : 127.0.0.1:${GW_HTTP_PORT}
Kong HTTPS   : 127.0.0.1:${GW_HTTPS_PORT}
Postgres     : ${PG_PORT}
Pooler (Tx)  : 127.0.0.1:${POOLER_TX_PORT}
Bundled Caddy: ${USE_CADDY}
============================================================
EOF

if [ "$USE_CADDY" = false ]; then
  cat <<EOF
Next steps:
  1. Add this block to your shared host Caddyfile and reload Caddy:

     ${DOMAIN} {
         reverse_proxy 127.0.0.1:${GW_HTTP_PORT}
     }

  2. Start this instance:
     sh run.sh start
EOF
else
  cat <<EOF
Next steps:
  1. Review SMTP settings in .env if needed.
  2. Start this instance:
     sh run.sh start
EOF
fi
