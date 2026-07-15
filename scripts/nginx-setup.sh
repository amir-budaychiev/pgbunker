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
PROMETHEUS_PUBLIC="${PROMETHEUS_PUBLIC:-false}"
PROMETHEUS_PUBLIC_PORT="${PROMETHEUS_PUBLIC_PORT:-9090}"
PROMETHEUS_UPSTREAM_PORT="${PROMETHEUS_UPSTREAM_PORT:-19090}"
PROMETHEUS_ALLOWED_IPS="${PROMETHEUS_ALLOWED_IPS:-}"

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
case "$PROMETHEUS_PUBLIC" in
  true|false) ;;
  *)
    echo "nginx-setup: PROMETHEUS_PUBLIC must be true or false" >&2
    exit 1
    ;;
esac
case "$PROMETHEUS_PUBLIC_PORT" in
  *[!0-9]*|'')
    echo "nginx-setup: PROMETHEUS_PUBLIC_PORT must be a numeric TCP port" >&2
    exit 1
    ;;
esac
case "$PROMETHEUS_UPSTREAM_PORT" in
  *[!0-9]*|'')
    echo "nginx-setup: PROMETHEUS_UPSTREAM_PORT must be a numeric TCP port" >&2
    exit 1
    ;;
esac
if [ "$PROMETHEUS_PUBLIC" = "true" ] && [ -z "$PROMETHEUS_ALLOWED_IPS" ]; then
  echo "nginx-setup: public Prometheus requires PROMETHEUS_ALLOWED_IPS (IP allowlist)" >&2
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

hostnames=("$DOMAIN")

for host in "${hostnames[@]}"; do
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
echo "nginx-setup: DNS OK for ${hostnames[*]}"

# ---- shared basic-auth file for all four web panels ----
# Grafana, PgHero, Dozzle, and vmui all check the SAME realm/file, so the
# browser prompts once and reuses it for all four — see docs/superpowers/plans
# /2026-07-15-unified-panel-login.md for the full design.
: "${PANEL_USER:?PANEL_USER is not set in .env}"
: "${PANEL_PASSWORD:?PANEL_PASSWORD is not set in .env}"
echo "nginx-setup: generating shared panel htpasswd for $PANEL_USER"
printf '%s:%s\n' "$PANEL_USER" "$(openssl passwd -apr1 "$PANEL_PASSWORD")" > /etc/nginx/pgbunker-panels.htpasswd
chown root:www-data /etc/nginx/pgbunker-panels.htpasswd
chmod 640 /etc/nginx/pgbunker-panels.htpasswd

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

# ---- landing page served at / ----
mkdir -p /var/www/pgbunker
cp nginx/landing.html /var/www/pgbunker/index.html

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
ufw --force delete allow "$PROMETHEUS_PUBLIC_PORT/tcp" >/dev/null 2>&1 || true
if [ "$PROMETHEUS_PUBLIC" = "true" ]; then
  for prometheus_ip in $PROMETHEUS_ALLOWED_IPS; do
    ufw allow from "$prometheus_ip" to any port "$PROMETHEUS_PUBLIC_PORT" proto tcp >/dev/null
  done
fi
ufw --force enable >/dev/null

# ---- certbot ----
# Remove any existing pgbunker-prometheus site FIRST: certbot's --nginx plugin
# scans every enabled site for a matching server_name, and pgbunker-prometheus
# already carries `ssl_certificate` lines for this exact domain (baked into its
# own template, not certbot-managed despite the comment). On a re-run, certbot
# sees that as "already satisfied" and skips the real (pgbunker) site entirely
# — leaving it with no HTTPS block at all. It's regenerated fresh below
# regardless (when PROMETHEUS_PUBLIC=true), so removing it here loses nothing.
rm -f /etc/nginx/sites-enabled/pgbunker-prometheus /etc/nginx/sites-available/pgbunker-prometheus

certbot_domains=(-d "$DOMAIN")

certbot --nginx \
  --non-interactive --agree-tos --redirect \
  -m "$LE_EMAIL" \
  "${certbot_domains[@]}"

# ---- sanity check: catch a self-redirect loop ----
# `nginx -t` only validates syntax — a server block that redirects to its own
# exact URL (seen once: certbot duplicated its `if ($host = ...) return 301`
# snippet into both the HTTPS and HTTP blocks instead of just the HTTP one)
# is syntactically valid but functionally broken, and would otherwise ship
# silently.
redirect_target="$(curl -s -o /dev/null -w '%{redirect_url}' "https://$DOMAIN/" || true)"
if [ "$redirect_target" = "https://$DOMAIN/" ]; then
  echo "nginx-setup: ERROR - https://$DOMAIN/ redirects to itself. Check /etc/nginx/sites-available/pgbunker for a duplicated 'if (\$host = ...) return 301' block — it should appear only in the plain :80 catch-all server block, not the :443 ssl one." >&2
  exit 1
fi

# ---- optional public Prometheus (TLS-terminated by nginx, IP-allowlisted) ----
# Enabled only after certbot, because the server block references the live cert.
if [ "$PROMETHEUS_PUBLIC" = "true" ]; then
  allow_directives=""
  for prometheus_ip in $PROMETHEUS_ALLOWED_IPS; do
    allow_directives="${allow_directives}    allow ${prometheus_ip};"$'\n'
  done
  export PROMETHEUS_ALLOW_DIRECTIVES="${allow_directives%$'\n'}"
  render nginx/pgbunker-prometheus.conf.tmpl /etc/nginx/sites-available/pgbunker-prometheus
  ln -sf /etc/nginx/sites-available/pgbunker-prometheus /etc/nginx/sites-enabled/pgbunker-prometheus
  nginx -t
  systemctl reload nginx
else
  rm -f /etc/nginx/sites-enabled/pgbunker-prometheus /etc/nginx/sites-available/pgbunker-prometheus
fi

# ---- optional PgBouncer TLS deploy-hook ----
hook_path="/etc/letsencrypt/renewal-hooks/deploy/pgbunker.sh"
if [ "$PGBOUNCER_PUBLIC" = "true" ] && [ "$PGBOUNCER_TLS" = "true" ]; then
  # Certbot names the cert after the first -d argument.
  cert_name="$DOMAIN"
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
echo "  Home:    https://$DOMAIN/"
echo "  Grafana: https://$DOMAIN/grafana"
echo "  PgHero:  https://$DOMAIN/pghero"
echo "  Dozzle:  https://$DOMAIN/dozzle"
if [ "$PROMETHEUS_PUBLIC" = "true" ]; then
  echo "  Prom:    https://$DOMAIN:$PROMETHEUS_PUBLIC_PORT/   (allowlisted: $PROMETHEUS_ALLOWED_IPS)"
fi
if [ "$PGBOUNCER_PUBLIC" = "true" ] && [ "$PGBOUNCER_TLS" = "true" ]; then
  echo "  DB:      postgresql://USER:PASS@$DOMAIN:$PGBOUNCER_PUBLIC_PORT/DB?sslmode=require"
elif [ "$PGBOUNCER_PUBLIC" = "true" ]; then
  echo "  DB:      postgresql://USER:PASS@$DOMAIN:$PGBOUNCER_PUBLIC_PORT/DB   (restricted to $PGBOUNCER_ALLOWED_CIDR by UFW)"
else
  echo "  DB:      private on 127.0.0.1:$PGBOUNCER_UPSTREAM_PORT; use SSH tunnel, VPN, or set PGBOUNCER_PUBLIC=true"
fi
