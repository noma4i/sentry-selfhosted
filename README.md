# Sentry Self-Hosted (Lightweight)

A memory-optimized build of [Sentry](https://sentry.io) self-hosted v26.3.1 that runs comfortably on **4 GB RAM** and handles thousands of events without issues.

The main trade-off is **no Symbolicator** — native stack trace symbolication (iOS, Android NDK, C/C++) is disabled. If you only monitor web applications (Python, Ruby, Node.js, etc.), this doesn't affect you at all. Symbolicator can be added back as a separate container when needed.

17 containers with memory limits, errors-only profile, built from source.

## Limitations

- **Raspberry Pi is not supported.** Sentry and its dependencies (ClickHouse, Confluent Kafka, Relay) only provide images and binaries for `linux/amd64` and `linux/arm64` (64-bit). Raspberry Pi models 1-3 use `armv7l` (32-bit ARM) which is incompatible. Raspberry Pi 4/5 running a **64-bit OS** (e.g. Raspberry Pi OS 64-bit, Ubuntu arm64) should work in theory, but hasn't been tested and will likely struggle with 4 GB RAM on the smaller models.
- **No Symbolicator** — see above.
- **No profiling, replays, metrics, uptime checks** — errors-only profile.

## Quick Start

```bash
git clone git@github.com:noma4i/sentry-selfhosted.git
cd sentry-selfhosted
./init.sh
```

`init.sh` automatically:
- Builds all images from source (`build.sh`: sentry, snuba, taskbroker)
- Generates secret key and relay credentials
- Starts infrastructure (Postgres, Redis, Kafka, ClickHouse, SeaweedFS)
- Creates Kafka topics, ClickHouse tables, S3 buckets
- Runs database migrations
- Creates admin user

After completion:
- **URL**: http://localhost:9000
- **Email**: `admin@localhost`
- **Password**: `admin123`

Subsequent starts (after `docker compose down`):

```bash
docker compose up -d
```

## Architecture

### Services

| Service | Port | Purpose |
|---------|------|---------|
| nginx | 9000 (host) | Reverse proxy, entry point |
| relay | 3000 | SDK event ingestion |
| web | 9000 | Sentry UI and API |
| events-consumer | — | Inbound event processing |
| post-process-forwarder | — | Error post-processing |
| snuba-api | 1218 | Query engine (ClickHouse) |
| snuba-errors-consumer | — | Writes events to ClickHouse |
| taskbroker / taskworker / taskscheduler | — | Background tasks |
| postgres + pgbouncer | 5432 | Primary database |
| redis | 6379 | Cache, queues, Django cache, rate limiting |
| kafka | 9092 | Event streaming (KRaft mode) |
| clickhouse | 8123 | Analytics database |
| seaweedfs | 8333 | S3-compatible storage (nodestore) |
| smtp | 25 | Email notifications |

### Key Architectural Changes

Compared to the original `getsentry/self-hosted`, this build makes the following architectural decisions to reduce memory footprint:

- **Memcached eliminated.** The original uses a dedicated Memcached container for Django cache (sourcemaps, sessions). We route all caching through **Redis** (db=1 for cache, db=0 for queues/buffers), removing one container and its memory overhead entirely.

- **Kafka JVM heap capped at 256 MB.** Confluent's cp-kafka defaults to 512 MB heap. For a single-broker local setup with low throughput, 256 MB is sufficient and saves ~250 MB.

- **ClickHouse tuned for low memory.** System logs (query_log, metric_log, trace_log, etc.) are disabled. Uncompressed and mark caches reduced to 8-16 MB. Per-query memory limit set to 150 MB. Baseline drops from ~650 MB to ~300 MB. Note: INSERT batches from Snuba can peak at ~1 GB, so the container limit is 2 GB.

- **Sentry web: 1 worker, 2 threads.** The original runs 3 workers with 4 threads each (~1.5 GB). A single worker with 2 threads is enough for local use and keeps memory under 700 MB. `reload-on-rss` is set to 400 MB to recycle workers before they leak.

- **Taskworker concurrency reduced to 1.** The original uses 4 parallel task processes. With concurrency=1, background task processing uses ~400 MB instead of ~750 MB.

- **Postgres tuned.** `shared_buffers=32MB`, `work_mem=4MB`, `maintenance_work_mem=32MB`. Sufficient for the workload and keeps Postgres under 100 MB.

### Data Flow

```
SDK -> nginx -> relay -> kafka (ingest-events)
  -> events-consumer -> kafka (events) -> snuba-errors-consumer -> ClickHouse
                      -> postgres (issues, groups)
                      -> seaweedfs (raw event data)
```

## Changes from the Original

The original `getsentry/self-hosted` runs ~50 containers in feature-complete mode and expects 16+ GB RAM. This build strips it down to 17 containers and 3-3.5 GB by cutting non-essential features and tuning every service for lower memory.

| Component | Original | This Build | Why |
|-----------|----------|------------|-----|
| **Total containers** | ~50 | 17 | errors-only profile, no profiling/replays/metrics pipeline |
| **Total RAM** | 16+ GB | 3-3.5 GB | Every service tuned, non-essential removed |
| **Error tracking** | Yes | Yes | Full pipeline preserved: ingestion, processing, storage, UI |
| **REST API** | Yes | Yes | Fully functional |
| **Alerting & email** | Yes | Yes | SMTP included |
| **Issue management** | Yes | Yes | Assign, resolve, merge, search |
| **Discover & Dashboards** | Yes | Yes | Event search, custom dashboards |
| **Integrations** | Yes | Yes | GitHub, Slack, Jira, etc. via UI |
| **SSO** | Yes | Yes | SAML2, OAuth |
| **Profiling** | vroom + 6 consumers | Removed | Saves ~3 containers and ~500 MB. Continuous profiling not needed for error tracking |
| **Session Replays** | replay consumers | Removed | Saves ~2 containers. Replay recording is separate from error monitoring |
| **Custom Metrics** | metrics + generic-metrics consumers | Removed | Saves ~6 containers. Sentry's built-in metrics still work for errors |
| **Symbolicator** | Dedicated container | Removed | Saves ~300 MB. Only needed for native code (iOS, Android NDK, C++). Web apps unaffected |
| **Uptime Checker** | Dedicated container | Removed | Saves ~100 MB. URL monitoring is a separate concern |
| **Memcached** | Dedicated container | Removed | Django cache moved to Redis (db=1). One less container, no functionality lost |
| **Attachments consumer** | Dedicated consumer | Removed | Event attachments not processed. Raw events still stored in nodestore |
| **Cleanup cron jobs** | sentry-cleanup, vroom-cleanup | Removed | Manual cleanup via `docker compose exec`. No automatic data expiry |
| **Kafka JVM heap** | 512 MB (default) | 256 MB | Sufficient for single-broker local setup. Saves ~250 MB |
| **Sentry web workers** | 3 workers, 4 threads | 1 worker, 2 threads | Adequate for single-user or low-traffic. Saves ~500 MB |
| **Taskworker concurrency** | 4 processes | 1 process | Background tasks run sequentially. Saves ~350 MB |
| **Postgres config** | Default (shared_buffers=128MB) | shared_buffers=32MB, work_mem=4MB | Tuned for small dataset. Saves ~50 MB |
| **Redis** | maxmemory unlimited | maxmemory 100MB | Handles cache + queues. Also serves as Django cache (replaces Memcached) |
| **ClickHouse** | Default caches + system logs | Small caches (8-16 MB), all system logs disabled | Baseline drops from ~650 MB to ~300 MB |
| **Init process** | `install.sh` (29 shell scripts) | `init.sh` (1 script, 10 steps) | Simplified, idempotent |
| **Image source** | Pull from GHCR | Build from source | Full control over the build |

## Memory Limits

| Service | mem_limit | Actual Usage |
|---------|-----------|--------------|
| clickhouse | 2 GB | 250-360 MB idle, ~1 GB peak |
| web | 1 GB | 500-700 MB |
| kafka | 512 MB | 250-300 MB |
| events-consumer | 512 MB | ~450 MB |
| post-process | 512 MB | ~440 MB |
| snuba-api | 512 MB | ~320 MB |
| taskworker | 512 MB | ~400 MB |
| taskscheduler | 384 MB | ~260 MB |
| postgres | 256 MB | ~80 MB |
| snuba-errors-consumer | 256 MB | ~165 MB |
| relay | 256 MB | ~60 MB |
| redis | 128 MB | ~7 MB |
| seaweedfs | 128 MB | ~70 MB |
| taskbroker | 128 MB | ~20 MB |
| smtp, pgbouncer, nginx | 64 MB | 2-15 MB |

## File Structure

```
.
├── docker-compose.yml      # 17 services with mem_limit
├── .env                    # Image versions, ports
├── init.sh                 # Full bootstrap (idempotent)
├── build.sh                # Build images from source
├── nginx-local.conf        # Nginx routing
├── redis-local.conf        # Redis config (100MB limit)
├── sentry-conf/
│   ├── Dockerfile          # Sentry overlay (S3 nodestore + custom configs)
│   ├── entrypoint.sh       # CA certificates + Django entrypoint
│   ├── sentry.conf.py      # Django settings (1 worker, Redis cache)
│   └── config.yml          # YAML config (mail, filestore)
├── relay-conf/
│   ├── config.yml          # Relay config (processing mode)
│   └── credentials.json    # Generated by init.sh
├── clickhouse-conf/
│   ├── config.xml          # ClickHouse tuning (small caches, no logs)
│   └── default-password.xml
├── geoip/                  # GeoIP data (optional)
└── source/                 # Service source code (v26.3.1)
    ├── sentry/             # Main service (Python/Django)
    ├── snuba/              # Query engine (Python)
    ├── relay/              # Event ingestion (Rust)
    ├── symbolicator/       # Symbol processing (Rust)
    ├── vroom/              # Profiling (Go)
    ├── taskbroker/         # Task broker (Rust)
    ├── uptime-checker/     # Uptime monitoring (Rust)
    └── self-hosted/        # Original orchestration (Shell)
```

### Build from Source

`build.sh` builds the following images locally from `source/`:

| Image | Source | Dockerfile |
|-------|--------|------------|
| `sentry-base-local` | `source/sentry/` | `source/sentry/self-hosted/Dockerfile` |
| `sentry-self-hosted-local` | `sentry-conf/` | `sentry-conf/Dockerfile` (overlay) |
| `snuba-local` | `source/snuba/` | `source/snuba/Dockerfile` |
| `taskbroker-local` | `source/taskbroker/` | `source/taskbroker/Dockerfile` |

Relay uses a pre-built image (Rust compilation requires 30+ min and 4+ GB RAM).

## Important Notes

- **ClickHouse**: requires `altinity/clickhouse-server:25.3.6` — Snuba migrations depend on this specific build
- **SeaweedFS**: `-ip=seaweedfs` is required for S3 redirects to work between containers
- **Relay**: credentials are generated and registered automatically via `init.sh`
- **Kafka topics**: Sentry ingest topics are created separately from Snuba bootstrap (both handled by `init.sh`)
