#!/bin/sh
set -eu

required_variables="S3_REGION S3_BUCKET S3_PREFIX S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY"

for variable_name in $required_variables; do
  variable_value="$(printenv "$variable_name" || true)"

  if [ -z "$variable_value" ]; then
    echo "backup-preflight: $variable_name is required" >&2
    exit 1
  fi

  case "$variable_value" in
    your-backup-bucket|your_access_key_id_here|your_secret_access_key_here)
      echo "backup-preflight: $variable_name still uses the example placeholder" >&2
      exit 1
      ;;
  esac
done

if [ "$#" -eq 0 ]; then
  set -- sh run.sh
fi

exec "$@"
