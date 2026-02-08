# PgBunker

Docker Compose stack for production PostgreSQL/PGBouncer: connection pooling, monitoring, dashboards, backups, and log management. Everything you need instead of a $30-50 per month managed database on a $10 VPS.

## Motivation

Couldn't find a ready-made PostgreSQL stack for developers and small teams. Managed solutions with similar specs cost 3x more. This project gives you enterprise-grade database infrastructure out of the box.

Tested on a 2-core, 4GB RAM, 60GB NVMe VPS (Ubuntu 24.04). Handles 2-3 production startup-level projects simultaneously.

## What's Included

- **PostgreSQL 17** — database with `pg_stat_statements` and production-tuned parameters
- **PgBouncer 1.24** — connection pooling (transaction mode), critical when multiple apps share one instance
- **Prometheus + Exporters** — metrics collection: PostgreSQL stats, PgBouncer pools, system resources (CPU, RAM, disk, network)
- **Grafana 11** — two pre-built dashboards: database metrics and system metrics
- **PgHero** — web UI for slow queries, missing indexes, table bloat
- **Dozzle** — real-time Docker log viewer with auth
- **Backup** — automated daily pg_dump with 7-day retention

## Quick Start

Requirements: Docker & Docker Compose.

```bash
git clone https://github.com/amir-budaychiev/pgbunker.git
cd pgbunker

# 1. Environment
cp .env.example .env
nano .env  # set your passwords and DB name

# 2. PgBouncer
cp pgbouncer/pgbouncer.ini.example pgbouncer/pgbouncer.ini
cp pgbouncer/userlist.txt.example pgbouncer/userlist.txt
# replace username/password in both files to match .env

# 3. Start
docker compose up -d
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

Prometheus datasource is provisioned automatically. Import the dashboards manually:

1. Open Grafana at `http://your-host:3000`
2. **Dashboards** -> **New** -> **Import**
3. Upload `grafana/pgbunker-db.json` — PostgreSQL & PgBouncer (connections, cache hit ratio, TPS, pool status)
4. Upload `grafana/pgbunker-system.json` — system resources (CPU, RAM, swap, disk, network)

## PostgreSQL Tuning

Default parameters in `.env.example` target 2 vCPU / 4GB RAM. Adjust for your server:

| Parameter              | 2 GB     | 4 GB (default) | 8 GB     |
| ---------------------- | -------- | -------------- | -------- |
| `PG_SHARED_BUFFERS`    | `512MB`  | `1GB`          | `2GB`    |
| `PG_EFFECTIVE_CACHE_SIZE` | `1GB` | `3GB`          | `6GB`    |
| `PG_WORK_MEM`          | `5MB`    | `10MB`         | `20MB`   |

Rule of thumb: `shared_buffers` = 25% RAM, `effective_cache_size` = 75% RAM.

## Backups

Automatic daily backups in `./backups/`, 7-day retention.

Restore:
```bash
gunzip < backups/last/dbname-latest.sql.gz \
  | docker compose exec -T postgres psql -U $POSTGRES_USER -d $POSTGRES_DB
```

## Firewall (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp        # SSH
sudo ufw allow 6432/tcp      # PgBouncer — open for your app servers
sudo ufw allow 3000/tcp      # Grafana   — restrict to your IP (see below)
sudo ufw allow 8080/tcp      # PgHero    — restrict to your IP
sudo ufw allow 8888/tcp      # Dozzle    — restrict to your IP
sudo ufw enable
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

- **Dozzle auth** — generate `users.yml` with bcrypt-hashed password:
  ```bash
  docker run -it --rm amir20/dozzle generate admin --password your_password_here --email john@example.com --name "Admin" > dozzle/users.yml
  ```
- **node-exporter on Linux (Ubuntu)** — in `docker-compose.yml`, switch the volume mount:
  ```yaml
  # for Ubuntu:
  - /:/host:ro,rslave
  # for macOS (default):
  - /:/host:ro
  ```
