# Nodewave Supabase Self-Hosted

A lightweight, multi-versioned deployment baseline for
self-hosted [Supabase](https://supabase.com/docs/guides/self-hosting/docker). This repository extracts Supabase’s
official `docker/` stack to the root and layers Nodewave’s management CLI, automatic key generation, client `.env`
exporter, interactive submodule-aware upgrader, atomic Vault-safe backups, Caddy TLS defaults, localhost port lockdown,
and container log rotation without modifying upstream files.

## Architecture: Clean Base + Nodewave Overlay

To prevent merge conflicts during upstream upgrades, this repository enforces a strict two-layer separation:

1. **Untouched Upstream Layer (Root):** Files synced directly from [
   `supabase/supabase/docker`](https://github.com/supabase/supabase/tree/master/docker) including `docker-compose.yml`,
   modular compose overlays (`caddy`, `envoy`, `kong`, `nginx`, `pg15`/`pg17`, `pgbouncer`, `s3`/`rustfs`, `logs`),
   lifecycle scripts (`setup.sh`, `run.sh`, `update.sh`, `reset.sh`), `utils/`, `volumes/`, `tests/`, and release
   metadata (`CHANGELOG.md`, `CONFIG.md`, `versions.md`, `upgrades.json`). **Never edit these manually.**
2. **Nodewave Overlay Layer:** Custom infrastructure configuration, asymmetric JWT mappings, environment defaults, CI
   sync workflows, and the `nodewave/` management scripts isolated in dedicated files merged automatically via
   `COMPOSE_FILE`.

### Repository Layout

```text
.
├── CHANGELOG.md                      # [Upstream] Release notes for self-hosted Docker snapshots
├── CONFIG.md                         # [Upstream] Configuration and architecture reference
├── versions.md                       # [Upstream] Tested container image version matrix
├── upgrades.json                     # [Upstream] Automated upgrade path & migration manifest
│
├── docker-compose.yml                # [Upstream] Core Supabase service stack (untouched)
├── docker-compose.caddy.yml          # [Upstream] Caddy reverse proxy & automatic TLS overlay
├── docker-compose.envoy.yml          # [Upstream] Envoy API gateway overlay
├── docker-compose.kong.yml           # [Upstream] Kong API gateway overlay
├── docker-compose.nginx.yml          # [Upstream] Nginx reverse proxy overlay
├── docker-compose.logs.yml           # [Upstream] Vector & Logflare analytics overlay
├── docker-compose.pg15.yml           # [Upstream] PostgreSQL 15 engine overlay
├── docker-compose.pg17.yml           # [Upstream] PostgreSQL 17 engine overlay
├── docker-compose.pgbouncer.yml      # [Upstream] PgBouncer connection pooler overlay
├── docker-compose.rustfs.yml         # [Upstream] RustFS S3-compatible local storage overlay
├── docker-compose.s3.yml             # [Upstream] External S3 storage backend overlay
├── docker-compose.nodewave.yml       # [Nodewave] JSON log rotation & asymmetric JWT/JWKS env mappings
├── docker-compose.caddy.nodewave.yml # [Nodewave] Caddy restart policy & JSON log rotation
│
├── .env.example                      # [Upstream] Base environment template (untouched)
├── .env.nodewave.example             # [Nodewave] COMPOSE_FILE layering, domain & port lockdown
├── .upstream-version                 # [Nodewave] Tracks the synced upstream self-hosted/v* tag
├── .gitattributes                    # [Upstream] Line-ending & file attribute rules
├── .gitignore                        # [Upstream] Git ignore rules for .env, volumes & backups
│
├── setup.sh                          # [Upstream] Interactive initial environment setup helper
├── run.sh                            # [Upstream] Primary stack lifecycle CLI (start/stop/pull/status)
├── update.sh                         # [Upstream] Version-aware upstream upgrade runner
├── reset.sh                          # [Upstream] Destructive local stack & volume reset script
│
├── nodewave/                         # [Nodewave] Management overlay & operational scripts
│   ├── manage.sh                     # Unified CLI (bootstrap, env export, key rotation, profiles, upgrades)
│   ├── bootstrap.sh                  # Backward-compatible entrypoint delegating to manage.sh bootstrap
│   ├── upgrade.sh                    # Interactive version upgrader (standalone & submodule, image cleanup, rollback)
│   └── backup.sh                     # Atomic pg_dumpall + pgsodium Vault key backup with retention pruning
│
├── utils/                            # [Upstream] Key rotation, DB password & PG17 upgrade scripts
│   ├── add-new-auth-keys.sh
│   ├── db-passwd.sh
│   ├── generate-keys.sh
│   ├── reassign-owner.sh
│   ├── rotate-new-api-keys.sh
│   └── upgrade-pg17.sh
│
├── volumes/                          # [Upstream] Mounted service configs & DB init SQL
│   ├── api/                          # Envoy & Kong gateway routing configurations
│   ├── db/                           # Postgres init scripts, roles, JWT, realtime & webhooks SQL
│   ├── functions/                    # Deno Edge Functions runtime & sample handlers
│   ├── logs/                         # Vector log pipeline configuration (vector.yml)
│   ├── pooler/                       # Supavisor / connection pooler config (pooler.exs)
│   ├── proxy/                        # Caddy & Nginx reverse proxy templates
│   └── realtime/                     # Realtime container entrypoint
│
├── dev/                              # [Upstream] Local development compose & seed data
├── tests/                            # [Upstream] Integration & upgrade verification test suites
└── .github/
    └── workflows/                    # [Nodewave] Automated upstream tracking & release CI
        ├── sync-upstream.yml         # Daily PR sync for new upstream self-hosted/v* tags
        ├── release-version.yml       # Auto-tags vX.Y.Z & creates release/vX.Y.Z on merge
        ├── sync-overlay.yml          # Opens PRs to backport nodewave/ overlay updates to release/v*
        └── backfill-versions.yml     # Manual workflow to import historical releases
```

## Versioning & Branching Model

Rather than tracking a single moving branch, every synced upstream `self-hosted/v*` release is preserved as an immutable
tag and a dedicated release branch:

| Ref Type           | Example          | Purpose                                                                                                                          |
|:-------------------|:-----------------|:---------------------------------------------------------------------------------------------------------------------------------|
| **`main`**         | `main`           | Tracks the latest synced upstream release and newest Nodewave overlay changes.                                                   |
| **Immutable Tag**  | `v0.8.4`         | Exact point-in-time snapshot of upstream `self-hosted/v0.8.4` + Nodewave overlay. Recommended for production pins and rollbacks. |
| **Release Branch** | `release/v0.8.4` | Receives Nodewave overlay/script PRs via `sync-overlay.yml` while holding the underlying Supabase stack fixed at `v0.8.4`.       |

## Quick Start

### Prerequisites

* **Docker Engine** and **Docker Compose v2** installed.
* **OpenSSL** (standard on Linux/macOS) and **Node.js >= 16** (optional; falls back to `node:22-alpine` via Docker
  automatically when generating asymmetric ES256 keys).
* For production servers: a domain with DNS `A`/`AAAA` records pointing to the host and ports **`80/tcp`** &
  **`443/tcp`** open.

### Option A: Local Development Setup

Clone the repository and run `bootstrap --local` to generate `.env`, mint all symmetric and asymmetric keys, configure
`http://localhost:8000` (with Caddy disabled), print your application `.env` keys, and start the containers:

```bash
git clone https://github.com/NodeWave-EA/supabase-docker.git
cd supabase-docker
./nodewave/manage.sh bootstrap --local --start
```

### Option B: Single-Server Production Deployment

Clone a pinned release tag (or `release/v*` branch) and bootstrap with your public domain:

```bash
git clone --branch v0.8.4 https://github.com/NodeWave-EA/supabase-docker.git /srv/supabase
cd /srv/supabase
./nodewave/manage.sh bootstrap -d supabase.nodewave.net --start -y
```

Once Caddy issues the Let's Encrypt TLS certificate, Supabase Studio and the API gateway are live at
`https://supabase.nodewave.net`.

### Option C: Multiple Instances on a Shared Server

Use `--project-name` (`-p`) and `--port-offset` (`-o`) to isolate Docker container names, networks, and localhost ports
across multiple projects on one VPS. When `--port-offset > 0`, bundled Caddy is automatically disabled so a single
shared reverse proxy on the host can route traffic by domain:

```bash
# Instance 1: Project Alpha -> gateway on 127.0.0.1:8001, Postgres on 5433
git clone --branch v0.8.4 https://github.com/NodeWave-EA/supabase-docker.git /srv/project-alpha
(cd /srv/project-alpha && ./nodewave/manage.sh bootstrap -d alpha.nodewave.net -p supabase-alpha -o 1 --start -y)

# Instance 2: Project Beta -> gateway on 127.0.0.1:8002, Postgres on 5434
git clone --branch v0.8.4 https://github.com/NodeWave-EA/supabase-docker.git /srv/project-beta
(cd /srv/project-beta && ./nodewave/manage.sh bootstrap -d beta.nodewave.net -p supabase-beta -o 2 --start -y)
```

Route both domains through your shared host Caddyfile:

```caddyfile
alpha.nodewave.net {
    reverse_proxy 127.0.0.1:8001
}

beta.nodewave.net {
    reverse_proxy 127.0.0.1:8002
}
```

### Option D: Embedding as a Git Submodule in a Project Repo

To pin a specific Supabase version inside an application repository (e.g., at `docker/supabase`):

```bash
git submodule add -b release/v0.8.4 https://github.com/NodeWave-EA/supabase-docker.git docker/supabase
git config -f .gitmodules submodule.docker/supabase.ignore dirty
```

To pull Nodewave overlay updates on that release branch or upgrade to a newer Supabase version later:

```bash
# Interactive upgrade wizard (updates submodule, .env keys, containers, old images & parent git commit)
./docker/supabase/nodewave/upgrade.sh
```

## Connecting Applications (Frontend, Backend & Database)

During `bootstrap`, all generated client credentials and connection strings are printed to stdout and saved locally to
`.env.clients` (automatically excluded from Git).

You can export formatted `.env` blocks directly into your Frontend, Backend, or ORM projects at any time:

```bash
# Print all client, server, Postgres pooler, S3, and Studio credentials
./nodewave/manage.sh env

# Export Next.js variables directly into a frontend project
./nodewave/manage.sh env --format nextjs > ../my-frontend/.env.local

# Export Vite / SPA variables
./nodewave/manage.sh env --format vite > ../my-vite-app/.env.local

# Export Backend + Prisma/Drizzle (DATABASE_URL & DIRECT_URL) + S3 storage variables
./nodewave/manage.sh env --format backend > ../my-backend/.env

# Export machine-readable JSON
./nodewave/manage.sh env --format json
```

## Management CLI Reference (`nodewave/manage.sh`)

`nodewave/manage.sh` provides a single control plane on top of Supabase's upstream scripts (`run.sh`, `utils/*`,
`update.sh`, `reset.sh`):

| Command                      | Description                                                                                                                                                                                               |
|:-----------------------------|:----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `bootstrap [options]`        | First-clone setup: creates `.env`, generates symmetric + asymmetric ES256 keys, configures ports/overlays, saves `.env.clients`, and optionally starts services. (`./nodewave/bootstrap.sh` is an alias.) |
| `env [--format <fmt>]`       | Prints ready-to-use client `.env` variables (`all`, `nextjs`, `vite`, `backend`, or `json`).                                                                                                              |
| `rotate-keys [mode]`         | Rotates opaque API keys (`--api`), ES256 JWKS + API keys (`--auth`), Postgres passwords (`--db`), or all (`--all`), then refreshes `.env.clients`.                                                        |
| `profile [list\|add\|rm]`    | Lists active `COMPOSE_FILE` layers or enables/disables overlays (`pg17`, `rustfs`, `s3`, `kong`, `logs`, `pgbouncer`, etc.).                                                                              |
| `start` / `stop` / `restart` | Starts, stops, or restarts all services in the active `COMPOSE_FILE` chain.                                                                                                                               |
| `status`                     | Displays container health and port bindings.                                                                                                                                                              |
| `logs [service]`             | Follows container logs (`--tail=100`) for all services or a specific service (e.g., `auth`, `db`, `rest`).                                                                                                |
| `backup [options]`           | Creates an atomic, checksum-verified `pg_dumpall` + `pgsodium_root.key` backup under `backups/` with automatic retention pruning (`./nodewave/backup.sh`).                                                |
| `upgrade [version] [opts]`   | Launches the interactive upgrade wizard (`./nodewave/upgrade.sh`) supporting standalone and submodule deployments, `.env` key sync, old image cleanup, and `--rollback`.                                  |
| `doctor`                     | Audits `.env` placeholders, asymmetric keys, `COMPOSE_FILE` paths, upstream file cleanliness, and service health.                                                                                         |
| `reassign-owner`             | Reassigns `public` schema objects from `supabase_admin` to `postgres` (`utils/reassign-owner.sh`).                                                                                                        |
| `upgrade-pg17`               | Executes the in-place PostgreSQL 15 to 17 major upgrade (`utils/upgrade-pg17.sh`).                                                                                                                        |
| `reset`                      | Stops containers and wipes local volumes (`reset.sh`).                                                                                                                                                    |

### Common `bootstrap` Flags

* `--local`: Configures `http://localhost:8000` and disables Caddy for local development.
* `-d, --domain <domain>`: Sets the public domain (e.g., `supabase.nodewave.net`).
* `-p, --project-name <name>`: Sets `COMPOSE_PROJECT_NAME` and prefixes all container names (`<name>-<service>`).
* `-o, --port-offset <N>`: Shifts host ports by `N` (`8000+N`, `8443+N`, `5432+N`, `6543+N`) and checks for port
  collisions before writing `.env`.
* `--site-url <url>`: Overrides `SITE_URL` for auth redirects (defaults to `http://localhost:3000` in `--local` mode or
  `https://<domain>` in production).
* `--pg17` / `--rustfs` / `--s3` / `--kong` / `--logs`: Appends the corresponding upstream Compose overlay during
  initial setup.
* `--no-caddy` / `--with-caddy`: Explicitly disables or force-enables the bundled Caddy reverse proxy.
* `--skip-auth-keys`: Skips generating asymmetric ES256 `JWT_KEYS`/`JWT_JWKS` and opaque API keys.
* `--start`: Starts the stack immediately once bootstrap completes.
* `-f, --force`: Backs up an existing `.env` before re-running bootstrap.
* `-y, --yes`: Runs non-interactively without confirmation prompts.

## Day-2 Operations

### Database & Vault Key Backups (`nodewave/backup.sh`)

`./nodewave/backup.sh` writes backups atomically (preventing corrupt partial archives on failure), verifies gzip stream
integrity, records a `.sha256` checksum, exports `/etc/postgresql-custom/pgsodium_root.key` (required to decrypt
Supabase Vault secrets on restore), and prunes older snapshots automatically:

```bash
# Create backup and retain the latest 14 snapshots (default)
./nodewave/backup.sh

# Customize output directory and retention count (0 = keep all)
./nodewave/backup.sh --out-dir /mnt/backups --keep 30

# Quiet mode for automated daily cron jobs (prints only the archive path on success)
0 2 * * * /srv/supabase/nodewave/backup.sh --quiet >> /var/log/supabase-backup.log 2>&1
```

To restore a backup:

```bash
# 1. Verify archive integrity
(cd backups && sha256sum -c supabase-db-20261124T020000Z.sql.gz.sha256)

# 2. Restore SQL cluster dump
gunzip -c backups/supabase-db-20261124T020000Z.sql.gz | docker compose exec -T db psql -U supabase_admin -d postgres
```

### Upgrading to a Newer Version (`nodewave/upgrade.sh`)

`./nodewave/upgrade.sh` (also available via `./nodewave/manage.sh upgrade`) works identically in **standalone** clones
and **parent repositories** that embed `supabase-docker` as a Git submodule:

```bash
# Interactive mode: selects parent compose file (if submodule), picks version/channel,
# backs up DB & .env, previews CHANGELOG.md, syncs missing .env keys, restarts containers,
# interactively cleans up old Docker images, and commits + pushes the submodule bump
./nodewave/upgrade.sh

# Or from a parent repo root:
./docker/supabase/nodewave/upgrade.sh

# Preview what upgrading to v0.8.5 would change without touching files or containers
./nodewave/upgrade.sh v0.8.5 --dry-run

# Non-interactive upgrade on a submodule repo (tracks release/v0.8.5, removes all old images, commits)
./docker/supabase/nodewave/upgrade.sh v0.8.5 --channel release --prune-images all --commit -y
```

#### Upgrade Features & Safety Guards

* **Channel Selection (`--channel release|tag`):** Choose between tracking `release/vX.Y.Z` (recommended for submodules
  so `sync-overlay.yml` patches apply cleanly) or pinning an immutable `vX.Y.Z` tag.
* **Environment Key Sync:** Compares `.env`, `.env.development`, and `.env.production` against `.env.example`, offers
  to append newly introduced keys, and can generate asymmetric ES256 keys if missing.
* **PostgreSQL Major Version Guard:** Detects if an existing Postgres 15 volume would be started against a Postgres 17
  image and warns before proceeding so you can enable `docker-compose.pg15.yml` or run `utils/upgrade-pg17.sh`.
* **Interactive Previous-Version Image Cleanup (`--prune-images all|select|dangling|skip`):** Snapshots image IDs
  before pulling, filters out any image still referenced by the new stack or other projects on the host, displays
  reclaimable disk space, and lets you delete all superseded images, pick specific numbers (`1,3,5-7`), prune dangling
  layers, or skip cleanup to preserve instant rollback speed.
* **Submodule Git Integration (`--commit`, `--push`):** Updates `.gitmodules` branch tracking, stages the submodule
  gitlink in the parent repository, and optionally commits and pushes the bump.

### Rolling Back

If an upgrade introduces issues—or if post-upgrade container health checks detect failures—revert to the exact
pre-upgrade commit, `.env` snapshot, `.gitmodules` branch, and containers in one step:

```bash
./nodewave/upgrade.sh --rollback
```

*(If database schema migrations ran during the failed upgrade, restore your pre-upgrade `.sql.gz` snapshot from
`backups/` as shown in the backup section above.)*

## Security & Operational Defaults

* **Complete Key Provisioning Out of the Box:** `bootstrap` runs both `utils/generate-keys.sh` (minting `JWT_SECRET`,
  `ANON_KEY`, `SERVICE_ROLE_KEY`, database, and Studio passwords) and `utils/add-new-auth-keys.sh` (minting ES256
  `JWT_KEYS`/`JWT_JWKS` and `SUPABASE_PUBLISHABLE_KEY`/`SUPABASE_SECRET_KEY`).
* **Clean Upstream Compose Files:** `docker-compose.nodewave.yml` maps `GOTRUE_JWT_KEYS`, `API_JWT_JWKS`, `JWT_JWKS`,
  and `SUPABASE_JWKS` directly via Compose overlay so `docker-compose.yml` never needs in-place edits.
* **Localhost Gateway Binding:** `.env.nodewave.example` binds `API_GW_HTTP_PORT` / `KONG_HTTP_PORT` (`127.0.0.1:8000`)
  and `KONG_HTTPS_PORT` (`127.0.0.1:8443`) to loopback so unencrypted gateway ports are never exposed publicly.
* **Automatic Log Rotation:** `docker-compose.nodewave.yml` and `docker-compose.caddy.nodewave.yml` configure Docker's
  `json-file` driver (`max-size: 25m`, `max-file: 5`) across core Supabase services to prevent container logs from
  exhausting disk space.

## Upstream Sync & CI Workflows

| Workflow                    | Trigger                      | Behavior                                                                                                                                                                |
|:----------------------------|:-----------------------------|:------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`sync-upstream.yml`**     | Daily (`06:00 UTC`) & Manual | Checks `supabase/supabase` for a newer `self-hosted/v*` tag, sparse-clones `docker/` to root, updates `.upstream-version`, and opens a Pull Request against `main`.     |
| **`release-version.yml`**   | Automatic on merge to `main` | When `.upstream-version` changes on `main`, creates the corresponding `vX.Y.Z` tag, updates `release/vX.Y.Z`, and publishes a GitHub Release.                           |
| **`sync-overlay.yml`**      | Push to `main` (`nodewave/`) | Propagates changes to `nodewave/`, `docker-compose.nodewave.yml`, `docker-compose.caddy.nodewave.yml`, and `.env.nodewave.example` to all `release/v*` branches via PR. |
| **`backfill-versions.yml`** | Manual (`workflow_dispatch`) | Imports the last *N* historical `self-hosted/v*` releases in chronological order, creating tags and release branches for each.                                          |

### Initial Repository Setup (Maintainers)

1. In GitHub **Settings → Actions → General**, enable **Read and write permissions** and check **Allow GitHub Actions to
   create and approve pull requests**.
2. Push this repository to `main`.
3. Open **Actions → Backfill Historical Supabase Versions**, click **Run workflow**, and enter how many recent releases
   to import (e.g., `5`).