#!/bin/bash
# EU Exit Node Setup - Robust Version + Base64URL Safe Link
set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo or as root."
    echo "Usage: sudo bash $0"
    exit 1
fi

export PATH=$PATH:/usr/local/bin

source "$(dirname "${BASH_SOURCE[0]}")/sni-config.sh"

echo "=========================================================="
echo "                 EU EXIT NODE SETUP                       "
echo "=========================================================="
echo "SNI targets:"
echo "  :${PORT_1} → ${SNI_1}"
echo "  :${PORT_2} → ${SNI_2}"
echo "  :${PORT_3} → ${SNI_3}"
echo "=========================================================="
read -p "Enter BARK_KEY (leave blank to skip notifications): " BARK_KEY
read -p "Enter RU Bridge VPS IP (leave blank to skip peer monitors): " RU_IP
echo "=========================================================="

# ── Wipe previous install — clean slate ──────────────────────────────────────
echo "[Wipe] Removing previous Xray/monitoring install..."
systemctl stop xray tls-push-monitor node-exporter 2>/dev/null || true
systemctl disable xray tls-push-monitor node-exporter 2>/dev/null || true
rm -f /etc/systemd/system/tls-push-monitor.service
rm -f /etc/systemd/system/xray.service.d/override.conf
rmdir /etc/systemd/system/xray.service.d 2>/dev/null || true
rm -f /usr/local/etc/xray/config.json
rm -f /usr/local/etc/xray/user_links.txt
rm -f /etc/logrotate.d/xray
rm -f /usr/local/bin/tls-push-monitor.sh
rm -f /etc/xray-kuma.env
rm -f /etc/xray-monitor.env
rm -f /etc/systemd/system/node-exporter.service
rm -f /usr/local/bin/node_exporter
rm -rf /var/log/xray
(crontab -l 2>/dev/null | grep -v "russia-v2ray-rules-dat" || true) | crontab -
systemctl daemon-reload
echo "[Wipe] Done."
# ─────────────────────────────────────────────────────────────────────────────

echo "1. Checking/Installing Dependencies..."
apt update && apt install -y git curl openssl cron jq

echo "2. Installing Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "3. Generating Credentials..."
UUID=$(xray uuid)
REALITY_KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/Private/ {print $NF}')
PUBLIC_KEY=$(echo "$REALITY_KEYS"  | awk '/Public/  {print $NF}')

# Robust Fallback: extract just the value from lines 1 and 2
if [ -z "$PRIVATE_KEY" ]; then
    PRIVATE_KEY=$(echo "$REALITY_KEYS" | head -n 1 | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$REALITY_KEYS"  | tail -n 1 | awk '{print $NF}')
fi

# Validation: Stop if keys are empty
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "[FAIL] Could not extract REALITY keys. Xray output was:"
    echo "$REALITY_KEYS"
    exit 1
fi

SHORT_ID=$(openssl rand -hex 4)
IP=$(curl -4 -s https://ifconfig.me)

echo "4. Creating Xray Server Configuration..."
mkdir -p /var/log/xray
chown nobody:nogroup /var/log/xray

# Setup log rotation to prevent SSD space exhaustion
cat > /etc/logrotate.d/xray << 'EOF'
/var/log/xray/*.log {
    daily
    rotate 3
    size 50M
    compress
    delaycompress
    missingok
    notifempty
    su nobody nogroup
    create 0640 nobody nogroup
    postrotate
        systemctl kill -s USR1 xray.service >/dev/null 2>&1 || true
    endscript
}
EOF

cat > /usr/local/etc/xray/config.json << XRAY_EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "inbounds": [
    {
      "tag": "in-sni-1",
      "port": $PORT_1,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "stream-one",
          "path": "/unicorn-magic",
          "xPaddingBytes": "100-1000",
          "xmux": {
            "maxConcurrency": "8-16",
            "cMaxReuseTimes": "64-128",
            "hMaxRequestTimes": "600-900"
          }
        },
        "realitySettings": {
          "show": false,
          "dest": "${SNI_1}:443",
          "xver": 0,
          "serverNames": ["$SNI_1"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    },
    {
      "tag": "in-sni-2",
      "port": $PORT_2,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "stream-one",
          "path": "/unicorn-magic",
          "xPaddingBytes": "100-1000",
          "xmux": {
            "maxConcurrency": "8-16",
            "cMaxReuseTimes": "64-128",
            "hMaxRequestTimes": "600-900"
          }
        },
        "realitySettings": {
          "show": false,
          "dest": "${SNI_2}:443",
          "xver": 0,
          "serverNames": ["$SNI_2"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    },
    {
      "tag": "in-sni-3",
      "port": $PORT_3,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "mode": "stream-one",
          "path": "/unicorn-magic",
          "xPaddingBytes": "100-1000",
          "xmux": {
            "maxConcurrency": "8-16",
            "cMaxReuseTimes": "64-128",
            "hMaxRequestTimes": "600-900"
          }
        },
        "realitySettings": {
          "show": false,
          "dest": "${SNI_3}:443",
          "xver": 0,
          "serverNames": ["$SNI_3"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block-ru" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "block-ru", "domain": ["geosite:category-ru", "geosite:ru-available-only-inside"] },
      { "type": "field", "outboundTag": "block-ru", "ip": ["geoip:ru"] }
    ]
  }
}
XRAY_EOF

echo "4.1. Opening UFW ports ${PORT_2} and ${PORT_3}..."
if command -v ufw &>/dev/null; then
    ufw allow ${PORT_2}/tcp
    ufw allow ${PORT_3}/tcp
fi

# Apply correct config settings
echo "5.1. Modifying Configuration..."
mkdir -p /etc/systemd/system/xray.service.d/ && printf '[Service]\nRestart=always\nRestartSec=5\n' | tee /etc/systemd/system/xray.service.d/override.conf > /dev/null && systemctl daemon-reload

echo "5.2. Downloading Runet routing databases & configuring auto-updates..."
mkdir -p /usr/local/share/xray
curl -sL -o /usr/local/share/xray/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat
curl -sL -o /usr/local/share/xray/geoip.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat

echo "5. Testing Xray Configuration..."
# TEST BEFORE RESTART (prevents leaving xray in a crashed state)
if ! xray -test -c /usr/local/etc/xray/config.json; then
    echo "[FAIL] Configuration error! Aborting restart."
    exit 1
fi

CRON_JOB="0 3 * * 0 curl -sL -o /usr/local/share/xray/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat && curl -sL -o /usr/local/share/xray/geoip.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat && systemctl restart xray"
(crontab -l 2>/dev/null | grep -v "russia-v2ray-rules-dat" || true; echo "$CRON_JOB") | crontab -

echo "6. Restarting Xray..."
systemctl restart xray
sleep 2

# Convert Base64 to Base64URL (natively supported by Xray, immune to URL parser bugs)
PBK_URLSAFE=$(echo "$PUBLIC_KEY" | tr '+/' '-_' | tr -d '=')

# Generate Share Link (using Base64URL for pbk, unescaped path)
SHARE_LINK="vless://$UUID@$IP:${PORT_1}?encryption=none&security=reality&sni=${SNI_1}&fp=chrome&pbk=$PBK_URLSAFE&sid=$SHORT_ID&type=xhttp&path=/unicorn-magic&mode=stream-one#EU-EXIT-FALLBACK"

# Persist share link for future reference
mkdir -p /usr/local/etc/xray
LINKS_FILE="/usr/local/etc/xray/user_links.txt"
echo "$(date -Iseconds) - EU Exit (Primary): $SHARE_LINK" >> "$LINKS_FILE"

echo "=========================================================="
echo "                   EU SETUP COMPLETE                      "
echo "=========================================================="
echo "EU UUID:             $UUID"
echo "EU Public Key:       $PUBLIC_KEY"
echo "EU Short ID:         $SHORT_ID"
echo ""
echo "SHARABLE VLESS LINK (Copy & Import):"
echo -e "\e[32m$SHARE_LINK\e[0m"
echo "✅ Link saved to: $LINKS_FILE"
echo "=========================================================="
echo "[PASS] Xray is running correctly!"

echo "7. Installing Node Exporter..."
RU_IP="$RU_IP" bash "$(dirname "$0")/setup-node-exporter.sh"

echo "8. Installing TLS push monitor (baseline mode)..."
cat > /etc/xray-monitor.env << EOF
TLS_TARGETS=${SNI_1}:443,${SNI_2}:443,${SNI_3}:443
TLS_RESOLVE_TO=
TLS_MODE=baseline
TLS_PUSHGATEWAY_URL=http://${RU_IP}:9091
EOF
chmod 600 /etc/xray-monitor.env

cp "$(dirname "$0")/tls-push-monitor.sh" /usr/local/bin/tls-push-monitor.sh
chmod +x /usr/local/bin/tls-push-monitor.sh

# tls-push-monitor.service must exist in the repo
cp "$(dirname "$0")/tls-push-monitor.service" /etc/systemd/system/tls-push-monitor.service
systemctl daemon-reload
systemctl enable --now tls-push-monitor

echo "=========================================================="
echo "         EU MONITORING INSTALL COMPLETE                   "
echo "=========================================================="
echo "Node Exporter: :9100 (whitelisted to RU VPS only)"
echo "TLS push monitor: running in baseline mode"
echo "Pushing metrics to: http://${RU_IP}:9091"
echo "=========================================================="

