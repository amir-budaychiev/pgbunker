#!/usr/bin/env bash
set -euo pipefail

# Installs and configures host-level nginx + certbot for pgbunker.
# Reads DOMAIN, LE_EMAIL, and PgBouncer public/TLS settings from .env.
#
# Idempotent: safe to re-run. Certbot will renew or no-op as needed.

if [ "$EUID" -ne 0 ]; then
  echo "nginx-setup: must run as root (use sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# ---- load .env without shell interpretation ----
if [ ! -f .env ]; then
  echo "nginx-setup: .env not found at $PROJECT_DIR/.env" >&2
  exit 1
fi

while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  export "$key=$value"
done < .env

: "${DOMAIN:?DOMAIN is not set in .env}"
: "${LE_EMAIL:?LE_EMAIL is not set in .env}"
PGBOUNCER_TLS="${PGBOUNCER_TLS:-false}"
PGBOUNCER_PUBLIC="${PGBOUNCER_PUBLIC:-false}"
PGBOUNCER_UPSTREAM_PORT="${PGBOUNCER_UPSTREAM_PORT:-16432}"
PGBOUNCER_PUBLIC_PORT="${PGBOUNCER_PUBLIC_PORT:-6432}"
PGBOUNCER_ALLOWED_CIDR="${PGBOUNCER_ALLOWED_CIDR:-}"

case "$PGBOUNCER_TLS" in
  true|false) ;;
  *)
    echo "nginx-setup: PGBOUNCER_TLS must be true or false" >&2
    exit 1
    ;;
esac
case "$PGBOUNCER_PUBLIC" in
  true|false) ;;
  *)
    echo "nginx-setup: PGBOUNCER_PUBLIC must be true or false" >&2
    exit 1
    ;;
esac
case "$PGBOUNCER_UPSTREAM_PORT" in
  *[!0-9]*|'')
    echo "nginx-setup: PGBOUNCER_UPSTREAM_PORT must be a numeric TCP port" >&2
    exit 1
    ;;
esac
case "$PGBOUNCER_PUBLIC_PORT" in
  *[!0-9]*|'')
    echo "nginx-setup: PGBOUNCER_PUBLIC_PORT must be a numeric TCP port" >&2
    exit 1
    ;;
esac
if [ "$PGBOUNCER_PUBLIC" = "true" ] && [ "$PGBOUNCER_TLS" = "false" ] && [ -z "$PGBOUNCER_ALLOWED_CIDR" ]; then
  echo "nginx-setup: plaintext public PgBouncer requires PGBOUNCER_ALLOWED_CIDR" >&2
  exit 1
fi

echo "nginx-setup: DOMAIN=$DOMAIN PGBOUNCER_PUBLIC=$PGBOUNCER_PUBLIC PGBOUNCER_TLS=$PGBOUNCER_TLS"

# ---- apt install ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  nginx libnginx-mod-stream \
  certbot python3-certbot-nginx \
  dnsutils curl ufw

# ---- DNS pre-check ----
server_ip="$(curl -fsS https://api.ipify.org)"
if [ -z "$server_ip" ]; then
  echo "nginx-setup: could not determine this server's public IP via ipify" >&2
  exit 1
fi

subdomains=("grafana.$DOMAIN" "pghero.$DOMAIN" "dozzle.$DOMAIN")
if [ "$PGBOUNCER_PUBLIC" = "true" ] && [ "$PGBOUNCER_TLS" = "true" ]; then
  subdomains+=("$DOMAIN")
fi

for host in "${subdomains[@]}"; do
  dns_ip="$(dig +short "$host" A | tail -n1)"
  if [ -z "$dns_ip" ]; then
    echo "nginx-setup: DNS for $host does not resolve. Create an A-record -> $server_ip and wait for propagation." >&2
    exit 1
  fi
  if [ "$dns_ip" != "$server_ip" ]; then
    echo "nginx-setup: DNS for $host points to $dns_ip, but this server's public IP is $server_ip. Fix DNS and re-run." >&2
    exit 1
  fi
done
echo "nginx-setup: DNS OK for ${subdomains[*]}"

# ---- render templates ----
render() {
  local source="$1" target="$2"
  local content
  content="$(cat "$source")"
  local var_name var_value
  while [[ "$content" =~ \$\{([A-Z_][A-Z0-9_]*)\} ]]; do
    var_name="${BASH_REMATCH[1]}"
    eval "var_value=\${$var_name-__UNSET__}"
    if [ "$var_value" = "__UNSET__" ]; then
      echo "nginx-setup: template $source references \${$var_name} but it is not set" >&2
      exit 1
    fi
    content="${content//\$\{$var_name\}/$var_value}"
  done
  printf '%s\n' "$content" > "$target"
}

mkdir -p /etc/nginx/streams-enabled
render nginx/pgbunker.conf.tmpl        /etc/nginx/sites-available/pgbunker
if [ "$PGBOUNCER_PUBLIC" = "true" ]; then
  render nginx/pgbunker-stream.conf.tmpl /etc/nginx/streams-enabled/pgbunker.conf
else
  rm -f /etc/nginx/streams-enabled/pgbunker.conf
fi

ln -sf /etc/nginx/sites-available/pgbunker /etc/nginx/sites-enabled/pgbunker
rm -f /etc/nginx/sites-enabled/default

# ---- ensure top-level stream include exists in nginx.conf ----
if [ "$PGBOUNCER_PUBLIC" = "true" ] && ! grep -q "streams-enabled" /etc/nginx/nginx.conf; then
  cat >> /etc/nginx/nginx.conf <<'NGINX_APPEND'

# Added by pgbunker nginx-setup.sh
stream {
    include /etc/nginx/streams-enabled/*.conf;
}
NGINX_APPEND
fi

nginx -t
systemctl reload nginx

# ---- UFW ----
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ufw allow 22/tcp   >/dev/null
ufw allow 80/tcp   >/dev/null
ufw allow 443/tcp  >/dev/null
ufw --force delete allow 6432/tcp >/dev/null 2>&1 || true
ufw --force delete allow "$PGBOUNCER_PUBLIC_PORT/tcp" >/dev/null 2>&1 || true
if [ "$PGBOUNCER_PUBLIC" = "true" ]; then
  if [ "$PGBOUNCER_TLS" = "true" ]; then
    ufw allow "$PGBOUNCER_PUBLIC_PORT/tcp" >/dev/null
  else
    ufw allow from "$PGBOUNCER_ALLOWED_CIDR" to any port "$PGBOUNCER_PUBLIC_PORT" proto tcp >/dev/null
  fi
fi
ufw --force enable >/dev/null

# ---- certbot ----
certbot_domains=(-d "grafana.$DOMAIN" -d "pghero.$DOMAIN" -d "dozzle.$DOMAIN")
if [ "$PGBOUNCER_PUBLIC" = "true" ] && [ "$PGBOUNCER_TLS" = "true" ]; then
  certbot_domains+=(-d "$DOMAIN")
fi

certbot --nginx \
  --non-interactive --agree-tos --redirect \
  -m "$LE_EMAIL" \
  "${certbot_domains[@]}"

# ---- optional PgBouncer TLS deploy-hook ----
hook_path="/etc/letsencrypt/renewal-hooks/deploy/pgbunker.sh"
if [ "$PGBOUNCER_PUBLIC" = "true" ] && [ "$PGBOUNCER_TLS" = "true" ]; then
  # Certbot names the cert after the first -d argument.
  cert_name="grafana.$DOMAIN"
  mkdir -p "$(dirname "$hook_path")"

  cat > "$hook_path" <<HOOK
#!/bin/sh
# Auto-installed by pgbunker nginx-setup.sh. Runs after every cert renewal.
set -eu
live_dir="/etc/letsencrypt/live/$cert_name"
cert_dst="$PROJECT_DIR/pgbouncer/certs"
mkdir -p "\$cert_dst"
cp "\$live_dir/fullchain.pem" "\$cert_dst/fullchain.pem"
cp "\$live_dir/privkey.pem"   "\$cert_dst/privkey.pem"
chown 70:70 "\$cert_dst/fullchain.pem" "\$cert_dst/privkey.pem"
chmod 644 "\$cert_dst/fullchain.pem"
chmod 600 "\$cert_dst/privkey.pem"
cd "$PROJECT_DIR" && docker compose kill -s HUP pgbouncer 2>/dev/null || true
HOOK
  chmod +x "$hook_path"

  # Run once now so first-time certs land in place and pgbouncer reloads.
  "$hook_path"
else
  rm -f "$hook_path"
fi

echo ""
echo "nginx-setup: done."
echo "  Grafana: https://grafana.$DOMAIN"
echo "  PgHero:  https://pghero.$DOMAIN"
echo "  Dozzle:  https://dozzle.$DOMAIN"
if [ "$PGBOUNCER_PUBLIC" = "true" ] && [ "$PGBOUNCER_TLS" = "true" ]; then
  echo "  DB:      postgresql://USER:PASS@$DOMAIN:$PGBOUNCER_PUBLIC_PORT/DB?sslmode=require"
elif [ "$PGBOUNCER_PUBLIC" = "true" ]; then
  echo "  DB:      postgresql://USER:PASS@$DOMAIN:$PGBOUNCER_PUBLIC_PORT/DB   (restricted to $PGBOUNCER_ALLOWED_CIDR by UFW)"
else
  echo "  DB:      private on 127.0.0.1:$PGBOUNCER_UPSTREAM_PORT; use SSH tunnel, VPN, or set PGBOUNCER_PUBLIC=true"
fi
