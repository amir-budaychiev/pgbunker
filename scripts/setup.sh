#!/usr/bin/env bash
set -euo pipefail

# Renders config files from .env and generates the Dozzle users file.
# Safe to re-run: overwrites the rendered files each time.

cd "$(dirname "$0")/.."

# ---- load .env ----
if [ ! -f .env ]; then
  if [ ! -f .env.example ]; then
    echo "setup: neither .env nor .env.example found" >&2
    exit 1
  fi
  cp .env.example .env
  echo "setup: created .env from .env.example — open it and set real passwords, then re-run this script"
  exit 1
fi

# Parse .env without shell interpretation so passwords with special chars
# (& | $ # etc.) are handled the same way Docker Compose reads them.
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  # Strip one layer of surrounding single or double quotes, if present.
  if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  export "$key=$value"
done < .env

# ---- sanity-check critical values are not placeholders ----
placeholders=(your_postgres_password_here your_grafana_password_here your_pghero_password_here)
for value in "$POSTGRES_PASSWORD" "$GRAFANA_ADMIN_PASSWORD" "$PGHERO_PASSWORD"; do
  for placeholder in "${placeholders[@]}"; do
    if [ "$value" = "$placeholder" ]; then
      echo "setup: .env still contains placeholder password '$placeholder' — set real values first" >&2
      exit 1
    fi
  done
done

for key in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD PGHERO_USERNAME PGHERO_PASSWORD DOMAIN LE_EMAIL; do
  eval "value=\${$key:-}"
  if [ -z "$value" ]; then
    echo "setup: .env is missing required variable $key" >&2
    exit 1
  fi
done

if [ "$DOMAIN" = "example.com" ]; then
  echo "setup: DOMAIN in .env is still the placeholder 'example.com' — set your real domain first" >&2
  exit 1
fi
if [ "$LE_EMAIL" = "you@example.com" ]; then
  echo "setup: LE_EMAIL in .env is still the placeholder — set a real email for Let's Encrypt" >&2
  exit 1
fi

# ---- render template to output file, substituting ${VAR} from current env ----
# Pure bash: reads template, replaces any ${NAME} with value of $NAME, writes output.
# No dependency on envsubst. Passwords with special characters are safe because we
# never pass them through sed/eval.
render() {
  local source="$1" target="$2"
  local content
  content="$(cat "$source")"
  local var_name var_value
  while [[ "$content" =~ \$\{([A-Z_][A-Z0-9_]*)\} ]]; do
    var_name="${BASH_REMATCH[1]}"
    eval "var_value=\${$var_name-__PGBUNKER_UNSET__}"
    if [ "$var_value" = "__PGBUNKER_UNSET__" ]; then
      echo "setup: template $source references \${$var_name} but it is not set in .env" >&2
      exit 1
    fi
    content="${content//\$\{$var_name\}/$var_value}"
  done
  printf '%s\n' "$content" > "$target"
}

echo "setup: rendering pgbouncer/pgbouncer.ini"
render pgbouncer/pgbouncer.ini.tmpl pgbouncer/pgbouncer.ini

# Append TLS block if enabled so pgbouncer terminates TLS on port 6432.
if [ "${PGBOUNCER_TLS:-false}" = "true" ]; then
  cat >> pgbouncer/pgbouncer.ini <<'TLS_BLOCK'

client_tls_sslmode = require
client_tls_cert_file = /certs/fullchain.pem
client_tls_key_file = /certs/privkey.pem
TLS_BLOCK
fi

echo "setup: rendering pgbouncer/userlist.txt"
render pgbouncer/userlist.txt.tmpl pgbouncer/userlist.txt
chmod 600 pgbouncer/userlist.txt

# ---- keep PGBOUNCER_EXPORTER_SSLMODE in .env synced with PGBOUNCER_TLS ----
# lib/pq (used by pgbouncer-exporter) does not accept "prefer", so we have to
# pick require vs disable explicitly. We derive it from PGBOUNCER_TLS so the
# user only ever touches one boolean.
target_sslmode="disable"
[ "${PGBOUNCER_TLS:-false}" = "true" ] && target_sslmode="require"

tmpfile="$(mktemp)"
awk -v v="$target_sslmode" '
  /^PGBOUNCER_EXPORTER_SSLMODE=/ { print "PGBOUNCER_EXPORTER_SSLMODE=" v; found=1; next }
  { print }
  END { if (!found) print "\n# Auto-managed by setup.sh — reflects PGBOUNCER_TLS.\nPGBOUNCER_EXPORTER_SSLMODE=" v }
' .env > "$tmpfile" && mv "$tmpfile" .env
export PGBOUNCER_EXPORTER_SSLMODE="$target_sslmode"

# ---- placeholder TLS certs so pgbouncer can start before nginx-setup.sh ----
# Real Let's Encrypt certs are written by scripts/nginx-setup.sh (deploy-hook)
# and loaded by pgbouncer on SIGHUP.
mkdir -p pgbouncer/certs
if [ "${PGBOUNCER_TLS:-false}" = "true" ] \
   && { [ ! -f pgbouncer/certs/fullchain.pem ] || [ ! -f pgbouncer/certs/privkey.pem ]; }; then
  echo "setup: generating placeholder self-signed cert (replaced by Let's Encrypt on nginx-setup.sh)"
  if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -sha256 -days 3650 -nodes -newkey rsa:2048 \
      -subj "/CN=pgbunker-placeholder" \
      -keyout pgbouncer/certs/privkey.pem \
      -out   pgbouncer/certs/fullchain.pem 2>/dev/null
  else
    docker run --rm -v "$PWD/pgbouncer/certs:/certs" alpine:3.19 sh -c '
      apk add --no-cache openssl >/dev/null 2>&1
      openssl req -x509 -sha256 -days 3650 -nodes -newkey rsa:2048 \
        -subj "/CN=pgbunker-placeholder" \
        -keyout /certs/privkey.pem \
        -out   /certs/fullchain.pem 2>/dev/null
    '
  fi
  chmod 644 pgbouncer/certs/*.pem
fi

# ---- dozzle auth file ----
if [ ! -f dozzle/users.yml ]; then
  echo "setup: generating dozzle/users.yml via docker"
  dozzle_image="amir20/dozzle:v10.1.1"
  docker run --rm "$dozzle_image" generate "$GRAFANA_ADMIN_USER" \
    --password "$GRAFANA_ADMIN_PASSWORD" \
    --email "${GRAFANA_ADMIN_USER}@localhost" \
    --name "Admin" > dozzle/users.yml
else
  echo "setup: dozzle/users.yml already exists, leaving it"
fi

echo "setup: done. next: docker compose up -d"
