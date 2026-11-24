# Nodewave Supabase Self-Hosted

A lightweight, multi-versioned deployment baseline for
self-hosted [Supabase](https://supabase.com/docs/guides/self-hosting/docker). This repository extracts Supabase’s
official `docker/` stack to the root and layers Nodewave’s production defaults, automatic Caddy TLS, localhost port
lockdown, container log rotation, and zero-touch bootstrap/backup scripts without modifying upstream files.

## Architecture: Clean Base + Nodewave Overlay

To prevent merge conflicts during upstream upgrades, this repository enforces a strict two-layer separation:

1. **Untouched Upstream Layer (Root):** Files synced directly from [
   `supabase/supabase/docker`](https://github.com/supabase/supabase/tree/master/docker) including `docker-compose.yml`,
   modular compose overlays (`caddy`, `envoy`, `kong`, `nginx`, `pg15`/`pg17`, `pgbouncer`, `s3`/`rustfs`, `logs`),
   lifecycle scripts (`setup.sh`, `run.sh`, `update.sh`, `reset.sh`), `utils/`, `volumes/`, `tests/`, and release
   metadata (`CHANGELOG.md`, `CONFIG.md`, `versions.md`, `upgrades.json`). **Never edit these manually.**
2. **Nodewave Overlay Layer:** Custom infrastructure configuration, environment defaults, CI sync workflows, and
   operational scripts isolated in dedicated files merged automatically via `COMPOSE_FILE`.

### Repository Layout

```text
.
├── CHANGELOG.md                  # [Upstream] Release notes for self-hosted Docker snapshots
├── CONFIG.md                     # [Upstream] Configuration and architecture reference
├── versions.md                   # [Upstream] Tested container image version matrix
├── upgrades.json                 # [Upstream] Automated upgrade path & migration manifest
│
├── docker-compose.yml            # [Upstream] Core Supabase service stack (untouched)
├── docker-compose.caddy.yml      # [Upstream] Caddy reverse proxy & automatic TLS overlay
├── docker-compose.envoy.yml      # [Upstream] Envoy API gateway overlay
├── docker-compose.kong.yml       # [Upstream] Kong API gateway overlay
├── docker-compose.nginx.yml      # [Upstream] Nginx reverse proxy overlay
├── docker-compose.logs.yml       # [Upstream] Vector & Logflare analytics overlay
├── docker-compose.pg15.yml       # [Upstream] PostgreSQL 15 engine overlay
├── docker-compose.pg17.yml       # [Upstream] PostgreSQL 17 engine overlay
├── docker-compose.pgbouncer.yml  # [Upstream] PgBouncer connection pooler overlay
├── docker-compose.rustfs.yml     # [Upstream] RustFS S3-compatible local storage overlay
├── docker-compose.s3.yml         # [Upstream] External S3 storage backend overlay
├── docker-compose.nodewave.yml   # [Nodewave] JSON log rotation & Caddy restart policy
│
├── .env.example                  # [Upstream] Base environment template (untouched)
├── .env.nodewave.example         # [Nodewave] COMPOSE_FILE layering, domain & port lockdown
├── .upstream-version             # [Nodewave] Tracks the synced upstream self-hosted/v* tag
├── .gitattributes                # [Upstream] Line-ending & file attribute rules
├── .gitignore                    # [Upstream] Git ignore rules for .env, volumes & backups
│
├── setup.sh                      # [Upstream] Interactive initial environment setup helper
├── run.sh                        # [Upstream] Primary stack lifecycle CLI (start/stop/pull/status)
├── update.sh                     # [Upstream] Version-aware upstream upgrade runner
├── reset.sh                      # [Upstream] Destructive local stack & volume reset script
│
├── nodewave/                     # [Nodewave] Operational scripts
│   ├── bootstrap.sh              # Generates .env, cryptographic secrets & JWT/JWK keys
│   └── backup.sh                 # Creates timestamped gzipped pg_dumpall snapshots
│
├── utils/                        # [Upstream] Key rotation, DB password & PG17 upgrade scripts
│   ├── add-new-auth-keys.sh
│   ├── db-passwd.sh
│   ├── generate-keys.sh
│   ├── reassign-owner.sh
│   ├── rotate-new-api-keys.sh
│   └── upgrade-pg17.sh
│
├── volumes/                      # [Upstream] Mounted service configs & DB init SQL
│   ├── api/                      # Envoy & Kong gateway routing configurations
│   ├── db/                       # Postgres init scripts, roles, JWT, realtime & webhooks SQL
│   ├── functions/                # Deno Edge Functions runtime & sample handlers
│   ├── logs/                     # Vector log pipeline configuration (vector.yml)
│   ├── pooler/                   # Supavisor / connection pooler config (pooler.exs)
│   ├── proxy/                    # Caddy & Nginx reverse proxy templates
│   └── realtime/                 # Realtime container entrypoint
│
├── dev/                          # [Upstream] Local development compose & seed data
├── tests/                        # [Upstream] Integration & upgrade verification test suites
└── .github/
    └── workflows/                # [Nodewave] Automated upstream tracking & release CI
        ├── sync-upstream.yml     # Daily PR sync for new upstream self-hosted/v* tags
        ├── release-version.yml   # Auto-tags vX.Y.Z & creates release/vX.Y.Z on merge
        └── backfill-versions.yml # Manual workflow to import historical releases
```

## Versioning & Branching Model

Rather than tracking a single moving branch, every synced upstream `self-hosted/v*` release is preserved as an immutable
tag and a dedicated release branch:

| Ref Type           | Example          | Purpose                                                                                                                          |
|:-------------------|:-----------------|:---------------------------------------------------------------------------------------------------------------------------------|
| **`main`**         | `main`           | Tracks the latest synced upstream release and newest Nodewave overlay changes.                                                   |
| **Immutable Tag**  | `v0.8.4`         | Exact point-in-time snapshot of upstream `self-hosted/v0.8.4` + Nodewave overlay. Recommended for production pins and rollbacks. |
| **Release Branch** | `release/v0.8.4` | Receives Nodewave overlay/script patches while holding the underlying Supabase stack fixed at `v0.8.4`.                          |

## Quick Start (Server Deployment)

### Prerequisites

* Linux server with **Docker Engine** and **Docker Compose v2** installed.
* A public domain (e.g., `supabase.example.com`) with DNS `A` / `AAAA` records pointing to the server.
* Firewall ports **`80/tcp`** and **`443/tcp`** open for Caddy HTTP/HTTPS and automatic Let's Encrypt TLS provisioning.

### 1. Clone a Pinned Version

Clone a specific release tag (recommended) or maintenance branch:

```bash
git clone --branch v0.8.4 https://github.com/NodeWave-EA/supabase-docker.git
cd supabase-docker
```

*(To track overlay patches for a specific version without upgrading Supabase, clone `--branch release/v0.8.4` instead.)*

### 2. Bootstrap Environment & Secrets

Run the bootstrap script to generate `.env` from `.env.example` + `.env.nodewave.example`, configure your domain, mint
cryptographic keys via `utils/generate-keys.sh`, and stamp `.supabase-version`:

```bash
./nodewave/bootstrap.sh
```

Review `.env` afterward to configure optional integrations (such as custom SMTP credentials) or append additional
upstream compose overlays to `COMPOSE_FILE` (e.g., `docker-compose.pg17.yml`, `docker-compose.s3.yml`, or
`docker-compose.pgbouncer.yml`).

### 3. Start the Stack

```bash
sh run.sh start
```

Verify all services are healthy:

```bash
sh run.sh status
```

Once Caddy issues the TLS certificate, Supabase Studio and the API gateway are accessible at `https://<your-domain>`.

## Day-2 Operations

### Database Backups

Create a compressed full-cluster PostgreSQL snapshot (`backups/supabase-db-<UTC-TIMESTAMP>.sql.gz`) at any time—and
always before upgrading:

```bash
./nodewave/backup.sh
```

### Upgrading to a Newer Version

1. **Back up the database:**
   ```bash
   ./nodewave/backup.sh
   ```
2. **Fetch tags and check out the target version:**
   ```bash
   git fetch --tags origin
   git checkout v0.8.5
   ```
3. **Check for new environment variables & migration notes:** Inspect `CHANGELOG.md`, `upgrades.json`, and
   `.env.example` against your active `.env` and add any newly required keys (or run `utils/add-new-auth-keys.sh` if
   asymmetric auth keys were added).
4. **Pull updated images and recreate containers:**
   ```bash
   sh run.sh pull
   sh run.sh start
   ```

### Rolling Back

If an upgrade introduces issues, check out the previous tag and restart the stack (restore your pre-upgrade backup from
`backups/` if database migrations ran):

```bash
git checkout v0.8.4
sh run.sh pull
sh run.sh start
```

## Security & Operational Defaults

* **Localhost Gateway Binding:** `.env.nodewave.example` binds `KONG_HTTP_PORT` (`127.0.0.1:8000`) and `KONG_HTTPS_PORT`
  (`127.0.0.1:8443`) to loopback so unencrypted gateway ports are never exposed publicly. All external traffic routes
  through Caddy on `80`/`443`.
* **Automatic Log Rotation:** `docker-compose.nodewave.yml` configures Docker's `json-file` driver (`max-size: 25m`,
  `max-file: 5`) across core Supabase services to prevent container logs from exhausting disk space.

## Upstream Sync & CI Workflows

| Workflow                    | Trigger                      | Behavior                                                                                                                                                            |
|:----------------------------|:-----------------------------|:--------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`sync-upstream.yml`**     | Daily (`06:00 UTC`) & Manual | Checks `supabase/supabase` for a newer `self-hosted/v*` tag, sparse-clones `docker/` to root, updates `.upstream-version`, and opens a Pull Request against `main`. |
| **`release-version.yml`**   | Automatic on merge to `main` | When `.upstream-version` changes on `main`, creates the corresponding `vX.Y.Z` tag, updates `release/vX.Y.Z`, and publishes a GitHub Release.                       |
| **`backfill-versions.yml`** | Manual (`workflow_dispatch`) | Imports the last *N* historical `self-hosted/v*` releases in chronological order, creating tags and release branches for each.                                      |

### Initial Repository Setup (Maintainers)

1. In GitHub **Settings → Actions → General**, enable **Read and write permissions** and check **Allow GitHub Actions to
   create and approve pull requests**.
2. Push this repository to `main`.
3. Open **Actions → Backfill Historical Supabase Versions**, click **Run workflow**, and enter how many recent releases
   to import (e.g., `5`).

## Bootstrapping Two Instances on One Server

```bash
# ./nodewave/bootstrap.sh --help

# Instance 1: Project Alpha -> gateway on 127.0.0.1:8001, Postgres on 5433
git clone --branch v0.8.4 https://github.com/Nodewave-EA/supabase-docker.git /srv/project-alpha
(cd /srv/project-alpha && ./nodewave/bootstrap.sh -d alpha.nodewave.net -p supabase-alpha -o 1 -y && sh run.sh start)

# Instance 2: Project Beta -> gateway on 127.0.0.1:8002, Postgres on 5434
git clone --branch v0.8.4 https://github.com/Nodewave-EA/supabase-docker.git /srv/project-beta
(cd /srv/project-beta && ./nodewave/bootstrap.sh -d beta.nodewave.net -p supabase-beta -o 2 -y && sh run.sh start)

```