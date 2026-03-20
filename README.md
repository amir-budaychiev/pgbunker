# PgBunker

Docker Compose stack for production PostgreSQL/PGBouncer: connection pooling, monitoring, dashboards, backups, and log management. Everything you need instead of a $30-50 per month managed database on a $10 VPS.

## Motivation

Couldn't find a ready-made PostgreSQL stack for developers and small teams. Managed solutions with similar specs cost 3x more. This project gives you enterprise-grade database infrastructure out of the box.

Tested on a 2-core, 4GB RAM, 60GB NVMe VPS (Ubuntu 24.04). Handles 2-3 production startup-level projects simultaneously.

## What's Included

- **PostgreSQL 17** — database with `pg_stat_statements` and production-tuned parameters
- **PgBouncer 1.24** — connection pooling (transaction mode), critical when multiple apps share one instance
- **Prometheus + Exporters** — metrics collection: PostgreSQL stats, PgBouncer pools, system resources (CPU, RAM, disk, network)
- **Grafana 12** — two pre-built dashboards: database metrics and system metrics
- **PgHero** — web UI for slow queries, missing indexes, table bloat
- **Dozzle** — real-time Docker log viewer with auth
- **Backup (S3)** — optional profile for automated daily pg_dump to S3-compatible object storage with 7-day retention

## Quick Start

Requirements: Docker & Docker Compose.

```bash
git clone https://github.com/amir-budaychiev/pgbunker.git
cd pgbunker

# 1. Environment
cp .env.example .env
nano .env  # set your passwords and DB name
# macOS only: set NODE_EXPORTER_HOST_MOUNT_OPTIONS=ro

# 2. PgBouncer
cp pgbouncer/pgbouncer.ini.example pgbouncer/pgbouncer.ini
cp pgbouncer/userlist.txt.example pgbouncer/userlist.txt
# only PGBOUNCER_LISTEN_PORT is configured in .env
# pool_mode, pool sizes and admin users are configured in pgbouncer.ini
# in pgbouncer.ini replace "john" with your POSTGRES_USER in 3 places:
#   line: * = host=postgres port=5432 user=YOUR_USER
#   line: admin_users = YOUR_USER
#   line: stats_users = YOUR_USER
# in userlist.txt set your credentials in plain text:
#   "YOUR_USER" "YOUR_POSTGRES_PASSWORD"
# restrict file permissions:
chmod 600 pgbouncer/userlist.txt

# 3. Dozzle auth (required — replace YOUR_PASSWORD and YOUR_EMAIL below)
docker run -it --rm amir20/dozzle:v10.1.1 generate admin --password YOUR_PASSWORD --email YOUR_EMAIL --name "Admin" > dozzle/users.yml

# 4. Start core stack
docker compose up -d

# 5. Enable S3 backups after you set real S3 credentials
docker compose --profile backup up -d backup
```

## Access Services

| Service       | Port   | Notes                          |
| ------------- | ------ | ------------------------------ |
| **PgBouncer** | `6432` | Application connects here      |
| **Grafana**   | `3000` | Credentials from `.env`        |
| **PgHero**    | `8080` | Credentials from `.env`        |
| **Dozzle**    | `8888` | Docker log viewer              |
| PostgreSQL    | --     | Internal only, via PgBouncer   |
| Prometheus    | --     | Internal only, used by Grafana |

**Connection string for your app:**
```
postgresql://user:password@your-host:6432/dbname
```

## Grafana Dashboards

Prometheus datasource and both dashboards are provisioned automatically on startup. Open Grafana at `http://your-host:3000` — dashboards are available under the **PgBunker** folder.

### Dashboard Overview

**DB Overview** monitors:
- Active connections and connection limits
- Queries per second (QPS)
- Query execution time distribution
- Cache hit ratio (should be >99%)
- Slow queries (queries >1s)
- Replication lag (if applicable)
- Index usage and efficiency
- Disk usage trends

**System Overview** monitors:
- CPU utilization
- Memory usage (RSS, cache)
- Disk I/O (read/write latency)
- Network throughput
- Disk space remaining
- System load average

## PostgreSQL Tuning

Default parameters in `.env.example` target 2 vCPU / 4GB RAM. Adjust for your server:

| Parameter              | 2 GB     | 4 GB (default) | 8 GB     |
| ---------------------- | -------- | -------------- | -------- |
| `PG_SHARED_BUFFERS`    | `512MB`  | `1GB`          | `2GB`    |
| `PG_EFFECTIVE_CACHE_SIZE` | `1GB` | `3GB`          | `6GB`    |
| `PG_WORK_MEM`          | `5MB`    | `10MB`         | `20MB`   |

Rule of thumb: `shared_buffers` = 25% RAM, `effective_cache_size` = 75% RAM.

## Backups (S3)

Automatic daily backups are uploaded to your S3-compatible bucket with 7-day retention.

The backup service is in the optional `backup` profile. It does not start until you run:

```bash
docker compose --profile backup up -d backup
```

If required S3 values are empty or still use example placeholders, the backup container exits immediately with a clear error.

Required `.env` values:
- `S3_REGION`
- `S3_BUCKET`
- `S3_PREFIX`
- `S3_ACCESS_KEY_ID`
- `S3_SECRET_ACCESS_KEY`
- `S3_ENDPOINT` (leave empty for AWS S3, set for Cloudflare R2/Backblaze B2/MinIO)

Restore from S3:
```bash
aws s3 cp "s3://$S3_BUCKET/$S3_PREFIX/YOUR_BACKUP_FILE.sql.gz" - \
  --region "$S3_REGION" \
  ${S3_ENDPOINT:+--endpoint-url "$S3_ENDPOINT"} \
  | gunzip \
  | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

## Firewall (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp        # SSH
sudo ufw allow 6432/tcp      # PgBouncer — open for app servers
sudo ufw allow 3000/tcp      # Grafana   — restrict to your IP (see below)
sudo ufw allow 8080/tcp      # PgHero    — restrict to your IP
sudo ufw allow 8888/tcp      # Dozzle    — restrict to your IP
sudo ufw enable
```

Restrict PgBouncer to specific app server IPs (recommended):
```bash
sudo ufw delete allow 6432/tcp
sudo ufw allow from YOUR_APP_SERVER_IP to any port 6432
```

Restrict admin panels to your IP only:
```bash
sudo ufw delete allow 3000/tcp
sudo ufw delete allow 8080/tcp
sudo ufw delete allow 8888/tcp
sudo ufw allow from YOUR_IP to any port 3000
sudo ufw allow from YOUR_IP to any port 8080
sudo ufw allow from YOUR_IP to any port 8888
```

PostgreSQL (5432) and Prometheus (9090) are not exposed to host — no firewall rules needed.

## Notes

- **node-exporter mount mode** — set once in `.env`:
  - Linux (Ubuntu, default): `NODE_EXPORTER_HOST_MOUNT_OPTIONS=ro,rslave`
  - macOS: `NODE_EXPORTER_HOST_MOUNT_OPTIONS=ro`
