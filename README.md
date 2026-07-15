# PgBunker

**Self-hosted Postgres on a small VPS.** One Docker Compose file, plus setup scripts for generated configs, monitoring, backups, logs, HTTPS, and optional public PgBouncer TLS.

Tested on **2 vCPU / 4 GB / 60 GB NVMe Ubuntu 24.04**. Runs on **1 vCPU / 2 GB** and **4 vCPU / 8 GB** by editing only `.env`.

---

## What you get

| Component            | Version | Purpose                                                  |
| -------------------- | ------- | -------------------------------------------------------- |
| PostgreSQL           | 17      | Database, `pg_stat_statements` enabled on first start    |
| PgBouncer            | 1.24    | Transaction-mode pooler, private by default              |
| Prometheus           | 3.2     | Metrics + 14 alert rules                                 |
| Grafana              | 12      | DB and System dashboards, provisioned on start           |
| PgHero               | 3.7     | Slow queries, missing indexes, table bloat               |
| Dozzle               | 10.1    | Live log viewer with auth                                |
| postgres-exporter    | 0.17    | Postgres metrics                                         |
| pgbouncer-exporter   | 0.10    | Pool metrics                                             |
| node-exporter        | 1.8     | Host metrics + textfile collector for backup status      |
| Backup (S3)          | —       | Daily `pg_dumpall --globals-only` + per-database dump    |
| Host nginx + certbot | —       | HTTPS for admin UIs, optional public PgBouncer TLS       |

All containers have memory limits. The default public ports after setup are **22, 80, and 443**. PgBouncer stays on `127.0.0.1` unless you explicitly set `PGBOUNCER_PUBLIC=true`.

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

Before the last command, point a single DNS A-record at your VPS:

```
<DOMAIN>                          # e.g. pgbunker.yourdomain.com
```

That's it. Certificates auto-renew via the `certbot.timer` systemd unit that ships with the certbot package — you don't have to schedule anything.

Optional — enable daily S3 backups once `S3_*` values in `.env` are real. If you also set `BACKUP_ALERTS_ENABLED=true`, re-run `./scripts/setup.sh` first so node-exporter gets the enabled metric:

```bash
./scripts/setup.sh
docker compose --profile backup up -d backup
```

---

## Services

| Service    | URL                                    | Notes                            |
| ---------- | -------------------------------------- | -------------------------------- |
| Home       | `https://<DOMAIN>/`                    | Landing page with links          |
| Grafana    | `https://<DOMAIN>/grafana`             | One login for all four panels    |
| PgHero     | `https://<DOMAIN>/pghero`              | One login for all four panels    |
| Dozzle     | `https://<DOMAIN>/dozzle`              | One login for all four panels    |
| Prometheus | `https://<DOMAIN>:9090/`               | Off by default; IP-allowlisted   |
| PgBouncer  | `127.0.0.1:<PGBOUNCER_UPSTREAM_PORT>`  | Private application endpoint     |

Private connection string on the VPS or through an SSH tunnel:

```
postgresql://user:password@127.0.0.1:16432/dbname
```

Public TLS endpoint on the default public port, only after `PGBOUNCER_PUBLIC=true` and `PGBOUNCER_TLS=true`:

```
postgresql://user:password@<DOMAIN>:6432/dbname?sslmode=require
```

---

## Single sign-on for panels

Grafana, PgHero, Dozzle, and the VictoriaLogs UI (vmui) all sit behind one nginx `auth_basic` realm (`PgBunker panels`), backed by one htpasswd file generated from `PANEL_USER`/`PANEL_PASSWORD` (`nginx-setup.sh` regenerates it on every run). The browser prompts once per session and reuses it for all four paths. Each app is configured to trust the username nginx already authenticated instead of showing its own login form — Grafana via `auth.proxy` (header `X-WEBAUTH-USER`), Dozzle via its `forward-proxy` auth provider (header `Remote-User`), and PgHero by simply having no `PGHERO_USERNAME`/`PGHERO_PASSWORD` set. This is still HTTP Basic Auth (the browser's native popup), not a styled login page with long-lived sessions — that would need a separate auth proxy (Authelia, oauth2-proxy), deliberately not added here.

---

## TLS

Panels are served over HTTPS by host nginx with a single Let's Encrypt certificate for `<DOMAIN>`, path-routed under `/grafana`, `/pghero`, `/dozzle`. The same certificate also covers the public PgBouncer and Prometheus endpoints on their own ports. Nothing to do after `nginx-setup.sh`.

**Public Postgres access is off by default.** Postgres uses a plaintext handshake to negotiate SSL (it's a protocol quirk), so nginx cannot terminate TLS for it. PgBouncer has to do it itself.

To publish PgBouncer with TLS, point the `<DOMAIN>` A-record at the VPS and flip two flags:

```diff
# .env
- PGBOUNCER_PUBLIC=false
+ PGBOUNCER_PUBLIC=true
- PGBOUNCER_TLS=false
+ PGBOUNCER_TLS=true
```

Then re-run the normal setup commands:

```bash
./scripts/setup.sh
docker compose up -d
sudo ./scripts/nginx-setup.sh
```

`setup.sh` and `nginx-setup.sh` handle the rest:

1. `setup.sh` adds the TLS block to `pgbouncer.ini` and generates a self-signed placeholder certificate so PgBouncer can start.
2. `nginx-setup.sh` issues the `<DOMAIN>` certificate, installs a certbot deploy-hook at `/etc/letsencrypt/renewal-hooks/deploy/pgbunker.sh`, and opens `PGBOUNCER_PUBLIC_PORT`. The hook copies renewed certs into `pgbouncer/certs/`, restricts the private key permissions, and sends `SIGHUP` to PgBouncer. This happens automatically every 60 days for the life of the VPS.

If you intentionally need a plaintext public PgBouncer endpoint — for example, over a private datacenter network — set an allowlist instead of opening it to the world:

```env
PGBOUNCER_PUBLIC=true
PGBOUNCER_TLS=false
PGBOUNCER_ALLOWED_CIDR=<APP_SERVER_IP>/32
```

SCRAM-SHA-256 still protects the password during authentication, but query traffic is plaintext. Use this mode only on a trusted private network or a tightly scoped allowlist.

---

## Prometheus access

By default Prometheus is private — it stays on the Docker network and you read its data through Grafana. To let another server (a central Prometheus, a remote Grafana datasource) reach it directly, expose it on its own port:

```env
PROMETHEUS_PUBLIC=true
PROMETHEUS_PUBLIC_PORT=9090
PROMETHEUS_ALLOWED_IPS=203.0.113.10          # space-separated allowlist, required
```

Then re-run `./scripts/setup.sh && docker compose up -d && sudo ./scripts/nginx-setup.sh`.

Host nginx TLS-terminates Prometheus on `PROMETHEUS_PUBLIC_PORT` with the same Let's Encrypt certificate and proxies to a `127.0.0.1` upstream. Prometheus has no authentication of its own, so access is locked to `PROMETHEUS_ALLOWED_IPS` in **two** layers — UFW and an nginx allowlist. Connect to it as `https://<DOMAIN>:9090/`.

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
| `GRAFANA_MEM_LIMIT`            | `192m`   | `320m`             | `512m`   |
| `PGHERO_MEM_LIMIT`             | `256m`   | `448m`             | `512m`   |
| `DOZZLE_MEM_LIMIT`             | `96m`    | `128m`             | `192m`   |
| `BACKUP_MEM_LIMIT`             | `192m`   | `256m`             | `384m`   |

Total cap (no backup running): **~1.8 GB / 3.23 GB / 5.8 GB**. Idle use is typically 40–60 % of the caps.

### Prometheus retention

| Variable              | 1 × 2 GB (40 GB) | 2 × 4 GB (60 GB) | 4 × 8 GB (80 GB) |
| --------------------- | ---------------- | ---------------- | ---------------- |
| `PROM_RETENTION_TIME` | `15d`            | `30d` (default)  | `60d`            |
| `PROM_RETENTION_SIZE` | `1GB`            | `3GB` (default)  | `8GB`            |

---

## Backups

Each daily run uploads two kinds of file to your S3 bucket:

- `globals_<timestamp>.sql.gz` — roles, passwords, tablespaces (`pg_dumpall --globals-only`)
- `<dbname>_<timestamp>.sql.gz` — one per user database (`pg_dump`)

Every upload is verified with `s3api head-object`. On success the container writes a Prometheus metric (`pgbunker_backup_last_success_time`) to the textfile directory read by node-exporter. When `BACKUP_ALERTS_ENABLED=true`, two alerts watch it:

- `BackupNeverRan` — the metric has never been set
- `BackupStale` — last success was more than 48 hours ago

Enable the profile once `S3_*` values in `.env` are real:

```bash
./scripts/setup.sh
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

`prometheus/alerts.yml` ships 14 rules in 5 groups. Backup alerts stay quiet unless `BACKUP_ALERTS_ENABLED=true` was rendered by `./scripts/setup.sh`.

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

`nginx-setup.sh` configures UFW with the minimum needed by default:

```
22    SSH
80    nginx (ACME challenge + HTTP → HTTPS redirect)
443   nginx (panels: /grafana, /pghero, /dozzle)
```

If `PGBOUNCER_PUBLIC=true`, it also enables nginx stream on `PGBOUNCER_PUBLIC_PORT`. With TLS it opens that port publicly; without TLS it requires `PGBOUNCER_ALLOWED_CIDR` and opens the port only for that source.

If `PROMETHEUS_PUBLIC=true`, it opens `PROMETHEUS_PUBLIC_PORT` (default 9090) only for the IPs in `PROMETHEUS_ALLOWED_IPS`.

Everything else — Postgres, all exporters, Grafana, PgHero, Dozzle, private PgBouncer, and private Prometheus — binds to `127.0.0.1` or stays inside the Docker bridge. Only nginx talks to the public internet.

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
│   └── certs/                  # filled when PgBouncer TLS is enabled
├── prometheus/
│   ├── prometheus.yml
│   ├── alerts.yml              # 14 rules
│   ├── postgres_exporter.yml
│   └── textfile/               # node-exporter textfile metrics
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
