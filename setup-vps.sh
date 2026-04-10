#!/bin/bash
# VPS Setup: SSH Hardening + Firewall (root-only access)
# Goal: Lock down SSH to key-only root login on port 48022.

set -e

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root."
   exit 1
fi

if [ -n "$1" ] && [ -f "$1" ]; then
    PUB_KEY=$(cat "$1")
elif [ -n "$1" ]; then
    PUB_KEY="$1"
else
    read -p "Paste your SSH public key: " PUB_KEY
fi

if [ -z "$PUB_KEY" ]; then
    echo "ERROR: No public key provided."
    exit 1
fi

# ── Wipe previous install — clean slate ──────────────────────────────────────
# Restore original sshd_config from backup so sed substitutions apply cleanly
if [ -f /etc/ssh/sshd_config.bak ]; then
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
fi
# Remove any previously added UFW rules so we don't accumulate duplicates
if command -v ufw &>/dev/null; then
    ufw delete allow 48022/tcp 2>/dev/null || true
    ufw delete allow 443/tcp   2>/dev/null || true
fi
# ─────────────────────────────────────────────────────────────────────────────

echo "[1/5] Setting up SSH keys for root..."
mkdir -p /root/.ssh
echo "$PUB_KEY" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

echo "[2/5] Configuring SSH Hardening (Port 48022)..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/^#\?Port 22/Port 48022/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

echo "[3/5] Setting up UFW Firewall..."
apt update && apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 48022/tcp
ufw allow 443/tcp
ufw --force enable

echo "[4/5] Installing Fail2ban..."
apt install -y fail2ban
systemctl enable fail2ban

echo "[5/5] Limiting systemd journal logs to prevent disk full..."
journalctl --vacuum-time=3d
sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=50M/' /etc/systemd/journald.conf
systemctl restart systemd-journald

echo "[FINAL] Activating Hardening (SSH Restart)..."
systemctl restart ssh

echo "----------------------------------------------------------"
echo "SETUP COMPLETE"
echo "Password login and Port 22 are now DISABLED."
echo "Login now with: ssh -p 48022 -i <key> root@$HOSTNAME"
echo "----------------------------------------------------------"
