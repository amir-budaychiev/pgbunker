#!/usr/bin/env bash
set -euo pipefail

# Prepares an Ubuntu host to run PgBunker: swap, the kernel settings Postgres
# cares about, key-only SSH, fail2ban, automatic security updates, and a
# systemd unit so the stack survives a reboot.
#
# Idempotent: safe to re-run.

if [ "$EUID" -ne 0 ]; then
  echo "harden: must run as root (use sudo)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq systemd-zram-generator fail2ban unattended-upgrades

# ---- swap ----
# zram is compressed swap in RAM: no disk writes, no wear, far faster than a
# swapfile. Skipped entirely if the host already has swap.
if [ -z "$(swapon --show --noheadings)" ]; then
  cat > /etc/systemd/zram-generator.conf <<'ZRAM'
# Installed by pgbunker harden.sh.
# Package defaults apply: half of RAM, capped at 4 GB.
[zram0]
ZRAM
  systemctl daemon-reload
  systemctl start systemd-zram-setup@zram0.service
  echo "harden: zram swap enabled"
else
  echo "harden: swap already configured, left alone"
fi

# ---- sysctl ----
cat > /etc/sysctl.d/60-pgbunker.conf <<'SYSCTL'
# Installed by pgbunker harden.sh.
# Postgres manages its own cache, so swap only under real pressure.
vm.swappiness = 30
vm.vfs_cache_pressure = 100
SYSCTL
sysctl -q --system

# ---- transparent huge pages ----
# Postgres and THP get along badly: the kernel's background compaction stalls
# backends, and memory use inflates. Turning THP off is standard advice for any
# Postgres box. Containers share the host kernel, so it has to be set here and
# it has to be set before Docker starts.
cat > /etc/systemd/system/disable-thp.service <<'THP'
[Unit]
Description=Disable Transparent Huge Pages (THP)
After=sysinit.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=multi-user.target
THP
systemctl daemon-reload
systemctl enable --now disable-thp.service
echo "harden: THP is now $(cat /sys/kernel/mm/transparent_hugepage/enabled)"

# ---- SSH: keys only ----
# The 00- prefix is load-bearing. sshd applies the FIRST directive it sees and
# reads the drop-in directory in lexicographic order, and hosting providers
# often ship their own 40-*.conf. A later name would silently lose.
ssh_user="${SUDO_USER:-root}"
ssh_home="$(getent passwd "$ssh_user" | cut -d: -f6)"
if [ -s "$ssh_home/.ssh/authorized_keys" ]; then
  cat > /etc/ssh/sshd_config.d/00-pgbunker-hardening.conf <<'SSHD'
# Installed by pgbunker harden.sh. Key-only login.
PasswordAuthentication no
PermitRootLogin prohibit-password
SSHD
  if sshd -t; then
    systemctl reload ssh
    echo "harden: password login disabled, key-only from now on"
  else
    rm -f /etc/ssh/sshd_config.d/00-pgbunker-hardening.conf
    echo "harden: sshd rejected the new config, change reverted" >&2
    exit 1
  fi
else
  echo "harden: WARNING - no SSH key found in $ssh_home/.ssh/authorized_keys" >&2
  echo "harden: password login left ON. Disabling it now would lock you out." >&2
  echo "harden: run 'ssh-copy-id $ssh_user@<this-host>' from your laptop, then re-run this script." >&2
fi

# ---- fail2ban ----
# The packaged jail is enabled but permissive. These numbers are what a public
# SSH port actually needs.
cat > /etc/fail2ban/jail.local <<'JAIL'
# Installed by pgbunker harden.sh.
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 22
backend = systemd
JAIL
systemctl enable fail2ban
systemctl restart fail2ban

# ---- automatic security updates ----
systemctl enable --now unattended-upgrades

# ---- keep the stack running across reboots ----
# Containers already carry restart: unless-stopped, which covers an ordinary
# reboot on its own. This unit adds three things that does not: a start ordered
# after Docker and the network, a clean `systemctl stop pgbunker`, and recovery
# if someone ran `docker compose down` and then rebooted.
# Profiles come from COMPOSE_PROFILES in .env, so they are not hardcoded here.
cat > /etc/systemd/system/pgbunker.service <<UNIT
[Unit]
Description=PgBunker docker compose stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_DIR
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable pgbunker.service

echo ""
echo "harden: done."
echo "--- swap ---"
swapon --show || echo "(none)"
echo "--- THP ---"
cat /sys/kernel/mm/transparent_hugepage/enabled
echo "--- ssh ---"
sshd -T | grep -E '^(passwordauthentication|permitrootlogin)'
echo "--- fail2ban ---"
fail2ban-client status sshd 2>/dev/null | head -4 || echo "(jail not reporting yet)"
echo "--- autostart ---"
echo "pgbunker.service is enabled; it starts the stack on the next boot."
echo "Once .env is filled in you can also start it now: systemctl start pgbunker"
