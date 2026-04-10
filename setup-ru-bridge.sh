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

SNI_1="debian.snt.utwente.nl"
SNI_2="nl.archive.ubuntu.com"
SNI_3="eclipse.mirror.liteserver.nl"
LOCAL_SNI="vkvideo.ru"
PORT_1=443
PORT_2=8443
PORT_3=9443

# ── Wipe previous install — clean slate ──────────────────────────────────────
echo "[Wipe] Removing previous Xray/Kuma/monitoring install..."
systemctl stop xray uptime-kuma log-capture-webhook tls-push-monitor nginx 2>/dev/null || true
systemctl disable xray uptime-kuma log-capture-webhook tls-push-monitor nginx 2>/dev/null || true
rm -f /etc/systemd/system/uptime-kuma.service
rm -f /etc/systemd/system/log-capture-webhook.service
rm -f /etc/systemd/system/tls-push-monitor.service
rm -f /etc/systemd/system/xray.service.d/override.conf
rmdir /etc/systemd/system/xray.service.d 2>/dev/null || true
rm -f /usr/local/etc/xray/config.json
rm -f /usr/local/etc/xray/user_links.txt
rm -f /etc/logrotate.d/xray
rm -f /usr/local/bin/tls-push-monitor.sh
rm -f /etc/xray-kuma.env
rm -f /opt/log-capture-webhook.py
rm -rf /opt/uptime-kuma
rm -f /etc/nginx/sites-enabled/kuma-proxy
rm -f /etc/nginx/sites-available/kuma-proxy
rm -rf /var/log/xray
(crontab -l 2>/dev/null | grep -v "russia-v2ray-rules-dat\|xray/incidents" || true) | crontab -
systemctl daemon-reload
echo "[Wipe] Done."
# ─────────────────────────────────────────────────────────────────────────────

echo "Checking/Installing Dependencies (jq, curl, openssl)..."
apt update && apt install -y git curl openssl cron jq

# User input prompts
echo "=========================================================="
echo "      INPUT EU EXIT NODE DETAILS (FROM EU SCRIPT)         "
echo "=========================================================="
echo "EU SNI targets (must match EU node):"
echo "  :${PORT_1} → ${SNI_1}"
echo "  :${PORT_2} → ${SNI_2}"
echo "  :${PORT_3} → ${SNI_3}"
echo "=========================================================="
read -p "Enter EU VPS IP: " EU_IP
read -p "Enter EU UUID: " EU_UUID
read -p "Enter EU Public Key: " EU_PUBKEY
read -p "Enter EU Short ID: " EU_SHORTID
echo "=========================================================="
echo "      MONITORING SETUP                                    "
echo "=========================================================="
read -p "Enter BARK_KEY (leave blank to skip notifications): " BARK_KEY
read -p "Enter Kuma dashboard domain (e.g., rryo.mooo.com): " KUMA_DOMAIN
echo "=========================================================="

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
mkdir -p /etc/systemd/system/xray.service.d/ && printf '[Service]\nRestart=always\nRestartSec=5\n' | tee /etc/systemd/system/xray.service.d/override.conf > /dev/null && systemctl daemon-reload

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
systemctl restart xray
sleep 2
echo "[PASS] Xray is running correctly!"

# Share Link for RU Bridge (VLESS Reality Vision TCP)
PUB_URLSAFE=$(echo "$RU_PUB" | tr '+/' '-_' | tr -d '=')
SHARE_LINK="vless://$RU_UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${LOCAL_SNI}&fp=chrome&pbk=$PUB_URLSAFE&sid=$RU_SHORTID&type=tcp&headerType=none#RU-BRIDGE-PRIMARY"

# Save the initial admin link to a permanent file for future reference
mkdir -p /usr/local/etc/xray
LINKS_FILE="/usr/local/etc/xray/user_links.txt"
echo "$(date -Iseconds) - Admin (Primary): $SHARE_LINK" > "$LINKS_FILE"

echo "=========================================================="
echo "                   RU SETUP COMPLETE                      "
echo "=========================================================="
echo "SHARABLE VLESS LINK (RU PRIMARY):"
echo -e "\e[32m$SHARE_LINK\e[0m"
echo "✅ Link successfully saved to: $LINKS_FILE"
echo "=========================================================="

echo "5. Installing Uptime Kuma monitoring (full Kuma host)..."
BARK_KEY="$BARK_KEY" \
PEER_IP="$EU_IP" \
PEER_SNI="$SNI_1" \
LOCAL_SNI="$LOCAL_SNI" \
EU_SNIS="${SNI_1}:443,${SNI_2}:443,${SNI_3}:443" \
RU_SNIS="${SNI_1}:${PORT_1},${SNI_2}:${PORT_2},${SNI_3}:${PORT_3}" \
KUMA_DOMAIN="$KUMA_DOMAIN" \
bash "$(dirname "$0")/install-uptime-kuma.sh" --kuma-host
