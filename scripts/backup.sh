#!/bin/sh

set -eu
set -o pipefail

# shellcheck disable=SC1091
. ./env.sh

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")

# ---- list all user databases except templates ----
databases=$(
  psql \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DATABASE" \
    -Atc "SELECT datname FROM pg_database WHERE datallowconn AND datname NOT IN ('template0','template1')"
)

verify_upload() {
  s3_key="$1"
  aws $aws_args s3api head-object --bucket "$S3_BUCKET" --key "$s3_key" >/dev/null
}

upload() {
  local_file="$1"
  s3_key="$2"
  echo "Uploading $local_file to s3://${S3_BUCKET}/${s3_key}"
  aws $aws_args s3 cp "$local_file" "s3://${S3_BUCKET}/${s3_key}"
  verify_upload "$s3_key"
  rm "$local_file"
}

# ---- 1. globals (roles, passwords, tablespaces) ----
echo "Dumping globals..."
pg_dumpall \
  -h "$POSTGRES_HOST" \
  -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" \
  --globals-only \
  | gzip > globals.sql.gz
upload globals.sql.gz "${S3_PREFIX}/globals_${timestamp}.sql.gz"

# ---- 2. every user database individually ----
for db in $databases; do
  echo "Dumping database $db..."
  pg_dump \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    -d "$db" \
    | gzip > "${db}.sql.gz"
  upload "${db}.sql.gz" "${S3_PREFIX}/${db}_${timestamp}.sql.gz"
done

# ---- 3. write success metric for node-exporter textfile collector ----
metric_dir="/var/lib/node-textfile"
if [ -d "$metric_dir" ]; then
  tmpfile=$(mktemp "${metric_dir}/pgbunker_backup.prom.XXXXXX")
  cat > "$tmpfile" <<EOF
# HELP pgbunker_backup_last_success_time Unix timestamp of the last successful backup run.
# TYPE pgbunker_backup_last_success_time gauge
pgbunker_backup_last_success_time $(date +%s)
EOF
  # node-exporter runs as nobody; default mktemp mode is 600 which would hide
  # the file from it. 644 is safe — the file contains only a timestamp.
  chmod 644 "$tmpfile"
  mv "$tmpfile" "${metric_dir}/pgbunker_backup.prom"
fi

echo "Backup complete."

# ---- 4. retention ----
if [ -n "${BACKUP_KEEP_DAYS:-}" ]; then
  sec=$((86400 * BACKUP_KEEP_DAYS))
  date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
  backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

  echo "Removing backups older than $date_from_remove from s3://${S3_BUCKET}/${S3_PREFIX}..."
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --query "${backups_query}" \
    --output text \
    | xargs -n1 -I 'KEY' aws $aws_args s3 rm "s3://${S3_BUCKET}/KEY"
  echo "Removal complete."
fi
