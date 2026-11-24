#!/usr/bin/env bash
set -euo pipefail

SUPABASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SUPABASE_ROOT"

# --- Detect Standalone vs. Git Submodule Mode -------------------------------

IS_SUBMODULE=false
PARENT_ROOT=""
SUBMODULE_REL=""

SUPER_TREE=$(git -C "$SUPABASE_ROOT" rev-parse --show-superproject-working-tree 2>/dev/null || true)
if [ -n "$SUPER_TREE" ]; then
  IS_SUBMODULE=true
  PARENT_ROOT="$(cd "$SUPER_TREE" && pwd)"
  if command -v python3 >/dev/null 2>&1; then
    SUBMODULE_REL=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$SUPABASE_ROOT" "$PARENT_ROOT")
  else
    SUBMODULE_REL="${SUPABASE_ROOT#"$PARENT_ROOT"/}"
  fi
fi

STATE_FILE="${SUPABASE_ROOT}/.nodewave-upgrade-state"

# --- CLI Options ------------------------------------------------------------

TARGET_VERSION=""
CHANNEL_PREF="" # release | tag | auto
COMPOSE_FILES_ARG=""
IMAGE_CLEANUP_MODE="" # all | select | skip | dangling
SKIP_BACKUP=false
SKIP_ENV_SYNC=false
SKIP_PULL=false
AUTO_COMMIT="" # yes | no | prompt
AUTO_PUSH=""   # yes | no | prompt
COMMIT_MSG=""
NON_INTERACTIVE=false
DRY_RUN=false
DO_ROLLBACK=false

usage() {
  cat <<'EOF'
Usage: ./nodewave/upgrade.sh [VERSION] [OPTIONS]

Interactive upgrade assistant for Nodewave Supabase (standalone or Git submodule).

Arguments:
  VERSION                       Target version or ref (e.g. v0.8.5, 0.8.5, release/v0.8.5, main)
                                If omitted, opens an interactive version selector.

Options:
  -v, --version <ref>           Target version, tag, or branch
      --channel <release|tag>   Prefer mutable 'release/vX.Y.Z' branch or immutable 'vX.Y.Z' tag
  -f, --compose-file <files>    Colon-separated compose file(s) (auto-detected if omitted)
      --prune-images <mode>     Previous-version image cleanup: all | select | dangling | skip
      --skip-image-cleanup      Alias for --prune-images skip
      --skip-backup             Skip pre-upgrade database and .env backup
      --skip-env-sync           Skip checking for new keys in .env.example
      --skip-pull               Skip 'docker compose pull'
      --commit                  Automatically commit submodule update in parent repo
      --no-commit               Do not commit submodule update in parent repo
      --commit-msg <message>    Custom commit message for parent repository
      --push                    Automatically push parent repo commit after committing
      --rollback                Roll back to the previous pre-upgrade state
      --dry-run                 Preview upgrade steps without modifying files or containers
  -y, --yes                     Non-interactive mode (uses safe defaults)
  -h, --help                    Show this help message

Examples:
  # Interactive upgrade (standalone or from parent repo via ./docker/supabase/nodewave/upgrade.sh)
  ./nodewave/upgrade.sh

  # Upgrade to v0.8.5 tracking release/v0.8.5, remove all old images, and commit submodule
  ./nodewave/upgrade.sh v0.8.5 --channel release --prune-images all --commit -y

  # Preview what upgrading to v0.8.5 would change
  ./nodewave/upgrade.sh v0.8.5 --dry-run

  # Revert the last upgrade
  ./nodewave/upgrade.sh --rollback
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
  -v | --version)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    TARGET_VERSION="$2"
    shift 2
    ;;
  --version=*)
    TARGET_VERSION="${1#*=}"
    shift
    ;;
  --channel)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    CHANNEL_PREF="$2"
    shift 2
    ;;
  --channel=*)
    CHANNEL_PREF="${1#*=}"
    shift
    ;;
  -f | --compose-file)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    COMPOSE_FILES_ARG="$2"
    shift 2
    ;;
  --compose-file=*)
    COMPOSE_FILES_ARG="${1#*=}"
    shift
    ;;
  --prune-images)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    IMAGE_CLEANUP_MODE="$2"
    shift 2
    ;;
  --prune-images=*)
    IMAGE_CLEANUP_MODE="${1#*=}"
    shift
    ;;
  --skip-image-cleanup)
    IMAGE_CLEANUP_MODE="skip"
    shift
    ;;
  --skip-backup)
    SKIP_BACKUP=true
    shift
    ;;
  --skip-env-sync)
    SKIP_ENV_SYNC=true
    shift
    ;;
  --skip-pull)
    SKIP_PULL=true
    shift
    ;;
  --commit)
    AUTO_COMMIT="yes"
    shift
    ;;
  --no-commit)
    AUTO_COMMIT="no"
    shift
    ;;
  --commit-msg)
    [ $# -ge 2 ] || {
      echo "Error: $1 requires a value." >&2
      exit 1
    }
    COMMIT_MSG="$2"
    shift 2
    ;;
  --push)
    AUTO_PUSH="yes"
    shift
    ;;
  --rollback)
    DO_ROLLBACK=true
    shift
    ;;
  --dry-run)
    DRY_RUN=true
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
  -*)
    echo "Error: Unknown option '$1'. Run with --help for usage." >&2
    exit 1
    ;;
  *)
    if [ -z "$TARGET_VERSION" ]; then
      TARGET_VERSION="$1"
    else
      echo "Error: Unexpected argument '$1'." >&2
      exit 1
    fi
    shift
    ;;
  esac
done

# --- Formatting & Prompt Helpers --------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
fi

step() { printf '\n%s==> %s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    %s[OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
  printf '\n%sError:%s %s\n' "$C_BOLD$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

ask_yes_no() {
  local prompt="$1" default="${2:-y}" reply
  if [ "$NON_INTERACTIVE" = true ] || [ ! -t 0 ]; then
    [ "$default" = "y" ] && return 0 || return 1
  fi
  if [ "$default" = "y" ]; then
    printf '%s %s[Y/n]%s: ' "$prompt" "$C_BOLD" "$C_RESET"
  else
    printf '%s %s[y/N]%s: ' "$prompt" "$C_BOLD" "$C_RESET"
  fi
  read -r reply
  [ -z "$reply" ] && reply="$default"
  case "$reply" in
  [Yy]*) return 0 ;;
  *) return 1 ;;
  esac
}

format_bytes() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GB", b / 1073741824;
    else if (b >= 1048576) printf "%.1f MB", b / 1048576;
    else if (b >= 1024) printf "%.1f KB", b / 1024;
    else printf "%d B", b;
  }'
}

ensure_local_excludes() {
  local git_dir
  git_dir=$(git -C "$SUPABASE_ROOT" rev-parse --git-dir)
  [[ "$git_dir" = /* ]] || git_dir="${SUPABASE_ROOT}/${git_dir}"
  mkdir -p "${git_dir}/info"
  for pattern in ".nodewave-upgrade-state" "docker-compose.instance.yml" ".env.clients" ".env.clients.*" ".env.development" ".env.production" "backups/"; do
    if ! grep -qxF "$pattern" "${git_dir}/info/exclude" 2>/dev/null; then
      echo "$pattern" >>"${git_dir}/info/exclude"
    fi
  done
}

# --- Compose Context Resolution ---------------------------------------------

COMPOSE_WORKDIR="$SUPABASE_ROOT"
COMPOSE_FLAGS=()

resolve_compose_context() {
  if [ "$IS_SUBMODULE" = true ]; then
    COMPOSE_WORKDIR="$PARENT_ROOT"
  else
    COMPOSE_WORKDIR="$SUPABASE_ROOT"
  fi

  local chosen_files="$COMPOSE_FILES_ARG"

  if [ -z "$chosen_files" ] && [ "$IS_SUBMODULE" = true ]; then
    # Discover compose files in parent repo (docker-compose.yml first when managed as symlink)
    local candidates=()
    for f in docker-compose.yml docker-compose.prod.yml docker-compose.dev.yml compose.yml compose.prod.yml compose.dev.yml; do
      [ -f "${PARENT_ROOT}/${f}" ] && candidates+=("$f")
    done

    # Infer default: prefer active docker-compose.yml symlink, otherwise match .env symlink
    local default_idx=1
    if [ -L "${PARENT_ROOT}/docker-compose.yml" ] && [ -e "${PARENT_ROOT}/docker-compose.yml" ]; then
      default_idx=1
    elif [ -L "${SUPABASE_ROOT}/.env" ]; then
      local link_target
      link_target=$(readlink "${SUPABASE_ROOT}/.env")
      for i in "${!candidates[@]}"; do
        if [[ "$link_target" == *prod* ]] && [[ "${candidates[$i]}" == *prod* ]]; then
          default_idx=$((i + 1))
        elif [[ "$link_target" == *dev* ]] && [[ "${candidates[$i]}" == *dev* ]]; then
          default_idx=$((i + 1))
        fi
      done
    fi

    if [ "${#candidates[@]}" -eq 1 ]; then
      chosen_files="${candidates[0]}"
    elif [ "${#candidates[@]}" -gt 1 ]; then
      if [ "$NON_INTERACTIVE" = true ] || [ ! -t 0 ]; then
        chosen_files="${candidates[$((default_idx - 1))]}"
      else
        step "Select Parent Repository Compose Stack"
        for i in "${!candidates[@]}"; do
          local mark=""
          [ $((i + 1)) -eq "$default_idx" ] && mark=" ${C_GREEN}(default)${C_RESET}"
          printf '    [%d] %s%s\n' $((i + 1)) "${candidates[$i]}" "$mark"
        done
        printf '    Enter choice [%d] or custom colon-separated file(s): ' "$default_idx"
        local sel
        read -r sel
        [ -z "$sel" ] && sel="$default_idx"
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#candidates[@]}" ]; then
          chosen_files="${candidates[$((sel - 1))]}"
        else
          chosen_files="$sel"
        fi
      fi
    fi
  fi

  COMPOSE_FLAGS=()
  if [ -n "$chosen_files" ]; then
    local IFS=':'
    for cf in $chosen_files; do
      [ -f "${COMPOSE_WORKDIR}/${cf}" ] || die "Compose file '${COMPOSE_WORKDIR}/${cf}' not found."
      COMPOSE_FLAGS+=("-f" "$cf")
    done
  fi
}

run_compose() {
  (cd "$COMPOSE_WORKDIR" && docker compose "${COMPOSE_FLAGS[@]}" "$@")
}

ensure_parent_env_and_networks() {
  if [ "$IS_SUBMODULE" = true ] && [ -f "${PARENT_ROOT}/run.sh" ]; then
    if ! run_compose config --quiet >/dev/null 2>&1; then
      if grep -q 'switch_env' "${PARENT_ROOT}/run.sh" 2>/dev/null; then
        local env_flag="--dev"
        local active_compose=""
        [ -L "${PARENT_ROOT}/docker-compose.yml" ] && active_compose=$(readlink "${PARENT_ROOT}/docker-compose.yml")
        for flag in "${COMPOSE_FLAGS[@]}"; do
          [[ "$flag" == *prod* ]] && env_flag="--prod"
        done
        [[ "$active_compose" == *prod* ]] && env_flag="--prod"

        warn "Parent repository environment symlinks are incomplete."
        if ask_yes_no "Run '${PARENT_ROOT}/run.sh env ${env_flag}' to initialize parent .env symlinks now?" "y"; then
          (cd "$PARENT_ROOT" && sh ./run.sh env "$env_flag")
        fi
      fi
    fi
  fi

  # Ensure any external Docker networks declared in the resolved compose config exist
  if docker info >/dev/null 2>&1; then
    local ext_nets
    ext_nets=$(run_compose config 2>/dev/null | awk '
      /^networks:/ { in_net=1; next }
      in_net && /^[^[:space:]]/ { in_net=0 }
      in_net && /^  [a-zA-Z0-9_.-]+:/ { net=$1; sub(/:$/, "", net) }
      in_net && /external: true/ && net != "" { print net; net="" }
    ' || true)
    for net in $ext_nets; do
      if ! docker network inspect "$net" >/dev/null 2>&1; then
        docker network create "$net" >/dev/null
        ok "Created external Docker network: ${net}"
      fi
    done
  fi
}

# --- Rollback Handler -------------------------------------------------------

perform_rollback() {
  [ -f "$STATE_FILE" ] || die "No upgrade state file found at ${STATE_FILE}. Nothing to roll back."

  # shellcheck disable=SC1090
  source "$STATE_FILE"

  step "Rolling Back Upgrade"
  info "Target commit : ${PREV_COMMIT:-unknown}"
  info "Target ref    : ${PREV_REF:-detached}"
  [ -n "${ENV_BACKUP_DIR:-}" ] && info "Env snapshot  : ${ENV_BACKUP_DIR}"
  [ -n "${DB_BACKUP_FILE:-}" ] && info "DB snapshot   : ${DB_BACKUP_FILE}"

  if [ "$DRY_RUN" = true ]; then
    info "[DRY RUN] Would revert git checkout, restore .env files, and restart containers."
    return 0
  fi

  if [ -n "${PREV_REF:-}" ] && git -C "$SUPABASE_ROOT" show-ref --verify --quiet "refs/heads/${PREV_REF}"; then
    git -C "$SUPABASE_ROOT" checkout "$PREV_REF"
    git -C "$SUPABASE_ROOT" reset --hard "$PREV_COMMIT"
  else
    git -C "$SUPABASE_ROOT" checkout "$PREV_COMMIT"
  fi

  if [ -n "${ENV_BACKUP_DIR:-}" ] && [ -d "$ENV_BACKUP_DIR" ]; then
    for f in .env .env.development .env.production; do
      if [ -f "${ENV_BACKUP_DIR}/${f}" ]; then
        cp -a "${ENV_BACKUP_DIR}/${f}" "${SUPABASE_ROOT}/${f}"
      fi
    done
    ok "Restored .env files from ${ENV_BACKUP_DIR}"
  fi

  if [ "$IS_SUBMODULE" = true ] && [ -n "${PREV_SUBMODULE_BRANCH:-}" ]; then
    git -C "$PARENT_ROOT" config -f .gitmodules "submodule.${SUBMODULE_REL}.branch" "$PREV_SUBMODULE_BRANCH"
  fi

  resolve_compose_context
  ensure_parent_env_and_networks
  info "Restarting stack with previous version images..."
  run_compose up -d --remove-orphans

  if [ -n "${DB_BACKUP_FILE:-}" ] && [ -f "$DB_BACKUP_FILE" ]; then
    echo ""
    warn "Database data was NOT overwritten automatically."
    info "If database schema migrations ran and need reverting, restore manually with:"
    info "  gunzip -c \"${DB_BACKUP_FILE}\" | docker compose exec -T db psql -U supabase_admin -d postgres"
  fi

  ok "Rollback complete."
}

if [ "$DO_ROLLBACK" = true ]; then
  perform_rollback
  exit 0
fi

# --- Pre-Flight & Version Discovery -----------------------------------------

step "Inspecting Current Deployment"

if [ "$IS_SUBMODULE" = true ]; then
  info "Mode           : Git Submodule inside '${PARENT_ROOT}'"
  info "Submodule Path : ${SUBMODULE_REL}"
else
  info "Mode           : Standalone Repository ('${SUPABASE_ROOT}')"
fi

ensure_local_excludes

PREV_COMMIT=$(git -C "$SUPABASE_ROOT" rev-parse HEAD)
PREV_SHORT=$(git -C "$SUPABASE_ROOT" rev-parse --short HEAD)
PREV_TAG=$(git -C "$SUPABASE_ROOT" describe --tags --exact-match 2>/dev/null || true)
PREV_BRANCH=$(git -C "$SUPABASE_ROOT" symbolic-ref --short HEAD 2>/dev/null || true)
PREV_UPSTREAM=$(tr -d '[:space:]' <"${SUPABASE_ROOT}/.upstream-version" 2>/dev/null || echo "unknown")
PREV_SUBMODULE_BRANCH=""
if [ "$IS_SUBMODULE" = true ]; then
  PREV_SUBMODULE_BRANCH=$(git -C "$PARENT_ROOT" config -f .gitmodules --get "submodule.${SUBMODULE_REL}.branch" 2>/dev/null || true)
fi

info "Current Commit : ${PREV_SHORT} (${PREV_BRANCH:-${PREV_TAG:-detached HEAD}})"
info "Upstream Base  : ${PREV_UPSTREAM}"
[ -n "$PREV_SUBMODULE_BRANCH" ] && info "Tracked Branch : ${PREV_SUBMODULE_BRANCH}"

# Ensure clean working tree in supabase-docker (ignoring untracked .env/backups)
if ! git -C "$SUPABASE_ROOT" diff --quiet || ! git -C "$SUPABASE_ROOT" diff --cached --quiet; then
  die "Uncommitted modifications exist inside '${SUPABASE_ROOT}'. Commit, stash, or revert them before upgrading."
fi

step "Fetching Available Versions from Origin"
git -C "$SUPABASE_ROOT" fetch --tags --prune origin

# Gather unique version tags sorted newest first
AVAILABLE_TAGS=()
while IFS= read -r tag; do
  [ -n "$tag" ] && AVAILABLE_TAGS+=("$tag")
done < <(git -C "$SUPABASE_ROOT" tag -l 'v*' | sort -V -r)

# --- Resolve Target Version & Channel ---------------------------------------

if [ -z "$TARGET_VERSION" ]; then
  [ "$NON_INTERACTIVE" = false ] && [ -t 0 ] || die "Specify a target version when running non-interactively (e.g. ./nodewave/upgrade.sh v0.8.5)."

  step "Available Supabase Versions"
  LIMIT=12
  COUNT=0
  for tag in "${AVAILABLE_TAGS[@]}"; do
    COUNT=$((COUNT + 1))
    [ "$COUNT" -gt "$LIMIT" ] && break

    HAS_REL=""
    if git -C "$SUPABASE_ROOT" show-ref --verify --quiet "refs/remotes/origin/release/${tag}"; then
      HAS_REL="release/${tag}"
    fi

    MARKER=""
    if [ "$tag" = "$PREV_TAG" ] || [ "release/${tag}" = "$PREV_BRANCH" ] || [ "release/${tag}" = "$PREV_SUBMODULE_BRANCH" ]; then
      MARKER=" ${C_GREEN}<-- current${C_RESET}"
    fi

    printf '    [%2d] %-10s %s(%s)%s%s\n' "$COUNT" "$tag" "$C_DIM" "${HAS_REL:-tag only}" "$C_RESET" "$MARKER"
  done

  echo ""
  info "Enter a number [1-${COUNT}], a version (e.g. v0.8.5), 'release/v0.8.5', or 'main':"
  printf '    Target version: '
  read -r USER_CHOICE
  [ -n "$USER_CHOICE" ] || die "No version selected."

  if [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] && [ "$USER_CHOICE" -ge 1 ] && [ "$USER_CHOICE" -le "$COUNT" ]; then
    TARGET_VERSION="${AVAILABLE_TAGS[$((USER_CHOICE - 1))]}"
  else
    TARGET_VERSION="$USER_CHOICE"
  fi
fi

# Normalize bare semantic version like "0.8.5" -> "v0.8.5"
if [[ "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  TARGET_VERSION="v${TARGET_VERSION}"
fi

# Determine git ref to checkout (branch vs immutable tag)
CHECKOUT_REF=""
CHECKOUT_KIND="" # branch | tag
TRACK_BRANCH_FOR_SUBMODULE=""

if [[ "$TARGET_VERSION" == release/* ]]; then
  git -C "$SUPABASE_ROOT" show-ref --verify --quiet "refs/remotes/origin/${TARGET_VERSION}" ||
    die "Remote branch 'origin/${TARGET_VERSION}' does not exist."
  CHECKOUT_REF="$TARGET_VERSION"
  CHECKOUT_KIND="branch"
  TRACK_BRANCH_FOR_SUBMODULE="$TARGET_VERSION"
elif [ "$TARGET_VERSION" = "main" ]; then
  CHECKOUT_REF="main"
  CHECKOUT_KIND="branch"
  TRACK_BRANCH_FOR_SUBMODULE="main"
else
  # Tag like v0.8.5: check if matching release/v0.8.5 branch also exists
  HAS_RELEASE_BRANCH=false
  if git -C "$SUPABASE_ROOT" show-ref --verify --quiet "refs/remotes/origin/release/${TARGET_VERSION}"; then
    HAS_RELEASE_BRANCH=true
  fi
  HAS_TAG=false
  if git -C "$SUPABASE_ROOT" show-ref --verify --quiet "refs/tags/${TARGET_VERSION}"; then
    HAS_TAG=true
  fi

  [ "$HAS_RELEASE_BRANCH" = true ] || [ "$HAS_TAG" = true ] ||
    die "Version '${TARGET_VERSION}' not found as a tag or release branch on origin."

  if [ -z "$CHANNEL_PREF" ]; then
    if [ "$HAS_RELEASE_BRANCH" = true ] && [ "$HAS_TAG" = true ]; then
      if [ "$NON_INTERACTIVE" = true ] || [ ! -t 0 ]; then
        if [ "$IS_SUBMODULE" = true ]; then
          CHANNEL_PREF="release"
        else
          CHANNEL_PREF="tag"
        fi
      else
        echo ""
        info "How would you like to track ${C_BOLD}${TARGET_VERSION}${C_RESET}?"
        printf '    [1] %srelease/%s%s (Recommended: tracks Nodewave overlay updates on %s)\n' "$C_BOLD" "$TARGET_VERSION" "$C_RESET" "$TARGET_VERSION"
        printf '    [2] %s%s%s         (Immutable point-in-time tag)\n' "$C_BOLD" "$TARGET_VERSION" "$C_RESET"
        local_def="1"
        [ "$IS_SUBMODULE" = false ] && local_def="2"
        printf '    Choice [%s]: ' "$local_def"
        read -r ch_sel
        [ -z "$ch_sel" ] && ch_sel="$local_def"
        [ "$ch_sel" = "1" ] && CHANNEL_PREF="release" || CHANNEL_PREF="tag"
      fi
    elif [ "$HAS_RELEASE_BRANCH" = true ]; then
      CHANNEL_PREF="release"
    else
      CHANNEL_PREF="tag"
    fi
  fi

  if [ "$CHANNEL_PREF" = "release" ]; then
    [ "$HAS_RELEASE_BRANCH" = true ] || die "Release branch 'release/${TARGET_VERSION}' does not exist."
    CHECKOUT_REF="release/${TARGET_VERSION}"
    CHECKOUT_KIND="branch"
    TRACK_BRANCH_FOR_SUBMODULE="release/${TARGET_VERSION}"
  else
    [ "$HAS_TAG" = true ] || die "Tag '${TARGET_VERSION}' does not exist."
    CHECKOUT_REF="$TARGET_VERSION"
    CHECKOUT_KIND="tag"
    TRACK_BRANCH_FOR_SUBMODULE=""
  fi
fi

if [ "$CHECKOUT_KIND" = "branch" ]; then
  TARGET_COMMIT=$(git -C "$SUPABASE_ROOT" rev-parse "origin/${CHECKOUT_REF}")
else
  TARGET_COMMIT=$(git -C "$SUPABASE_ROOT" rev-parse "${CHECKOUT_REF}^{commit}")
fi

TARGET_SHORT=$(git -C "$SUPABASE_ROOT" rev-parse --short "$TARGET_COMMIT")

info "Selected Target: ${C_BOLD}${CHECKOUT_REF}${C_RESET} (${TARGET_SHORT})"

SUBMODULE_PENDING=false
if [ "$IS_SUBMODULE" = true ]; then
  if [ "$PREV_SUBMODULE_BRANCH" != "$TRACK_BRANCH_FOR_SUBMODULE" ] || ! git -C "$PARENT_ROOT" diff --quiet -- "$SUBMODULE_REL"; then
    SUBMODULE_PENDING=true
  fi
fi

if [ "$PREV_COMMIT" = "$TARGET_COMMIT" ] && [ "$SUBMODULE_PENDING" = false ]; then
  ok "Already at ${CHECKOUT_REF} (${TARGET_SHORT})."
  if ! ask_yes_no "Re-run image pull, .env check, and image cleanup anyway?" "n"; then
    exit 0
  fi
fi

# --- Resolve Compose Stack & Snapshot Current Docker Images -----------------

resolve_compose_context

step "Snapshotting Active Docker Images Before Upgrade"

OLD_IMAGE_PAIRS=() # "repo:tag|sha256:..."
if docker info >/dev/null 2>&1; then
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    pair=$(docker inspect --format '{{.Config.Image}}|{{.Image}}' "$cid" 2>/dev/null || true)
    [ -n "$pair" ] && OLD_IMAGE_PAIRS+=("$pair")
  done < <(run_compose ps -a -q 2>/dev/null || true)

  while IFS= read -r img_ref; do
    [ -n "$img_ref" ] || continue
    img_id=$(docker image inspect --format '{{.Id}}' "$img_ref" 2>/dev/null || true)
    [ -n "$img_id" ] && OLD_IMAGE_PAIRS+=("${img_ref}|${img_id}")
  done < <(run_compose config --images 2>/dev/null || true)
fi

UNIQUE_OLD_PAIRS=()
if [ "${#OLD_IMAGE_PAIRS[@]}" -gt 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && UNIQUE_OLD_PAIRS+=("$line")
  done < <(printf '%s\n' "${OLD_IMAGE_PAIRS[@]}" | sort -u)
fi

info "Captured ${#UNIQUE_OLD_PAIRS[@]} active image reference(s) from current version."

# --- Dry Run Summary --------------------------------------------------------

if [ "$DRY_RUN" = true ]; then
  step "Dry Run Summary (No Changes Made)"
  info "Current ref   : ${PREV_BRANCH:-${PREV_TAG:-$PREV_SHORT}} (${PREV_SHORT})"
  info "Target ref    : ${CHECKOUT_REF} (${TARGET_SHORT})"
  info "Compose dir   : ${COMPOSE_WORKDIR}"
  info "Compose flags : ${COMPOSE_FLAGS[*]:-(default)}"
  if [ "$IS_SUBMODULE" = true ]; then
    info "Parent repo   : ${PARENT_ROOT}"
    info "Submodule     : ${SUBMODULE_REL} (branch -> ${TRACK_BRANCH_FOR_SUBMODULE:-<detached tag>})"
  fi
  echo ""
  info "Changelog preview (${PREV_SHORT}..${TARGET_SHORT}):"
  git -C "$SUPABASE_ROOT" diff "${PREV_COMMIT}..${TARGET_COMMIT}" -- CHANGELOG.md | head -n 40 || true
  exit 0
fi

# --- Pre-Upgrade Backup -----------------------------------------------------

STAMP=$(date -u +"%Y%m%dT%H%M%SZ")
ENV_BACKUP_DIR="${SUPABASE_ROOT}/backups/env-pre-upgrade-${STAMP}"
DB_BACKUP_FILE=""

if [ "$SKIP_BACKUP" = false ]; then
  step "Pre-Upgrade Backup"
  if ask_yes_no "Create database & .env backup before upgrading?" "y"; then
    mkdir -p "$ENV_BACKUP_DIR"
    for f in .env .env.development .env.production; do
      if [ -f "${SUPABASE_ROOT}/${f}" ] && [ ! -L "${SUPABASE_ROOT}/${f}" ]; then
        cp -a "${SUPABASE_ROOT}/${f}" "${ENV_BACKUP_DIR}/${f}"
      fi
    done
    ok "Environment files backed up to ${ENV_BACKUP_DIR}"

    if docker ps --filter "status=running" --format '{{.Names}}\t{{.Image}}' | grep -Eq 'supabase-db|-db(-1)?$|supabase/postgres'; then
      DB_BACKUP_FILE=$("${SUPABASE_ROOT}/nodewave/backup.sh" --quiet)
      ok "Database backup saved to ${DB_BACKUP_FILE}"
    else
      warn "No running Postgres container detected; skipped database dump."
    fi
  else
    warn "Skipped pre-upgrade backup."
  fi
fi

# Save rollback metadata before changing files
cat >"$STATE_FILE" <<EOF
PREV_COMMIT="${PREV_COMMIT}"
PREV_REF="${PREV_BRANCH}"
PREV_SUBMODULE_BRANCH="${PREV_SUBMODULE_BRANCH}"
ENV_BACKUP_DIR="${ENV_BACKUP_DIR}"
DB_BACKUP_FILE="${DB_BACKUP_FILE}"
EOF

# --- Checkout Target Version ------------------------------------------------

step "Checking Out ${CHECKOUT_REF}"

if [ "$CHECKOUT_KIND" = "branch" ]; then
  git -C "$SUPABASE_ROOT" checkout -B "$CHECKOUT_REF" "origin/${CHECKOUT_REF}"
else
  git -C "$SUPABASE_ROOT" checkout "$CHECKOUT_REF"
fi

if [ -f "${SUPABASE_ROOT}/.upstream-version" ]; then
  NEW_UPSTREAM=$(tr -d '[:space:]' <"${SUPABASE_ROOT}/.upstream-version")
  printf 'ref=%s\n' "$NEW_UPSTREAM" >"${SUPABASE_ROOT}/.supabase-version"
  ok "Checked out ${CHECKOUT_REF} (upstream ${NEW_UPSTREAM})"
else
  ok "Checked out ${CHECKOUT_REF}"
fi

# --- Changelog & Postgres Major Version Check -------------------------------

step "Reviewing Release Notes & Compatibility"

CHANGELOG_DIFF=$(git -C "$SUPABASE_ROOT" diff "${PREV_COMMIT}..HEAD" -- CHANGELOG.md | grep '^+[^+]' | sed 's/^+//' | head -n 35 || true)
if [ -n "$CHANGELOG_DIFF" ]; then
  info "Highlights from CHANGELOG.md:"
  printf '%s\n' "$CHANGELOG_DIFF" | sed 's/^/      /'
else
  info "No CHANGELOG.md changes between ${PREV_SHORT} and ${TARGET_SHORT}."
fi

# Guard against accidental PG 15 -> PG 17 mismatch on existing data volume
if [ -f "${SUPABASE_ROOT}/volumes/db/data/PG_VERSION" ]; then
  DATA_PG_VER=$(tr -d '[:space:]' <"${SUPABASE_ROOT}/volumes/db/data/PG_VERSION")
  NEW_DB_IMG=$(run_compose config 2>/dev/null | awk '/image:.*supabase\/postgres:/{print $2; exit}' || true)
  if [ "$DATA_PG_VER" = "15" ] && [[ "$NEW_DB_IMG" == *":17."* ]]; then
    echo ""
    warn "Existing database volume is PostgreSQL 15, while the target compose stack uses ${NEW_DB_IMG} (PG 17)!"
    warn "Starting PG 17 directly on PG 15 data will fail unless you either:"
    warn "  1. Enable 'docker-compose.pg15.yml' in COMPOSE_FILE, OR"
    warn "  2. Run 'sudo bash utils/upgrade-pg17.sh' after upgrading."
    ask_yes_no "Continue anyway?" "n" || die "Aborted so you can configure PG 15 / PG 17 migration first."
  fi
fi

# --- .env Key Diff & Migration Helper ---------------------------------------

if [ "$SKIP_ENV_SYNC" = false ] && [ -f "${SUPABASE_ROOT}/.env.example" ]; then
  step "Auditing Environment Variables Against .env.example"

  ENV_TARGETS=()
  for candidate in .env .env.development .env.production; do
    if [ -f "${SUPABASE_ROOT}/${candidate}" ] && [ ! -L "${SUPABASE_ROOT}/${candidate}" ]; then
      ENV_TARGETS+=("${SUPABASE_ROOT}/${candidate}")
    fi
  done

  for env_file in "${ENV_TARGETS[@]}"; do
    MISSING_KEYS=$(awk -F= '
      /^[A-Z0-9_]+=/ {
        if (NR == FNR) { seen[$1] = 1 }
        else if (!($1 in seen)) { print $1 }
      }
    ' "$env_file" "${SUPABASE_ROOT}/.env.example")

    if [ -z "$MISSING_KEYS" ]; then
      ok "$(basename "$env_file"): all keys from .env.example are present."
      continue
    fi

    MISSING_COUNT=$(printf '%s\n' "$MISSING_KEYS" | wc -l | tr -d ' ')
    warn "$(basename "$env_file") is missing ${MISSING_COUNT} key(s) from .env.example:"
    printf '%s\n' "$MISSING_KEYS" | sed 's/^/      - /'

    if ask_yes_no "Append missing default variables from .env.example to $(basename "$env_file")?" "y"; then
      {
        echo ""
        echo "# Added by nodewave/upgrade.sh on ${STAMP} (${CHECKOUT_REF})"
        while IFS= read -r mkey; do
          [ -n "$mkey" ] || continue
          grep -m1 "^${mkey}=" "${SUPABASE_ROOT}/.env.example" || true
        done <<<"$MISSING_KEYS"
      } >>"$env_file"
      ok "Appended missing keys to $(basename "$env_file")."
    fi

    # Offer asymmetric ES256 auth key generation if newly added and empty
    if grep -q '^SUPABASE_PUBLISHABLE_KEY=$' "$env_file" && [ -f "${SUPABASE_ROOT}/utils/add-new-auth-keys.sh" ]; then
      if ask_yes_no "Generate asymmetric ES256 & opaque API keys for $(basename "$env_file") now?" "y"; then
        (
          cd "$SUPABASE_ROOT"
          if [ "$(basename "$env_file")" != ".env" ]; then
            cp "$env_file" .env.upgrade-tmp
            sh ./utils/add-new-auth-keys.sh --update-env >/dev/null
            git checkout -- docker-compose.yml 2>/dev/null || true
            rm -f .env.old docker-compose.yml.old .env.upgrade-tmp
          else
            sh ./utils/add-new-auth-keys.sh --update-env >/dev/null
            git checkout -- docker-compose.yml 2>/dev/null || true
            rm -f .env.old docker-compose.yml.old
          fi
        )
        ok "Generated asymmetric auth keys."
      fi
    fi
  done

  # Refresh .env.clients if manage.sh is available
  if [ -x "${SUPABASE_ROOT}/nodewave/manage.sh" ] && [ -f "${SUPABASE_ROOT}/.env" ]; then
    "${SUPABASE_ROOT}/nodewave/manage.sh" env --format all >"${SUPABASE_ROOT}/.env.clients"
    chmod 600 "${SUPABASE_ROOT}/.env.clients" 2>/dev/null || true
    if [ -L "${SUPABASE_ROOT}/.env" ]; then
      _active_target=$(basename "$(readlink "${SUPABASE_ROOT}/.env")")
      if [[ "$_active_target" == .env.* ]]; then
        cp -a "${SUPABASE_ROOT}/.env.clients" "${SUPABASE_ROOT}/.env.clients.${_active_target#.env.}"
        chmod 600 "${SUPABASE_ROOT}/.env.clients.${_active_target#.env.}" 2>/dev/null || true
      fi
    fi
    ok "Refreshed .env.clients"
  fi
fi

# --- Validate Compose, Pull Images & Restart Stack --------------------------

step "Validating Compose Configuration & Updating Containers"

ensure_parent_env_and_networks

if ! COMPOSE_ERR=$(run_compose config --quiet 2>&1); then
  printf '%s\n' "$COMPOSE_ERR" >&2
  die "Docker Compose configuration validation failed. Fix the missing .env file or compose reference above and re-run."
fi
ok "Compose configuration validated."

if [ "$SKIP_PULL" = false ]; then
  info "Pulling container images for ${CHECKOUT_REF}..."
  run_compose pull
fi

info "Recreating updated containers..."
run_compose up -d --remove-orphans

sleep 3
UNHEALTHY=$(run_compose ps --format '{{.Name}}\t{{.Status}}' 2>/dev/null | grep -E 'Exit|Restarting|unhealthy' || true)
if [ -n "$UNHEALTHY" ]; then
  warn "Some containers reported issues after restart:"
  printf '%s\n' "$UNHEALTHY" | sed 's/^/      /'
  if ask_yes_no "Roll back to ${PREV_BRANCH:-${PREV_TAG:-$PREV_SHORT}} now?" "y"; then
    perform_rollback
    exit 1
  fi
else
  ok "All stack services started cleanly."
fi

# --- Interactive Previous-Version Docker Image Removal ----------------------

cleanup_previous_images() {
  [ "$IMAGE_CLEANUP_MODE" = "skip" ] && {
    info "Skipped previous-version Docker image cleanup."
    return 0
  }
  [ "${#UNIQUE_OLD_PAIRS[@]}" -eq 0 ] && return 0

  local IN_USE_IDS=()
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    local iid
    iid=$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null || true)
    [ -n "$iid" ] && IN_USE_IDS+=("$iid")
  done < <(docker ps -a -q 2>/dev/null || true)

  while IFS= read -r img_ref; do
    [ -n "$img_ref" ] || continue
    local iid
    iid=$(docker image inspect --format '{{.Id}}' "$img_ref" 2>/dev/null || true)
    [ -n "$iid" ] && IN_USE_IDS+=("$iid")
  done < <(run_compose config --images 2>/dev/null || true)

  local OBSOLETE_REFS=()
  local OBSOLETE_IDS=()
  local OBSOLETE_SIZES=()
  local TOTAL_BYTES=0

  for pair in "${UNIQUE_OLD_PAIRS[@]}"; do
    local ref="${pair%%|*}"
    local id="${pair##*|}"

    local used=false
    for u_id in "${IN_USE_IDS[@]}"; do
      if [ "$id" = "$u_id" ]; then
        used=true
        break
      fi
    done
    [ "$used" = true ] && continue

    local sz
    sz=$(docker image inspect --format '{{.Size}}' "$id" 2>/dev/null || true)
    [ -n "$sz" ] || continue

    OBSOLETE_REFS+=("$ref")
    OBSOLETE_IDS+=("$id")
    OBSOLETE_SIZES+=("$sz")
    TOTAL_BYTES=$((TOTAL_BYTES + sz))
  done

  if [ "${#OBSOLETE_REFS[@]}" -eq 0 ]; then
    ok "No unused previous-version Docker images remain on disk."
    return 0
  fi

  step "Previous-Version Docker Images Available for Cleanup"
  local TOTAL_HUMAN
  TOTAL_HUMAN=$(format_bytes "$TOTAL_BYTES")
  info "Found ${#OBSOLETE_REFS[@]} superseded image(s) not used by any container (${C_BOLD}${TOTAL_HUMAN}${C_RESET} total):"
  echo ""

  for i in "${!OBSOLETE_REFS[@]}"; do
    local short_id="${OBSOLETE_IDS[$i]#sha256:}"
    short_id="${short_id:0:12}"
    local sz_h
    sz_h=$(format_bytes "${OBSOLETE_SIZES[$i]}")
    printf '    [%2d] %-52s %s%-12s  %9s%s\n' \
      $((i + 1)) "${OBSOLETE_REFS[$i]}" "$C_DIM" "$short_id" "$sz_h" "$C_RESET"
  done
  echo ""

  local ACTION="$IMAGE_CLEANUP_MODE"
  if [ -z "$ACTION" ]; then
    if [ "$NON_INTERACTIVE" = true ] || [ ! -t 0 ]; then
      ACTION="skip"
    else
      info "Choose cleanup action:"
      printf '    [a] Remove ALL %d superseded image(s) (%s)\n' "${#OBSOLETE_REFS[@]}" "$TOTAL_HUMAN"
      printf '    [s] Select specific images to remove (customizable)\n'
      printf '    [d] Remove ALL superseded image(s) + dangling (<none>) images\n'
      printf '    [k] Keep all previous images (skip cleanup for fast rollback)\n'
      printf '    Choice [a/s/d/K]: '
      local ch
      read -r ch
      case "$ch" in
      [Aa]) ACTION="all" ;;
      [Ss]) ACTION="select" ;;
      [Dd]) ACTION="dangling" ;;
      *) ACTION="skip" ;;
      esac
    fi
  fi

  local TO_REMOVE_REFS=()
  local TO_REMOVE_IDS=()

  case "$ACTION" in
  all | dangling)
    TO_REMOVE_REFS=("${OBSOLETE_REFS[@]}")
    TO_REMOVE_IDS=("${OBSOLETE_IDS[@]}")
    ;;
  select)
    info "Enter image numbers to remove (comma-separated or ranges, e.g. '1,3,5-7'), or 'all' / 'none':"
    printf '    Selection: '
    local sel_str
    read -r sel_str
    case "$sel_str" in
    "" | none | NONE)
      info "No images selected; skipping removal."
      return 0
      ;;
    all | ALL)
      TO_REMOVE_REFS=("${OBSOLETE_REFS[@]}")
      TO_REMOVE_IDS=("${OBSOLETE_IDS[@]}")
      ;;
    *)
      local IFS=','
      for token in $sel_str; do
        token=$(printf '%s' "$token" | tr -d ' ')
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
          local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
          for ((n = start; n <= end; n++)); do
            if [ "$n" -ge 1 ] && [ "$n" -le "${#OBSOLETE_REFS[@]}" ]; then
              TO_REMOVE_REFS+=("${OBSOLETE_REFS[$((n - 1))]}")
              TO_REMOVE_IDS+=("${OBSOLETE_IDS[$((n - 1))]}")
            fi
          done
        elif [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "${#OBSOLETE_REFS[@]}" ]; then
          TO_REMOVE_REFS+=("${OBSOLETE_REFS[$((token - 1))]}")
          TO_REMOVE_IDS+=("${OBSOLETE_IDS[$((token - 1))]}")
        else
          warn "Ignoring invalid selection '${token}'"
        fi
      done
      ;;
    esac
    ;;
  skip | *)
    info "Kept all previous-version images."
    return 0
    ;;
  esac

  local REMOVED_COUNT=0
  for i in "${!TO_REMOVE_REFS[@]}"; do
    info "Removing ${TO_REMOVE_REFS[$i]}..."
    if docker rmi "${TO_REMOVE_REFS[$i]}" >/dev/null 2>&1 || docker rmi "${TO_REMOVE_IDS[$i]}" >/dev/null 2>&1; then
      REMOVED_COUNT=$((REMOVED_COUNT + 1))
    else
      warn "Could not remove ${TO_REMOVE_REFS[$i]} (may still be tagged or referenced)."
    fi
  done

  if [ "$ACTION" = "dangling" ]; then
    info "Pruning dangling (<none>) images..."
    docker image prune -f >/dev/null 2>&1 || true
  fi

  ok "Removed ${REMOVED_COUNT} previous-version image(s)."
}

cleanup_previous_images

# --- Parent Repository Submodule Update & Git Commit ------------------------

if [ "$IS_SUBMODULE" = true ]; then
  step "Updating Parent Repository Submodule Reference"

  if [ -n "$TRACK_BRANCH_FOR_SUBMODULE" ]; then
    git -C "$PARENT_ROOT" config -f .gitmodules "submodule.${SUBMODULE_REL}.branch" "$TRACK_BRANCH_FOR_SUBMODULE"
  else
    git -C "$PARENT_ROOT" config -f .gitmodules --unset "submodule.${SUBMODULE_REL}.branch" 2>/dev/null || true
  fi

  git -C "$PARENT_ROOT" add .gitmodules "$SUBMODULE_REL"

  if git -C "$PARENT_ROOT" diff --cached --quiet; then
    ok "Parent repository submodule pointer is already up to date."
  else
    PARENT_BRANCH=$(git -C "$PARENT_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "HEAD")
    info "Staged changes in '${PARENT_ROOT}' (branch: ${PARENT_BRANCH}):"
    git -C "$PARENT_ROOT" status -s -- .gitmodules "$SUBMODULE_REL" | sed 's/^/      /'
    echo ""

    DO_COMMIT=false
    if [ "$AUTO_COMMIT" = "yes" ]; then
      DO_COMMIT=true
    elif [ "$AUTO_COMMIT" = "no" ]; then
      DO_COMMIT=false
    elif ask_yes_no "Commit submodule upgrade in parent repository (${PARENT_BRANCH})?" "y"; then
      DO_COMMIT=true
    fi

    if [ "$DO_COMMIT" = true ]; then
      DEFAULT_MSG="chore(docker): upgrade supabase-docker to ${CHECKOUT_REF}"
      FINAL_MSG="${COMMIT_MSG:-$DEFAULT_MSG}"
      if [ -z "$COMMIT_MSG" ] && [ "$NON_INTERACTIVE" = false ] && [ -t 0 ]; then
        printf '    Commit message [%s]: ' "$DEFAULT_MSG"
        read -r custom_msg
        [ -n "$custom_msg" ] && FINAL_MSG="$custom_msg"
      fi

      git -C "$PARENT_ROOT" commit -m "$FINAL_MSG" -- .gitmodules "$SUBMODULE_REL"
      ok "Committed submodule upgrade to '${PARENT_BRANCH}'."

      DO_PUSH=false
      if [ "$AUTO_PUSH" = "yes" ]; then
        DO_PUSH=true
      elif [ "$AUTO_PUSH" != "no" ] && [ "$PARENT_BRANCH" != "HEAD" ]; then
        ask_yes_no "Push '${PARENT_BRANCH}' to origin?" "n" && DO_PUSH=true
      fi

      if [ "$DO_PUSH" = true ]; then
        git -C "$PARENT_ROOT" push origin "$PARENT_BRANCH"
        ok "Pushed '${PARENT_BRANCH}' to origin."
      fi
    else
      info "Changes remain staged in '${PARENT_ROOT}' for you to commit manually."
    fi
  fi
fi

# --- Summary ----------------------------------------------------------------

step "Upgrade Complete"
ok "Upgraded ${PREV_BRANCH:-${PREV_TAG:-$PREV_SHORT}} -> ${CHECKOUT_REF} (${TARGET_SHORT})"
info "Rollback available via: ./nodewave/upgrade.sh --rollback"
