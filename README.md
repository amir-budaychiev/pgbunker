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
| VictoriaLogs         | 1.51    | Searchable log storage, optional `logs` profile          |
| Vector               | 0.56    | Ships container logs into VictoriaLogs                   |
| postgres-exporter    | 0.17    | Postgres metrics                                         |
| pgbouncer-exporter   | 0.10    | Pool metrics                                             |
| node-exporter        | 1.8     | Host metrics + textfile collector for backup status      |
| Backup (S3)          | —       | Daily `pg_dumpall --globals-only` + per-database dump    |
| Host nginx + certbot | —       | HTTPS for admin UIs, optional public PgBouncer TLS       |

All containers have memory limits. The default public ports after setup are **22, 80, and 443**. PgBouncer stays on `127.0.0.1` unless you explicitly set `PGBOUNCER_PUBLIC=true`.

---

## Quick start

Requirements: Ubuntu 24.04, a domain whose DNS you control, and Docker from
Docker's own apt repository — Ubuntu's `docker.io` package is older and ships a
different Compose:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Then:

```bash
git clone https://github.com/amir-budaychiev/pgbunker.git
cd pgbunker

sudo ./scripts/harden.sh          # swap, key-only SSH, fail2ban, auto-updates
cp .env.example .env
nano .env                         # set passwords, DOMAIN, LE_EMAIL
./scripts/setup.sh                # render pgbouncer configs and dozzle auth
docker compose up -d              # start the stack
sudo ./scripts/nginx-setup.sh     # install nginx + certbot, HTTPS, UFW
```

`harden.sh` runs first because it may disable password SSH login, and you want
to find out you still have a working key while you are still logged in. It
refuses to touch SSH if it cannot find one, so it cannot lock you out.

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
| VictoriaLogs | `https://<DOMAIN>/select/vmui/`      | Off by default; same login       |
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

## Centralized logs

Dozzle tails logs live. VictoriaLogs keeps them, so you can search a week back.
Both ship in this repo; the second one is off until you ask for it.

Vector reads every container's stdout/stderr from the Docker socket and writes
into VictoriaLogs. You read them either in vmui at `https://<DOMAIN>/select/vmui/`
or in Grafana's Explore tab, behind the same login as the other panels.

**"Every container" is literal.** If this box runs workloads besides PgBunker,
their logs land in VictoriaLogs too — which is usually the point of having a log
host, but worth knowing before you point it at a server full of other people's
applications. To collect only PgBunker's own containers, swap the
`exclude_containers` block in `vector/vector.yaml.tmpl` for
`include_containers: [pgbunker-]` and re-run `./scripts/setup.sh`.

Turn it on:

```env
LOGS_ENABLED=true
GRAFANA_PLUGINS=victoriametrics-logs-datasource
```

```bash
./scripts/setup.sh
docker compose --profile logs up -d
sudo ./scripts/nginx-setup.sh
```

Every log line carries three fields you will actually query on:

| Field | Value | Why |
| --- | --- | --- |
| `server` | `LOGS_SERVER_NAME` from `.env` | which host it came from |
| `service` | `pgbunker-grafana`, `pgbunker-postgres`, … | container name minus the replica suffix, so it survives a recreate |
| `log_type` | `app` | room for other sources later |

Postgres log lines carry `user@database` in their prefix, so a slow query found
in the logs tells you which database it came from. `pg_stat_statements` itself
is created once, in `POSTGRES_DB` — that one view reports queries from every
database in the cluster, so a single place is enough. Query *text* from other
users is only visible to a superuser or a role with `pg_read_all_stats`; PgHero
connects as `POSTGRES_USER`, the bootstrap superuser, so it sees everything.
Point it at an ordinary role instead and other users' queries turn into
`<insufficient privilege>` — that is Postgres working as designed, not a broken
install.

A query in vmui or Grafana Explore looks like this:

```logsql
_time:1h service:pgbunker-postgres error
```

Note what `service` is doing: the raw container name ends in `-1` and changes
whenever Compose recreates the container. If that name keyed the log stream,
one service would shatter into a new stream on every restart and old lines
would look like they vanished. Stripping the suffix keeps one service as one
stream.

### Disk and memory

Logs are cheap. On the box this project runs on, 14 days of logs from three
hosts take **35 MB** of disk, VictoriaLogs sits at ~80 MiB of RAM and Vector at
~15 MiB.

| Variable | 1 × 2 GB | 2 × 4 GB (default) | 4 × 8 GB |
| --- | --- | --- | --- |
| `LOGS_RETENTION` | — | `14d` | `30d` |
| `VICTORIALOGS_MEM_LIMIT` | — | `256m` | `512m` |
| `VECTOR_MEM_LIMIT` | — | `128m` | `192m` |
| `GRAFANA_MEM_LIMIT` | — | `384m` | `576m` |

**The logs profile does not fit on 1 vCPU / 2 GB.** The base stack already caps
out at ~1.8 GB of that 2 GB. Either leave logs off, or ship them to another
host that runs this profile — see the next section.

Grafana gets a bump because the VictoriaLogs plugin costs it about 20 MiB, and
the stock `320m` is already only ~86 % of what a working Grafana 12 uses.

---

## Shipping logs from other servers

One PgBunker box can be the log sink for your whole fleet. It exposes a
write-only `/insert/` endpoint on 443 — no new port, same certificate.

Two independent gates guard it, and both must pass: an IP allowlist and its own
htpasswd. The credentials are deliberately separate from `PANEL_PASSWORD`,
because they end up sitting in config files on other machines.

```env
LOGS_ENABLED=true
LOGS_INGEST_ENABLED=true
LOGS_INGEST_ALLOWED_IPS=203.0.113.10 203.0.113.11
LOGS_INGEST_USER=ingest
LOGS_INGEST_PASSWORD=<a long random string>
```

```bash
sudo ./scripts/nginx-setup.sh
```

On each sending host, run Vector with a config like this. Only `.server`, the
endpoint and the password change per host — keep `_stream_fields` identical
everywhere, or the same service will land in two different streams.

```yaml
sources:
  docker:
    type: docker_logs
    exclude_containers:
      - vector

transforms:
  label:
    type: remap
    inputs: [docker]
    source: |
      .server = "app-1"
      .log_type = "app"
      .service = replace(string!(.container_name), r'-[0-9]+$', "")

sinks:
  vlogs:
    type: elasticsearch
    inputs: [label]
    endpoints:
      - https://pgbunker.example.com/insert/elasticsearch/
    auth:
      strategy: basic
      user: ingest
      password: <the same LOGS_INGEST_PASSWORD>
    api_version: v8
    compression: gzip
    healthcheck:
      enabled: false
    query:
      _msg_field: message
      _time_field: timestamp
      _stream_fields: server,service,log_type
```

### Dozzle across hosts

Dozzle can also show another host's containers live, without VictoriaLogs. Run
`dozzle agent` there, allow this server's IP on port 7007, and list it:

```env
DOZZLE_REMOTE_AGENT=203.0.113.10:7007,203.0.113.11:7007
```

This is a direct connection from your PgBunker box to the agent, so treat port
7007 like any other admin port: allowlist it, never leave it open to the world.

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

`PGBOUNCER_ALLOWED_CIDR` restricts who may connect at all, and it applies in
both modes. TLS proves the server's identity; it says nothing about who is
allowed to knock. The value is a space-separated list.

| `PGBOUNCER_ALLOWED_CIDR` | `PGBOUNCER_TLS` | Result |
| --- | --- | --- |
| set | either | `allow`/`deny all` in the nginx stream, UFW opens the port only for those sources |
| empty | `true` | open to the whole internet — the setup script warns about it |
| empty | `false` | refuses to run |

```env
PGBOUNCER_PUBLIC=true
PGBOUNCER_TLS=true
PGBOUNCER_ALLOWED_CIDR=203.0.113.10/32 203.0.113.11/32
```

Without TLS, SCRAM-SHA-256 still protects the password during authentication,
but query traffic is plaintext. Use that mode only on a trusted private network
or a tightly scoped allowlist.

If you later change the allowlist, delete the old UFW rules by hand — the
script adds rules but does not know which stale ones to remove.

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
| `VICTORIALOGS_MEM_LIMIT` (logs)| —        | `256m`             | `512m`   |
| `VECTOR_MEM_LIMIT` (logs)      | —        | `128m`             | `192m`   |

Total cap without the backup or logs profile: **~1.81 GB / 3.25 GB / 5.81 GB**.
With the logs profile (and `GRAFANA_MEM_LIMIT` raised to `384m` / `576m`):
**does not fit / ~3.69 GB / 6.56 GB**. These are ceilings, not usage — idle
consumption typically runs 40–60 % of them.

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

## Host hardening

`scripts/harden.sh` sets up the baseline any internet-facing box wants. It is
idempotent, so re-running it is a no-op.

```bash
sudo ./scripts/harden.sh
```

| What | Detail |
| --- | --- |
| Swap | zram — compressed swap in RAM, half of RAM capped at 4 GB. Skipped if the host already has swap. |
| sysctl | `vm.swappiness=30`, `vm.vfs_cache_pressure=100` in `/etc/sysctl.d/60-pgbunker.conf` |
| Huge pages | THP switched off via `disable-thp.service`, ordered before Docker starts |
| SSH | `PasswordAuthentication no`, `PermitRootLogin prohibit-password` in `/etc/ssh/sshd_config.d/00-pgbunker-hardening.conf` |
| fail2ban | `jail.local` with `bantime 1h`, `findtime 10m`, `maxretry 5`, `sshd` jail on the systemd backend |
| Updates | `unattended-upgrades` enabled for security patches |
| Autostart | `pgbunker.service` enabled, so the stack comes back after a reboot |

**Why turn off transparent huge pages.** Postgres allocates many small shared
pages, and the kernel's background compaction of huge pages stalls backends
while inflating memory use. Disabling THP is standard advice for any Postgres
host. The database runs in a container, but containers share the host kernel —
so this is a host setting, and it has to be applied before Docker starts.

**It will not lock you out.** Before touching SSH it checks that your account
has a key in `authorized_keys`; if there is none it leaves password login
alone, says so loudly, and carries on with everything else. It also runs
`sshd -t` before reloading, and reverts the file if sshd rejects it.

The `00-` prefix on the SSH drop-in matters: sshd honours the *first* directive
it reads and loads that directory in alphabetical order, and hosting providers
frequently ship their own `40-*.conf`. A later filename would be silently
ignored.

**About the autostart unit.** Every container already carries
`restart: unless-stopped`, which handles an ordinary reboot on its own. The
unit adds three things that does not: a start ordered after Docker and the
network, a clean `systemctl stop pgbunker`, and recovery if someone ran
`docker compose down` and then rebooted. It runs plain `docker compose up -d`
and takes its profiles from `COMPOSE_PROFILES` in `.env`, so set

```env
COMPOSE_PROFILES=logs,backup
```

if you want those to come up automatically too.

Verify afterwards:

```bash
swapon --show
cat /sys/kernel/mm/transparent_hugepage/enabled
sshd -T | grep -E '^(passwordauthentication|permitrootlogin)'
fail2ban-client status sshd
```

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
├── nginx/                          # host nginx config templates
│   ├── pgbunker.conf.tmpl
│   ├── pgbunker-stream.conf.tmpl
│   ├── pgbunker-prometheus.conf.tmpl
│   ├── pgbunker-logs.conf.tmpl     # vmui, rendered when logs are on
│   ├── pgbunker-logs-ingest.conf.tmpl
│   └── landing.html.tmpl
├── pgbouncer/
│   ├── pgbouncer.ini.tmpl
│   ├── userlist.txt.tmpl
│   └── certs/                      # filled when PgBouncer TLS is enabled
├── prometheus/
│   ├── prometheus.yml
│   ├── alerts.yml                  # 14 rules
│   ├── postgres_exporter.yml
│   └── textfile/                   # node-exporter textfile metrics
├── grafana/
│   └── provisioning/               # datasources + dashboards
├── vector/
│   └── vector.yaml.tmpl            # log shipping, rendered by setup.sh
├── dozzle/
│   └── users.yml                   # auth, generated by setup.sh
└── scripts/
    ├── setup.sh                    # renders configs from .env
    ├── nginx-setup.sh              # sudo: nginx + certbot + UFW
    ├── harden.sh                   # sudo: swap, THP, SSH, fail2ban, autostart
    ├── init-db.sql                 # pg_stat_statements on first start
    ├── backup.sh                   # pg_dumpall + per-DB dump to S3
    └── backup-preflight.sh         # validates S3 env before backup runs
```

---

## What's not included

Deliberate omissions — add them yourself if and when you need them.

- **PITR (point-in-time recovery).** Daily dumps mean up to 24 hours of data loss. For sub-minute RPO, add `pgBackRest` or `WAL-G` with WAL archiving to S3.
- **Major version upgrade.** Moving from PG 17 to 18 is a manual `pg_upgrade` or dump/restore — no automation shipped.
- **Log alerting.** VictoriaLogs stores and searches logs, but nothing here alerts on a pattern in them. Prometheus alerts cover metrics only.
- **Per-container metrics.** node-exporter covers the host. Add cAdvisor (~100–200 MB RAM) for per-container CPU/RAM in Grafana.
- **`auth_query` for PgBouncer.** `userlist.txt` stores plaintext passwords. Cleaner alternative is a SCRAM-hash lookup in Postgres via a tech user.
- **Volume backups.** `prometheus_data` and `grafana_data` are not backed up. Add a weekly tar to S3 if dashboard customisations or metric history matter.

---

## Upgrading from an earlier version

`setup.sh` stops with an error if a template references a variable your `.env`
does not have. After pulling, add the keys you are missing — copy them from
`.env.example`:

```
LOGS_ENABLED  LOGS_SERVER_NAME  LOGS_RETENTION
VICTORIALOGS_MEM_LIMIT  VECTOR_MEM_LIMIT  GRAFANA_PLUGINS
LOGS_INGEST_ENABLED  LOGS_INGEST_ALLOWED_IPS
LOGS_INGEST_USER  LOGS_INGEST_PASSWORD
DOZZLE_REMOTE_AGENT  COMPOSE_PROFILES
```

Leaving them all at their `.env.example` defaults keeps the stack exactly as it
was — every new feature is off until you turn it on.

---

## Licence

MIT.
