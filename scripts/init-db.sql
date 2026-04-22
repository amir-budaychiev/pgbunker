-- Runs once, the first time postgres starts with an empty data dir.
-- Required for PgHero, slow-query analysis, and the postgres-exporter dashboards.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
