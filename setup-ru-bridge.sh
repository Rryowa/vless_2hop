#!/bin/bash
# RU Bridge Node Setup - Robust Version + Share Link
# Standard Multi-Hop (Vision-to-XHTTP) & TSPU Evasion

set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo or as root."
    echo "Usage: sudo bash $0"
    exit 1
fi

export PATH=$PATH:/usr/local/bin

# --- Load Environment Variables ---
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
    # Source .env, ignoring comments and xargs to handle potential spaces
    export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

# Helper to save to .env
update_env() {
    local key=$1
    local val=$2
    [ ! -f "$ENV_FILE" ] && touch "$ENV_FILE"
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$ENV_FILE"
    else
        echo "${key}=\"${val}\"" >> "$ENV_FILE"
    fi
}

# ── Wipe previous install — clean slate ──────────────────────────────────────
echo "[Wipe] Removing previous Xray/monitoring install..."
for svc in xray prometheus grafana-server pushgateway blackbox-exporter node-exporter alertmanager bark-webhook tls-push-monitor nginx; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
rm -f /etc/systemd/system/prometheus.service
rm -f /etc/systemd/system/pushgateway.service
rm -f /etc/systemd/system/blackbox-exporter.service
rm -f /etc/systemd/system/node-exporter.service
rm -f /etc/systemd/system/alertmanager.service
rm -f /etc/systemd/system/tls-push-monitor.service
rm -f /etc/systemd/system/bark-webhook.service
rm -f /etc/systemd/system/xray.service.d/override.conf
rmdir /etc/systemd/system/xray.service.d 2>/dev/null || true

# Binaries
rm -f /usr/local/bin/xray
rm -f /usr/local/bin/prometheus /usr/local/bin/promtool
rm -f /usr/local/bin/pushgateway
rm -f /usr/local/bin/blackbox_exporter
rm -f /usr/local/bin/node_exporter
rm -f /usr/local/bin/alertmanager /usr/local/bin/amtool
rm -f /usr/local/bin/tls-push-monitor.sh
rm -f /usr/local/bin/bark-webhook.py

# Configs and Data
rm -rf /etc/prometheus/ /etc/alertmanager/ /var/lib/prometheus/
rm -rf /etc/grafana/ /var/lib/grafana/
rm -rf /usr/local/etc/xray/
rm -rf /usr/local/share/xray/
rm -rf /var/log/xray/
rm -f /etc/logrotate.d/xray
rm -f /etc/xray-monitor.env
rm -f /etc/nginx/sites-enabled/grafana-proxy
rm -f /etc/nginx/sites-available/grafana-proxy

if command -v ufw &>/dev/null; then
    ufw delete allow 443/tcp 2>/dev/null || true
    ufw delete allow 8443/tcp 2>/dev/null || true
fi

(crontab -l 2>/dev/null | grep -v "russia-v2ray-rules-dat" || true) | crontab -
systemctl daemon-reload
echo "[Wipe] Done."
# ─────────────────────────────────────────────────────────────────────────────

echo "Checking/Installing Dependencies (jq, curl, openssl)..."
apt update && apt install -y git curl openssl cron jq

# ── Inputs ────────────────────────────────────────────────────────────────────
echo "=========================================================="
echo "      VPN CONFIGURATION (LOADED FROM .env)                "
echo "=========================================================="

# SNIs
read -p "SNI 1 (Port 443) [current: $SNI_1]: " INPUT; SNI_1=${INPUT:-$SNI_1}; update_env SNI_1 "$SNI_1"
read -p "SNI 2 (Port 8443) [current: $SNI_2]: " INPUT; SNI_2=${INPUT:-$SNI_2}; update_env SNI_2 "$SNI_2"
read -p "SNI 3 (Port 9443) [current: $SNI_3]: " INPUT; SNI_3=${INPUT:-$SNI_3}; update_env SNI_3 "$SNI_3"
read -p "RU Local SNI (e.g., ya.ru) [current: $LOCAL_SNI]: " INPUT; LOCAL_SNI=${INPUT:-$LOCAL_SNI}; update_env LOCAL_SNI "$LOCAL_SNI"

# EU Node
echo "----------------------------------------------------------"
echo "EU Exit Node Details:"
read -p "EU VPS IP [current: $EU_IP]: " INPUT; EU_IP=${INPUT:-$EU_IP}; update_env EU_IP "$EU_IP"
read -p "EU UUID [current: $EU_UUID]: " INPUT; EU_UUID=${INPUT:-$EU_UUID}; update_env EU_UUID "$EU_UUID"
read -p "EU Public Key [current: $EU_PUBKEY]: " INPUT; EU_PUBKEY=${INPUT:-$EU_PUBKEY}; update_env EU_PUBKEY "$EU_PUBKEY"
read -p "EU Short ID [current: $EU_SHORTID]: " INPUT; EU_SHORTID=${INPUT:-$EU_SHORTID}; update_env EU_SHORTID "$EU_SHORTID"

# Monitoring
echo "----------------------------------------------------------"
echo "Monitoring Setup:"
read -p "BARK_KEY (blank to skip) [current: $BARK_KEY]: " INPUT; BARK_KEY=${INPUT:-$BARK_KEY}; update_env BARK_KEY "$BARK_KEY"
read -p "Monitoring Domain [current: $MONITORING_DOMAIN]: " INPUT; MONITORING_DOMAIN=${INPUT:-$MONITORING_DOMAIN}; update_env MONITORING_DOMAIN "$MONITORING_DOMAIN"
echo "=========================================================="

# Static Ports (ensure they are in ENV)
[ -z "$PORT_1" ] && PORT_1=443 && update_env PORT_1 443
[ -z "$PORT_2" ] && PORT_2=8443 && update_env PORT_2 8443
[ -z "$PORT_3" ] && PORT_3=9443 && update_env PORT_3 9443

echo "1. Installing Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "2. Generating RU Inbound Credentials (VLESS+Reality+Vision)..."
RU_UUID=$(xray uuid)
RU_KEYS=$(xray x25519)
RU_PRIV=$(echo "$RU_KEYS" | awk '/Private/ {print $NF}')
RU_PUB=$(echo "$RU_KEYS" | awk '/Public/ {print $NF}')

# Robust Fallback
if [ -z "$RU_PRIV" ]; then
    RU_PRIV=$(echo "$RU_KEYS" | head -n 1 | awk '{print $NF}')
    RU_PUB=$(echo "$RU_KEYS"  | tail -n 1 | awk '{print $NF}')
fi

# Validation
if [ -z "$RU_PRIV" ] || [ -z "$RU_PUB" ]; then
    echo "[FAIL] Could not extract RU keys."
    exit 1
fi

RU_SHORTID=$(openssl rand -hex 4)
IP=$(curl -4 -s https://ifconfig.me)

echo "3. Creating Xray Bridge Configuration..."
mkdir -p /var/log/xray
chown -R nobody:nogroup /var/log/xray

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
  "dns": {
    "servers": [
      "77.88.8.8",
      "77.88.8.1"
    ]
  },
  "inbounds": [
    {
      "tag": "vless-vision-in",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$RU_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${LOCAL_SNI}:443",
          "xver": 0,
          "serverNames": ["$LOCAL_SNI"],
          "privateKey": "$RU_PRIV",
          "shortIds": ["$RU_SHORTID"]
        }
      }
    },
    {
      "tag": "vless-xhttp-in",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$RU_UUID"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${LOCAL_SNI}:443",
          "xver": 0,
          "serverNames": ["$LOCAL_SNI"],
          "privateKey": "$RU_PRIV",
          "shortIds": ["$RU_SHORTID"]
        },
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "/unicorn-magic"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "eu-sni-1",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$EU_IP",
          "port": $PORT_1,
          "users": [{
            "id": "$EU_UUID",
            "encryption": "none"
          }]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "$SNI_1",
          "publicKey": "$EU_PUBKEY",
          "shortId": "$EU_SHORTID"
        },
        "xhttpSettings": {
          "mode": "stream-one",
          "path": "/unicorn-magic",
          "xPaddingBytes": "100-1000",
          "xmux": {
            "maxConcurrency": "8-16",
            "cMaxReuseTimes": "64-128",
            "hMaxRequestTimes": "600-900"
          }
        }
      }
    },
    {
      "tag": "eu-sni-2",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$EU_IP",
          "port": $PORT_2,
          "users": [{
            "id": "$EU_UUID",
            "encryption": "none"
          }]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "$SNI_2",
          "publicKey": "$EU_PUBKEY",
          "shortId": "$EU_SHORTID"
        },
        "xhttpSettings": {
          "mode": "stream-one",
          "path": "/unicorn-magic",
          "xPaddingBytes": "100-1000",
          "xmux": {
            "maxConcurrency": "8-16",
            "cMaxReuseTimes": "64-128",
            "hMaxRequestTimes": "600-900"
          }
        }
      }
    },
    {
      "tag": "eu-sni-3",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$EU_IP",
          "port": $PORT_3,
          "users": [{
            "id": "$EU_UUID",
            "encryption": "none"
          }]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "chrome",
          "serverName": "$SNI_3",
          "publicKey": "$EU_PUBKEY",
          "shortId": "$EU_SHORTID"
        },
        "xhttpSettings": {
          "mode": "stream-one",
          "path": "/unicorn-magic",
          "xPaddingBytes": "100-1000",
          "xmux": {
            "maxConcurrency": "8-16",
            "cMaxReuseTimes": "64-128",
            "hMaxRequestTimes": "600-900"
          }
        }
      }
    },
    {
      "tag": "direct-ru",
      "protocol": "freedom"
    },
    {
      "tag": "block-ru",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "block-ru", "domain": ["geosite:category-ru", "geosite:ru-available-only-inside"] },
      { "type": "field", "outboundTag": "block-ru", "ip": ["geoip:ru"] },
      { "type": "field", "outboundTag": "direct-ru", "ip": ["geoip:private"] },
      { "type": "field", "balancerTag": "eu-balancer", "network": "tcp,udp" }
    ],
    "balancers": [{ "tag": "eu-balancer", "selector": ["eu-sni"], "strategy": { "type": "leastPing" } }]
  },
  "burstObservatory": {
    "subjectSelector": ["eu-sni"],
    "pingConfig": { "destination": "http://captive.apple.com/hotspot-detect.html", "interval": "5m" }
  }
}
XRAY_EOF

# Apply correct config settings
echo "3.1. Modifying Configuration..."
mkdir -p /etc/systemd/system/xray.service.d/ && printf '[Service]\nRestart=always\nRestartSec=5\nRestartPreventExitStatus=\n' | tee /etc/systemd/system/xray.service.d/override.conf > /dev/null && systemctl daemon-reload

echo "3.2. Downloading Runet routing databases & configuring auto-updates..."
mkdir -p /usr/local/share/xray
curl -sL -o /usr/local/share/xray/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat
curl -sL -o /usr/local/share/xray/geoip.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat

CRON_JOB="0 3 * * 0 curl -sL -o /usr/local/share/xray/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat && curl -sL -o /usr/local/share/xray/geoip.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat && systemctl restart xray"
(crontab -l 2>/dev/null | grep -v "russia-v2ray-rules-dat" || true; echo "$CRON_JOB") | crontab -

echo "3.3. Testing Xray Configuration..."
if ! xray -test -c /usr/local/etc/xray/config.json; then
    echo "[FAIL] Configuration error! Aborting restart."
    exit 1
fi

echo "4. Restarting Xray..."
chown -R nobody:nogroup /var/log/xray
systemctl enable xray
systemctl restart xray
sleep 3
if systemctl is-active --quiet xray; then
    echo "[PASS] Xray is running correctly!"
else
    echo "[FAIL] Xray failed to start!"
    journalctl -u xray --no-pager -n 15
    exit 1
fi

# Share Links for RU Bridge
PUB_URLSAFE=$(echo "$RU_PUB" | tr '+/' '-_' | tr -d '=')
LINK_TCP="vless://$RU_UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${LOCAL_SNI}&fp=chrome&pbk=$PUB_URLSAFE&sid=$RU_SHORTID&type=tcp&headerType=none#RU-Reality-TCP"
LINK_XHTTP="vless://$RU_UUID@$IP:8443?encryption=none&security=reality&sni=${LOCAL_SNI}&fp=chrome&pbk=$PUB_URLSAFE&sid=$RU_SHORTID&type=xhttp&mode=packet-up&path=%2Funicorn-magic#RU-Reality-xHTTP"

# Save links
mkdir -p /usr/local/etc/xray
LINKS_FILE="/usr/local/etc/xray/user_links.txt"
{
  echo "$(date -Iseconds) - RU Reality TCP (443): $LINK_TCP"
  echo "$(date -Iseconds) - RU Reality xHTTP (8443): $LINK_XHTTP"
} > "$LINKS_FILE"

echo "=========================================================="
echo "                   RU SETUP COMPLETE                      "
echo "=========================================================="
echo "1. VLESS Reality TCP (Vision):"
echo -e "\e[32m$LINK_TCP\e[0m"
echo ""
echo "2. VLESS Reality xHTTP (Packet-up):"
echo -e "\e[32m$LINK_XHTTP\e[0m"
echo ""
echo "✅ Links saved to: $LINKS_FILE"
echo "=========================================================="

echo "5. Installing monitoring stack (Prometheus + Grafana + Alertmanager)..."
BARK_KEY="$BARK_KEY" \
EU_IP="$EU_IP" \
MONITORING_DOMAIN="$MONITORING_DOMAIN" \
bash "$(dirname "$0")/setup-monitoring.sh"
