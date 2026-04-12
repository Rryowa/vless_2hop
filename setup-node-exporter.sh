#!/bin/bash
# Node Exporter Setup: Prometheus metrics endpoint on port 9100
# Run on EU VPS. Installs node_exporter and restricts access to RU bridge IP.

set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

# --- Load Environment Variables ---
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
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

if [ -z "$RU_IP" ]; then
    read -p "Enter RU Bridge VPS IP (for UFW allowlist) [current: $RU_IP]: " INPUT
    RU_IP=${INPUT:-$RU_IP}
    [ -n "$RU_IP" ] && update_env RU_IP "$RU_IP"
fi

# ── Wipe previous install — clean slate ──────────────────────────────────────
echo "[wipe] Removing any previous node_exporter install..."
systemctl stop node-exporter 2>/dev/null || true
systemctl disable node-exporter 2>/dev/null || true
rm -f /etc/systemd/system/node-exporter.service
rm -f /usr/local/bin/node_exporter
systemctl daemon-reload
# ─────────────────────────────────────────────────────────────────────────────

echo "[1/5] Resolving latest Node Exporter version..."
NE_VERSION=$(curl -sI https://github.com/prometheus/node_exporter/releases/latest | grep -i location | grep -oP 'v[\d.]+' | head -1)
if [ -z "$NE_VERSION" ]; then
    echo "ERROR: Could not determine latest Node Exporter version."
    exit 1
fi
echo "       Version: ${NE_VERSION}"

echo "[2/5] Downloading Node Exporter ${NE_VERSION}..."
curl -sL "https://github.com/prometheus/node_exporter/releases/download/${NE_VERSION}/node_exporter-${NE_VERSION#v}.linux-amd64.tar.gz" \
    -o /tmp/node_exporter.tar.gz
tar -xzf /tmp/node_exporter.tar.gz -C /tmp/
cp /tmp/node_exporter-${NE_VERSION#v}.linux-amd64/node_exporter /usr/local/bin/
chmod +x /usr/local/bin/node_exporter
rm -rf /tmp/node_exporter*

echo "[3/5] Installing systemd service..."
cat > /etc/systemd/system/node-exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:9100
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node-exporter

echo "[4/5] Starting node-exporter service..."
systemctl start node-exporter

echo "[5/5] Configuring firewall..."
if command -v ufw &>/dev/null; then
    if [ -n "$RU_IP" ]; then
        if ! ufw status | grep -q "9100.*${RU_IP}"; then
            ufw allow from "${RU_IP}" to any port 9100 proto tcp
        fi
        echo "       UFW: allowed port 9100 from ${RU_IP} only"
    else
        echo "       WARNING: No RU_IP provided — port 9100 not opened in UFW."
        echo "                Add a rule manually: ufw allow from <RU_IP> to any port 9100 proto tcp"
    fi
else
    echo "       UFW not found — opening port 9100 via iptables fallback..."
        iptables -I INPUT -p tcp --dport 9100 -j ACCEPT 2>/dev/null || echo "[WARNING] iptables rule failed — open port 9100 manually."
fi

echo "[check] Waiting for node-exporter to come up..."
for i in $(seq 1 10); do
    if curl -s http://127.0.0.1:9100/metrics &>/dev/null; then
        echo "        Service is responding."
        break
    fi
    if [ "$i" -eq 10 ]; then
        echo "ERROR: node-exporter did not respond after 10 attempts."
        systemctl status node-exporter --no-pager
        exit 1
    fi
    sleep 1
done

echo "----------------------------------------------------------"
echo "NODE EXPORTER SETUP COMPLETE"
echo "Listening on: http://$(hostname -I | awk '{print $1}'):9100/metrics"
if [ -n "$RU_IP" ]; then
    echo "Access allowed from: ${RU_IP}"
fi
echo "Service status: $(systemctl is-active node-exporter)"
echo "----------------------------------------------------------"
