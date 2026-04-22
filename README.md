# PgBunker

**Self-hosted Postgres on a small VPS.** One Docker Compose file. Pooling, monitoring, dashboards, backups, logs, and HTTPS — all set up by a single script.

Tested on **2 vCPU / 4 GB / 60 GB NVMe Ubuntu 24.04**. Runs on **1 vCPU / 2 GB** and **4 vCPU / 8 GB** with one edit to `.env`.

---

## What you get

| Component            | Version | Purpose                                                  |
| -------------------- | ------- | -------------------------------------------------------- |
| PostgreSQL           | 17      | Database, `pg_stat_statements` enabled on first start    |
| PgBouncer            | 1.24    | Transaction-mode pooler, optional TLS on `:6432`         |
| Prometheus           | 3.2     | Metrics + 14 alert rules                                 |
| Grafana              | 12      | DB and System dashboards, provisioned on start           |
| PgHero               | 3.7     | Slow queries, missing indexes, table bloat               |
| Dozzle               | 10.1    | Live log viewer with auth                                |
| postgres-exporter    | 0.17    | Postgres metrics                                         |
| pgbouncer-exporter   | 0.10    | Pool metrics                                             |
| node-exporter        | 1.8     | Host metrics + textfile collector for backup status      |
| Backup (S3)          | —       | Daily `pg_dumpall --globals-only` + per-database dump    |
| Host nginx + certbot | —       | HTTPS for admin UIs, optional TLS for Postgres           |

All containers have memory limits. The only public ports after setup are **22, 80, 443, and 6432** — everything else stays inside the Docker network or on `127.0.0.1`.

---

## Quick start

Requirements: Ubuntu 24.04, Docker + Compose installed, a domain whose DNS you control.

```bash
git clone https://github.com/amir-budaychiev/pgbunker.git
cd pgbunker

cp .env.example .env
nano .env                         # set passwords, DOMAIN, LE_EMAIL
./scripts/setup.sh                # render pgbouncer configs and dozzle auth
docker compose up -d              # start the stack
sudo ./scripts/nginx-setup.sh     # install nginx + certbot, HTTPS, UFW
```

Before the last command, point these DNS A-records at your VPS:

```
grafana.<DOMAIN>
pghero.<DOMAIN>
dozzle.<DOMAIN>
<DOMAIN>                          # only if PGBOUNCER_TLS=true
```

That's it. Certificates auto-renew via the `certbot.timer` systemd unit that ships with the certbot package — you don't have to schedule anything.

Optional — enable daily S3 backups once `S3_*` values in `.env` are real:

```bash
docker compose --profile backup up -d backup
```

---

## Services

| Service   | URL                          | Notes                          |
| --------- | ---------------------------- | ------------------------------ |
| Grafana   | `https://grafana.<DOMAIN>`   | Credentials from `.env`        |
| PgHero    | `https://pghero.<DOMAIN>`    | Credentials from `.env`        |
| Dozzle    | `https://dozzle.<DOMAIN>`    | Docker log viewer              |
| PgBouncer | `<DOMAIN>:6432` (TCP)        | Application endpoint           |

App connection string:

```
postgresql://user:password@<DOMAIN>:6432/dbname
```

With `PGBOUNCER_TLS=true`:

```
postgresql://user:password@<DOMAIN>:6432/dbname?sslmode=require
```

---

## TLS

Admin UIs are served over HTTPS by host nginx with a multi-SAN Let's Encrypt certificate. Nothing to do after `nginx-setup.sh`.

**TLS for Postgres connections is off by default.** Postgres uses a plaintext handshake to negotiate SSL (it's a protocol quirk), so nginx cannot terminate TLS for it. PgBouncer has to do it itself.

To turn it on, flip one flag:

```diff
# .env
- PGBOUNCER_TLS=false
+ PGBOUNCER_TLS=true
```

Then re-run the normal three commands. `setup.sh` and `nginx-setup.sh` handle the rest:

1. `setup.sh` adds the TLS block to `pgbouncer.ini` and generates a self-signed placeholder certificate so PgBouncer can start.
2. `nginx-setup.sh` includes `<DOMAIN>` in the certbot request alongside the admin subdomains, and installs a certbot deploy-hook at `/etc/letsencrypt/renewal-hooks/deploy/pgbunker.sh`. The hook copies renewed certs into `pgbouncer/certs/` and sends `SIGHUP` to PgBouncer. This happens automatically every 60 days for the life of the VPS.

If you don't need TLS — for example, your app and DB live in the same datacenter — keep it off and restrict port 6432 to the app server's IP:

```bash
sudo ufw delete allow 6432/tcp
sudo ufw allow from <APP_SERVER_IP> to any port 6432
```

SCRAM-SHA-256 still protects the password during authentication.

---

## Server sizes

Default `.env` is tuned for **2 vCPU / 4 GB / 60 GB NVMe**. For other sizes, edit `.env` — no other files change.

### Postgres

| Variable                    | 1 × 2 GB | 2 × 4 GB (default) | 4 × 8 GB |
| --------------------------- | -------- | ------------------ | -------- |
| `PG_MAX_CONNECTIONS`        | `50`     | `100`              | `200`    |
| `PG_SHARED_BUFFERS`         | `512MB`  | `1GB`              | `2GB`    |
| `PG_EFFECTIVE_CACHE_SIZE`   | `1GB`    | `3GB`              | `6GB`    |
| `PG_WORK_MEM`               | `4MB`    | `10MB`             | `20MB`   |
| `PG_MAINTENANCE_WORK_MEM`   | `128MB`  | `256MB`            | `512MB`  |
| `PG_AUTOVACUUM_MAX_WORKERS` | `1`      | `2`                | `3`      |

Rule of thumb: `shared_buffers ≈ 25 %` of RAM, `effective_cache_size ≈ 75 %`.

### Storage and safety

NVMe-tuned by default. For HDD, change the first two.

| Variable                       | Default | Notes                                              |
| ------------------------------ | ------- | -------------------------------------------------- |
| `PG_RANDOM_PAGE_COST`          | `1.1`   | `4` for HDD                                        |
| `PG_EFFECTIVE_IO_CONCURRENCY`  | `200`   | `1` for HDD, `2` for SATA SSD                      |
| `PG_STATEMENT_TIMEOUT`         | `0`     | `0` = off. Set per role instead — cluster-wide can |
|                                |         | kill analytics and migrations.                     |
| `PG_IDLE_IN_TX_TIMEOUT`        | `120s`  | Kills clients that `BEGIN` and then sleep.         |

### PgBouncer pools

Edit `pgbouncer/pgbouncer.ini.tmpl`, then re-run `./scripts/setup.sh`.

| Parameter           | 1 × 2 GB | 2 × 4 GB (default) | 4 × 8 GB |
| ------------------- | -------- | ------------------ | -------- |
| `default_pool_size` | `10`     | `20`               | `40`     |
| `max_client_conn`   | `100`    | `200`              | `400`    |
| `min_pool_size`     | `2`      | `5`                | `10`     |
| `reserve_pool_size` | `2`      | `5`                | `10`     |

### Container memory limits

| Variable                       | 1 × 2 GB | 2 × 4 GB (default) | 4 × 8 GB |
| ------------------------------ | -------- | ------------------ | -------- |
| `POSTGRES_MEM_LIMIT`           | `768m`   | `1536m`            | `3072m`  |
| `PGBOUNCER_MEM_LIMIT`          | `96m`    | `128m`             | `256m`   |
| `POSTGRES_EXPORTER_MEM_LIMIT`  | `96m`    | `128m`             | `192m`   |
| `PGBOUNCER_EXPORTER_MEM_LIMIT` | `48m`    | `64m`              | `96m`    |
| `NODE_EXPORTER_MEM_LIMIT`      | `48m`    | `64m`              | `96m`    |
| `PROMETHEUS_MEM_LIMIT`         | `256m`   | `512m`             | `1024m`  |
| `GRAFANA_MEM_LIMIT`            | `192m`   | `256m`             | `512m`   |
| `PGHERO_MEM_LIMIT`             | `256m`   | `384m`             | `512m`   |
| `DOZZLE_MEM_LIMIT`             | `96m`    | `128m`             | `192m`   |
| `BACKUP_MEM_LIMIT`             | `192m`   | `256m`             | `384m`   |

Total cap (no backup running): **~1.8 GB / 3.1 GB / 5.8 GB**. Idle use is typically 40–60 % of the caps.

### Prometheus retention

| Variable              | 1 × 2 GB (40 GB) | 2 × 4 GB (60 GB) | 4 × 8 GB (80 GB) |
| --------------------- | ---------------- | ---------------- | ---------------- |
| `PROM_RETENTION_TIME` | `15d`            | `30d` (default)  | `60d`            |
| `PROM_RETENTION_SIZE` | `1GB`            | `3GB` (default)  | `8GB`            |

---

## Backups

Each daily run uploads three kinds of file to your S3 bucket:

- `globals_<timestamp>.sql.gz` — roles, passwords, tablespaces (`pg_dumpall --globals-only`)
- `<dbname>_<timestamp>.sql.gz` — one per user database (`pg_dump`)

Every upload is verified with `s3api head-object`. On success the container writes a Prometheus metric (`pgbunker_backup_last_success_time`) to a shared volume read by node-exporter. Two alerts watch it:

- `BackupNeverRan` — the metric has never been set
- `BackupStale` — last success was more than 48 hours ago

Enable the profile once `S3_*` values in `.env` are real:

```bash
docker compose --profile backup up -d backup
```

If any `S3_*` is empty or still a placeholder, the container exits with a clear error.

### Restore

One database:

```bash
aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/YOUR_DB_<timestamp>.sql.gz" - \
  --region "$S3_REGION" \
  ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"} \
  | gunzip \
  | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d YOUR_DB
```

Roles and passwords (usually first, on a fresh cluster):

```bash
aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/globals_<timestamp>.sql.gz" - \
  --region "$S3_REGION" \
  ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"} \
  | gunzip \
  | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d postgres
```

---

## Alerts

`prometheus/alerts.yml` ships 14 rules in 5 groups:

- **postgres** — down, too many connections, low cache hit ratio, long-running transactions, deadlocks
- **pgbouncer** — exporter down, clients waiting for a pool slot
- **node** — disk < 15 % and < 5 %, memory > 90 %, load > 2× CPU count
- **targets** — any Prometheus scrape target down > 3 min
- **backup** — never ran, or last success > 48 h ago

Alerts show up in the Prometheus UI and in Grafana's Alerting page. No Alertmanager is shipped — add one yourself if you want Telegram or Slack delivery.

---

## Dashboards

Two dashboards are auto-provisioned from `grafana/provisioning/dashboards/` under the **PgBunker** folder:

- **DB Overview** — connections, QPS, query time, cache hit ratio, slow queries, replication lag, index efficiency, disk
- **System Overview** — CPU, memory, swap, disk I/O, network, load average

Provisioned dashboards are read-only in the UI — the JSON files in the repo are the source of truth.

---

## Firewall

`nginx-setup.sh` configures UFW with the minimum needed:

```
22    SSH
80    nginx (ACME challenge + HTTP → HTTPS redirect)
443   nginx (admin UIs)
6432  nginx stream → PgBouncer
```

Everything else — Postgres, Prometheus, all exporters, Grafana, PgHero, Dozzle — binds to `127.0.0.1` or stays inside the Docker bridge. Only nginx talks to the public internet.

---

## Project layout

```
pgbunker/
├── .env.example
├── docker-compose.yml
├── nginx/                      # host nginx config templates
│   ├── pgbunker.conf.tmpl
│   └── pgbunker-stream.conf.tmpl
├── pgbouncer/
│   ├── pgbouncer.ini.tmpl
│   ├── userlist.txt.tmpl
│   └── certs/                  # filled by setup.sh + nginx-setup.sh
├── prometheus/
│   ├── prometheus.yml
│   ├── alerts.yml              # 14 rules
│   └── postgres_exporter.yml
├── grafana/
│   └── provisioning/           # datasource + dashboards
├── dozzle/
│   └── users.yml               # auth, generated by setup.sh
└── scripts/
    ├── setup.sh                # renders configs from .env
    ├── nginx-setup.sh          # sudo: nginx + certbot + UFW
    ├── init-db.sql             # pg_stat_statements on first start
    ├── backup.sh               # pg_dumpall + per-DB dump to S3
    └── backup-preflight.sh     # validates S3 env before backup runs
```

---

## What's not included

Deliberate omissions — add them yourself if and when you need them.

- **PITR (point-in-time recovery).** Daily dumps mean up to 24 hours of data loss. For sub-minute RPO, add `pgBackRest` or `WAL-G` with WAL archiving to S3.
- **Major version upgrade.** Moving from PG 17 to 18 is a manual `pg_upgrade` or dump/restore — no automation shipped.
- **Full-text log search.** Dozzle is live-tail only. Add Loki + Promtail if you need to search a week back (budget ~500 MB – 1 GB RAM).
- **Per-container metrics.** node-exporter covers the host. Add cAdvisor (~100–200 MB RAM) for per-container CPU/RAM in Grafana.
- **`auth_query` for PgBouncer.** `userlist.txt` stores plaintext passwords. Cleaner alternative is a SCRAM-hash lookup in Postgres via a tech user.
- **Volume backups.** `prometheus_data` and `grafana_data` are not backed up. Add a weekly tar to S3 if dashboard customisations or metric history matter.

---

## Licence

MIT.
