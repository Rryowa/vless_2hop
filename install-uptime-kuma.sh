#!/bin/bash
# Installs monitoring infrastructure for the two-hop stealth proxy.
#
# Two modes (detected via flags):
#   --kuma-host    Full Kuma install (RU node): Node.js, Uptime Kuma, nginx HTTPS
#                  reverse proxy with Let's Encrypt, configure-kuma.py, tls-push-monitor.sh (DPI mode),
#                  log-capture-webhook
#   --remote-push  Lightweight install (EU node): env file + tls-push-monitor.sh only
#                  (baseline mode, pushes to RU Kuma)
#
# Environment variables (set by caller):
#   BARK_KEY       - Bark device key for push notifications (RU mode only)
#   PEER_IP        - IP of the peer VPS
#   PEER_SNI       - SNI hostname for peer's Reality cert
#   LOCAL_SNI      - SNI hostname for this server's Reality cert
#   EU_SNIS        - EU baseline targets: host:port,... (RU mode only)
#   RU_SNIS        - RU DPI probe targets: host:port,... (RU mode only)
#   KUMA_DOMAIN    - Domain for Kuma dashboard with Let's Encrypt cert (RU mode only)

set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo or as root."
    echo "Usage: sudo bash $0 --kuma-host|--remote-push"
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUMA_HOST=false
REMOTE_PUSH=false
for arg in "$@"; do
    case "$arg" in
        --kuma-host)   KUMA_HOST=true ;;
        --remote-push) REMOTE_PUSH=true ;;
    esac
done

install_tls_push_monitor() {
    echo "[TLS] Installing tls-push-monitor service..."
    cp "$REPO_DIR/tls-push-monitor.sh" /usr/local/bin/tls-push-monitor.sh
    chmod +x /usr/local/bin/tls-push-monitor.sh

    cp "$REPO_DIR/tls-push-monitor.service" /etc/systemd/system/tls-push-monitor.service
    systemctl daemon-reload
    systemctl enable --now tls-push-monitor
    echo "[TLS] Service started (30s interval)."
}

# ═══════════════════════════════════════════════════════════════════════════════
# EU NODE — Lightweight (env file + tls-push-monitor only)
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$REMOTE_PUSH" = true ]; then
    echo "=========================================================="
    echo "   EU LIGHTWEIGHT MONITORING INSTALL (no Kuma)            "
    echo "=========================================================="

    if [ -z "$RU_IP" ] && [ -z "$PEER_IP" ]; then
        echo "[ERROR] RU IP not set. Pass RU_IP or PEER_IP env var."
        exit 1
    fi
    if [ -z "$KUMA_DOMAIN" ]; then
        echo "[ERROR] KUMA_DOMAIN not set. Pass KUMA_DOMAIN env var."
        exit 1
    fi
    RU_IP="${RU_IP:-$PEER_IP}"

    if [ ! -f /etc/xray-kuma.env ]; then
        echo "[TLS] Writing env file template..."
        cat > /etc/xray-kuma.env << EOF
PEER_IP=${RU_IP}
PEER_SNI=${PEER_SNI:-vkvideo.ru}
LOCAL_SNI=${LOCAL_SNI:-debian.snt.utwente.nl}
TLS_TARGETS=${TLS_TARGETS:-debian.snt.utwente.nl:443,nl.archive.ubuntu.com:443,eclipse.mirror.liteserver.nl:443}
TLS_RESOLVE_TO=
KUMA_PUSH_URL=https://${KUMA_DOMAIN}:3001
TLS_PUSH_TOKENS='{}'
EOF
        chmod 600 /etc/xray-kuma.env
        echo ""
        echo "[TLS] IMPORTANT: After running configure-kuma.py on the RU node,"
        echo "[TLS] copy the EU baseline env contents to /etc/xray-kuma.env on this node."
        echo "[TLS] The file must contain the correct TLS_PUSH_TOKENS from the RU Kuma."
    else
        echo "[TLS] /etc/xray-kuma.env already exists, not overwriting."
    fi

    install_tls_push_monitor

    echo "=========================================================="
    echo "   EU LIGHTWEIGHT MONITORING INSTALLED                    "
    echo "=========================================================="
    echo "TLS push monitor running in baseline mode."
    echo "Pushing to: https://${KUMA_DOMAIN}:3001"
    echo ""
    echo "Next steps:"
    echo "  1. Run install-uptime-kuma.sh --kuma-host on the RU node"
    echo "  2. Copy the EU baseline env file contents printed by"
    echo "     configure-kuma.py to this node's /etc/xray-kuma.env"
    echo "  3. Restart: systemctl restart tls-push-monitor"
    echo "=========================================================="
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RU NODE — Full Kuma Install
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$KUMA_HOST" != true ]; then
    echo "[ERROR] Must specify --kuma-host (RU full install) or --remote-push (EU lightweight)."
    exit 1
fi

KUMA_DIR="/opt/uptime-kuma"

read -rp "Kuma admin username: " KUMA_USER
read -rsp "Kuma admin password: " KUMA_PASS
echo
if [ -z "$KUMA_USER" ] || [ -z "$KUMA_PASS" ]; then
    echo "[ERROR] Kuma username and password cannot be empty."
    exit 1
fi

# ── 1. Node.js ────────────────────────────────────────────────────────────────
echo "[Kuma] Checking Node.js..."
NODE_OK=false
if command -v node &>/dev/null; then
    NODE_MAJOR=$(node --version | sed 's/v\([0-9]*\).*/\1/')
    [ "$NODE_MAJOR" -ge 18 ] && NODE_OK=true
fi

if [ "$NODE_OK" = false ]; then
    echo "[Kuma] Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# ── 1b. uptime-kuma-api Python library ───────────────────────────────────────
echo "[Kuma] Installing uptime-kuma-api..."
apt install -y python3-pip python3 --no-install-recommends
pip3 install --break-system-packages --quiet uptime-kuma-api

# ── 2. Uptime Kuma ────────────────────────────────────────────────────────────
echo "[Kuma] Cloning Uptime Kuma..."
rm -rf "$KUMA_DIR"
git clone https://github.com/louislam/uptime-kuma.git "$KUMA_DIR"

echo "[Kuma] Running npm setup (this may take a minute)..."
cd "$KUMA_DIR"
npm run setup --silent

mkdir -p "$KUMA_DIR/data"
chown -R nobody:nogroup "$KUMA_DIR/data"
chmod 755 "$KUMA_DIR/data"

# ── 3. Systemd service ────────────────────────────────────────────────────────
cat > /etc/systemd/system/uptime-kuma.service << 'EOF'
[Unit]
Description=Uptime Kuma Monitoring
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=/opt/uptime-kuma
Environment=NODE_ENV=production
Environment=UPTIME_KUMA_HOST=127.0.0.1
ExecStart=/usr/bin/node server/server.js --port=3001
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now uptime-kuma

# ── 4. Wait for Kuma to be ready ─────────────────────────────────────────────
echo "[Kuma] Waiting for Uptime Kuma to start (up to 60s)..."
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:3001 > /dev/null 2>&1; then
        echo "[Kuma] Ready."
        break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
        echo "[Kuma] ERROR: Uptime Kuma did not start in time."
        exit 1
    fi
done

# ── 5. Let's Encrypt + Nginx HTTPS reverse proxy ──────────────────────────
if [ -z "$KUMA_DOMAIN" ]; then
    echo "[ERROR] KUMA_DOMAIN not set. Pass KUMA_DOMAIN env var."
    exit 1
fi

echo "[Nginx] Installing nginx and certbot..."
apt install -y nginx certbot python3-certbot-nginx

# Stop nginx temporarily so certbot standalone can bind port 80
systemctl stop nginx 2>/dev/null || true

echo "[Certbot] Obtaining Let's Encrypt certificate for ${KUMA_DOMAIN}..."
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$KUMA_DOMAIN"

CERT_PATH="/etc/letsencrypt/live/${KUMA_DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${KUMA_DOMAIN}/privkey.pem"

cat > /etc/nginx/sites-available/kuma-proxy << EOF
server {
    listen 3001 ssl;
    server_name ${KUMA_DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass         http://127.0.0.1:13001;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/kuma-proxy /etc/nginx/sites-enabled/kuma-proxy

# Kuma must bind to a different port so nginx can take 3001
echo "[Nginx] Moving Kuma to port 13001 (nginx proxies 3001 -> 13001)..."
sed -i 's/--port=3001/--port=13001/' /etc/systemd/system/uptime-kuma.service
systemctl daemon-reload
systemctl restart uptime-kuma
sleep 3

nginx -t
systemctl enable nginx
systemctl reload-or-restart nginx

# UFW: allow public access to dashboard + ACME
if command -v ufw &>/dev/null; then
    ufw allow 3001/tcp
    ufw allow 80/tcp
    echo "[Nginx] UFW rules added: ports 3001 (HTTPS dashboard) + 80 (ACME)"
fi

# Certbot auto-renew
systemctl enable certbot.timer 2>/dev/null || true

echo "[Nginx] HTTPS proxy active: ${KUMA_DOMAIN}:3001 -> 127.0.0.1:13001 (Kuma)"

# ── 6. Write base env file, then configure Kuma ──────────────────────────────
RU_IP=$(curl -4 -sf https://ifconfig.me 2>/dev/null || echo "")

if [ -z "$RU_IP" ]; then
    echo "[Kuma] WARNING: Could not auto-detect RU public IP."
    read -rp "Enter this server's public IP manually: " RU_IP
    if [ -z "$RU_IP" ]; then
        echo "[Kuma] ERROR: RU IP is required for EU env file. Aborting."
        exit 1
    fi
fi

echo "[Kuma] Configuring admin account and monitors..."
python3 "$REPO_DIR/configure-kuma.py" \
    "http://127.0.0.1:13001" \
    "$KUMA_USER" "$KUMA_PASS" \
    --eu-ip "$PEER_IP" \
    --ru-ip "$RU_IP" \
    --eu-snis "${EU_SNIS:-debian.snt.utwente.nl:443,nl.archive.ubuntu.com:443,eclipse.mirror.liteserver.nl:443}" \
    --ru-snis "${RU_SNIS:-debian.snt.utwente.nl:443,nl.archive.ubuntu.com:8443,eclipse.mirror.liteserver.nl:9443}" \
    --local-sni "${LOCAL_SNI:-vkvideo.ru}" \
    --peer-sni "${PEER_SNI:-debian.snt.utwente.nl}" \
    --domain "${KUMA_DOMAIN}" \
    --env-file /etc/xray-kuma.env \
    --eu-env-file /tmp/xray-kuma-env-eu-baseline

echo "KUMA_USER=${KUMA_USER}" >> /etc/xray-kuma.env
echo "KUMA_PASS=${KUMA_PASS}" >> /etc/xray-kuma.env

# ── 7. Install log-capture webhook ───────────────────────────────────────────
echo "[Webhook] Installing log-capture webhook server..."

WEBHOOK_SRC="$REPO_DIR/log-capture-webhook.py"
if [ ! -f "$WEBHOOK_SRC" ]; then
    echo "[Webhook] WARNING: log-capture-webhook.py not found in repo dir, skipping."
else
    ESCAPED_KEY=$(printf '%s' "$BARK_KEY" | sed 's/[&/\\]/\\&/g')
    sed "s/BARK_KEY_PLACEHOLDER/$ESCAPED_KEY/" "$WEBHOOK_SRC" > /opt/log-capture-webhook.py
    chmod 755 /opt/log-capture-webhook.py

    cp "$REPO_DIR/log-capture-webhook.service" /etc/systemd/system/log-capture-webhook.service
    mkdir -p /var/log/xray/incidents
    chown -R nobody:nogroup /var/log/xray/incidents

    systemctl daemon-reload
    systemctl enable --now log-capture-webhook

    CRON_RETAIN="0 4 * * * find /var/log/xray/incidents -mtime +30 -delete"
    (crontab -l 2>/dev/null | grep -v "xray/incidents" || true; echo "$CRON_RETAIN") | crontab -
    echo "[Webhook] Installed."
fi

# ── 8. Install tls-push-monitor (DPI mode) ───────────────────────────────────
install_tls_push_monitor

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=========================================================="
echo "        UPTIME KUMA INSTALLED (RU NODE — FULL)            "
echo "=========================================================="
echo "Dashboard:"
echo "  https://${KUMA_DOMAIN}:3001"
echo ""
echo "Admin: ${KUMA_USER}"
echo "Monitors: 6 TCP + 3 TLS-Baseline + 3 TLS-DPI = 12 total"
echo ""
echo "=== EU BASELINE ENV FILE ==="
echo "Copy the following to EU node's /etc/xray-kuma.env:"
echo ""
cat /tmp/xray-kuma-env-eu-baseline
echo ""
echo "Then on EU node: systemctl restart tls-push-monitor"
echo "=========================================================="
