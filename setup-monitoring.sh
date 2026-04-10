#!/bin/bash
# Installs the full Prometheus monitoring stack on the RU VPS.
#
# Installs: Prometheus, Grafana OSS, Pushgateway, Blackbox Exporter,
#           Node Exporter, Alertmanager, Bark webhook bridge,
#           nginx HTTPS reverse proxy (Let's Encrypt), tls-push-monitor (DPI mode)
#
# Environment variables (set by caller or prompted interactively):
#   EU_IP        - IP of the EU exit VPS
#   KUMA_DOMAIN  - Domain for Grafana dashboard (Let's Encrypt cert)
#   BARK_KEY     - Bark device key for push notifications (optional)

set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo or as root."
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Inputs ────────────────────────────────────────────────────────────────────
[ -z "$EU_IP" ]       && read -rp "Enter EU VPS IP: " EU_IP
[ -z "$KUMA_DOMAIN" ] && read -rp "Enter monitoring domain (e.g., rryo.mooo.com): " KUMA_DOMAIN
[ -z "$BARK_KEY" ]    && read -rp "Enter BARK_KEY (leave blank to skip notifications): " BARK_KEY

if [ -z "$EU_IP" ]; then
    echo "ERROR: EU_IP is required."
    exit 1
fi
if [ -z "$KUMA_DOMAIN" ]; then
    echo "ERROR: KUMA_DOMAIN is required."
    exit 1
fi

# ── Wipe previous install — clean slate ──────────────────────────────────────
echo "[Wipe] Removing previous monitoring stack install..."
for svc in prometheus grafana-server pushgateway blackbox-exporter node-exporter alertmanager tls-push-monitor bark-webhook nginx; do
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
rm -f /usr/local/bin/prometheus /usr/local/bin/promtool
rm -f /usr/local/bin/pushgateway
rm -f /usr/local/bin/blackbox_exporter
rm -f /usr/local/bin/alertmanager /usr/local/bin/amtool
rm -f /usr/local/bin/node_exporter
rm -f /usr/local/bin/bark-webhook.py
rm -f /usr/local/bin/tls-push-monitor.sh
rm -rf /etc/prometheus/
rm -rf /etc/alertmanager/
rm -rf /var/lib/grafana/
rm -rf /etc/grafana/dashboards/
rm -rf /var/lib/prometheus/

if command -v ufw &>/dev/null; then
    ufw delete allow 3000/tcp 2>/dev/null || true
    ufw delete deny 9091/tcp 2>/dev/null || true
    # Also attempt to delete any rules that mention 9091 from sources
    for rule in $(ufw status numbered | grep '9091' | awk -F"[][]" '{print $2}' | sort -rn 2>/dev/null || true); do
        echo "y" | ufw delete $rule 2>/dev/null || true
    done
fi
rm -f /etc/xray-monitor.env
rm -f /etc/nginx/sites-enabled/grafana-proxy
rm -f /etc/nginx/sites-available/grafana-proxy
systemctl daemon-reload
apt remove -y grafana 2>/dev/null || true
echo "[Wipe] Done."
# ─────────────────────────────────────────────────────────────────────────────

# ── Helper: download latest GitHub release binary ────────────────────────────
github_latest_version() {
    # Usage: github_latest_version owner/repo
    curl -sI "https://github.com/$1/releases/latest" \
        | grep -i location \
        | grep -oP 'v[\d.]+' \
        | head -1
}

# ── Step 1: Dependencies ─────────────────────────────────────────────────────
echo "[1/12] Installing system dependencies..."
apt update && apt install -y curl wget git nginx certbot python3-certbot-nginx python3

# ── Step 2: Install Prometheus ───────────────────────────────────────────────
echo "[2/12] Installing Prometheus..."
PROM_VERSION=$(github_latest_version prometheus/prometheus)
if [ -z "$PROM_VERSION" ]; then
    echo "ERROR: Could not determine latest Prometheus version."
    exit 1
fi
echo "       Version: ${PROM_VERSION}"

curl -sL "https://github.com/prometheus/prometheus/releases/download/${PROM_VERSION}/prometheus-${PROM_VERSION#v}.linux-amd64.tar.gz" \
    | tar -xz -C /tmp/
cp "/tmp/prometheus-${PROM_VERSION#v}.linux-amd64/prometheus" /usr/local/bin/prometheus
cp "/tmp/prometheus-${PROM_VERSION#v}.linux-amd64/promtool"   /usr/local/bin/promtool
chmod +x /usr/local/bin/prometheus /usr/local/bin/promtool
rm -rf /tmp/prometheus*

# Create system user
id prometheus &>/dev/null || useradd --no-create-home --shell /bin/false prometheus

# Create dirs and copy config
mkdir -p /etc/prometheus /var/lib/prometheus
sed -e "s/<EU_IP>/${EU_IP}/g" -e "s/<KUMA_DOMAIN>/${KUMA_DOMAIN}/g" "$REPO_DIR/prometheus.yml" > /etc/prometheus/prometheus.yml
cp "$REPO_DIR/prometheus-alerts.yml" /etc/prometheus/prometheus-alerts.yml

# Blackbox config (written now, used by step 5)
cat > /etc/prometheus/blackbox.yml << 'BLACKBOXEOF'
modules:
  tcp_connect:
    prober: tcp
    timeout: 5s
  http_2xx:
    prober: http
    http:
      preferred_ip_protocol: "ip4"
BLACKBOXEOF

chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus/ \
    --storage.tsdb.retention.time=30d \
    --web.listen-address=127.0.0.1:9090
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prometheus
echo "[2/12] Prometheus installed and started."

# ── Step 3: Install Grafana OSS ──────────────────────────────────────────────
echo "[3/12] Installing Grafana OSS..."
echo "deb [trusted=yes] https://mirror.yandex.ru/mirrors/packages.grafana.com/oss/deb stable main" \
    > /etc/apt/sources.list.d/grafana.list
apt update && apt install -y grafana

# Bind to localhost on port 13000 (nginx will proxy 3000 -> 13000)
sed -i 's/^;http_addr =.*/http_addr = 127.0.0.1/' /etc/grafana/grafana.ini
sed -i 's/^http_addr =.*/http_addr = 127.0.0.1/'  /etc/grafana/grafana.ini
sed -i 's/^;http_port =.*/http_port = 13000/'      /etc/grafana/grafana.ini
sed -i 's/^http_port =.*/http_port = 13000/'        /etc/grafana/grafana.ini

# Provisioning
mkdir -p /etc/grafana/provisioning/datasources \
         /etc/grafana/provisioning/dashboards \
         /etc/grafana/dashboards
cp "$REPO_DIR/grafana-provisioning/datasource.yml"  /etc/grafana/provisioning/datasources/
cp "$REPO_DIR/grafana-provisioning/dashboard.yml"   /etc/grafana/provisioning/dashboards/
cp "$REPO_DIR/grafana-dashboard.json"               /etc/grafana/dashboards/
chown -R grafana:grafana /etc/grafana/provisioning /etc/grafana/dashboards

systemctl enable --now grafana-server
echo "[3/12] Grafana installed and started on 127.0.0.1:13000."

# ── Step 4: Install Pushgateway ──────────────────────────────────────────────
echo "[4/12] Installing Pushgateway..."
PGW_VERSION=$(github_latest_version prometheus/pushgateway)
if [ -z "$PGW_VERSION" ]; then
    echo "ERROR: Could not determine latest Pushgateway version."
    exit 1
fi
echo "       Version: ${PGW_VERSION}"

curl -sL "https://github.com/prometheus/pushgateway/releases/download/${PGW_VERSION}/pushgateway-${PGW_VERSION#v}.linux-amd64.tar.gz" \
    | tar -xz -C /tmp/
cp "/tmp/pushgateway-${PGW_VERSION#v}.linux-amd64/pushgateway" /usr/local/bin/pushgateway
chmod +x /usr/local/bin/pushgateway
rm -rf /tmp/pushgateway*

cat > /etc/systemd/system/pushgateway.service << 'EOF'
[Unit]
Description=Prometheus Pushgateway
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/pushgateway \
    --web.listen-address=0.0.0.0:9091
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pushgateway
echo "[4/12] Pushgateway installed (0.0.0.0:9091)."

# ── Step 5: Install Blackbox Exporter ────────────────────────────────────────
echo "[5/12] Installing Blackbox Exporter..."
BB_VERSION=$(github_latest_version prometheus/blackbox_exporter)
if [ -z "$BB_VERSION" ]; then
    echo "ERROR: Could not determine latest Blackbox Exporter version."
    exit 1
fi
echo "       Version: ${BB_VERSION}"

curl -sL "https://github.com/prometheus/blackbox_exporter/releases/download/${BB_VERSION}/blackbox_exporter-${BB_VERSION#v}.linux-amd64.tar.gz" \
    | tar -xz -C /tmp/
cp "/tmp/blackbox_exporter-${BB_VERSION#v}.linux-amd64/blackbox_exporter" /usr/local/bin/blackbox_exporter
chmod +x /usr/local/bin/blackbox_exporter
rm -rf /tmp/blackbox_exporter*

cat > /etc/systemd/system/blackbox-exporter.service << 'EOF'
[Unit]
Description=Prometheus Blackbox Exporter
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/blackbox_exporter \
    --config.file=/etc/prometheus/blackbox.yml \
    --web.listen-address=127.0.0.1:9115
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now blackbox-exporter
echo "[5/12] Blackbox Exporter installed (127.0.0.1:9115)."

# ── Step 6: Install Node Exporter (RU node itself) ───────────────────────────
echo "[6/12] Installing Node Exporter..."
NE_VERSION=$(github_latest_version prometheus/node_exporter)
if [ -z "$NE_VERSION" ]; then
    echo "ERROR: Could not determine latest Node Exporter version."
    exit 1
fi
echo "       Version: ${NE_VERSION}"

curl -sL "https://github.com/prometheus/node_exporter/releases/download/${NE_VERSION}/node_exporter-${NE_VERSION#v}.linux-amd64.tar.gz" \
    | tar -xz -C /tmp/
cp "/tmp/node_exporter-${NE_VERSION#v}.linux-amd64/node_exporter" /usr/local/bin/node_exporter
chmod +x /usr/local/bin/node_exporter
rm -rf /tmp/node_exporter*

cat > /etc/systemd/system/node-exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node-exporter
echo "[6/12] Node Exporter installed (127.0.0.1:9100)."

# ── Step 7: Install Alertmanager ─────────────────────────────────────────────
echo "[7/12] Installing Alertmanager..."
AM_VERSION=$(github_latest_version prometheus/alertmanager)
if [ -z "$AM_VERSION" ]; then
    echo "ERROR: Could not determine latest Alertmanager version."
    exit 1
fi
echo "       Version: ${AM_VERSION}"

curl -sL "https://github.com/prometheus/alertmanager/releases/download/${AM_VERSION}/alertmanager-${AM_VERSION#v}.linux-amd64.tar.gz" \
    | tar -xz -C /tmp/
cp "/tmp/alertmanager-${AM_VERSION#v}.linux-amd64/alertmanager" /usr/local/bin/alertmanager
cp "/tmp/alertmanager-${AM_VERSION#v}.linux-amd64/amtool"       /usr/local/bin/amtool
chmod +x /usr/local/bin/alertmanager /usr/local/bin/amtool
rm -rf /tmp/alertmanager*

mkdir -p /etc/alertmanager /var/lib/alertmanager
cp "$REPO_DIR/alertmanager.yml" /etc/alertmanager/alertmanager.yml
chown -R nobody:nogroup /var/lib/alertmanager

cat > /etc/systemd/system/alertmanager.service << 'EOF'
[Unit]
Description=Alertmanager
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/alertmanager \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/var/lib/alertmanager \
    --web.listen-address=127.0.0.1:9093
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now alertmanager
echo "[7/12] Alertmanager installed (127.0.0.1:9093)."

# ── Step 8: Install Bark webhook bridge ──────────────────────────────────────
echo "[8/12] Installing Bark webhook bridge..."
if [ -n "$BARK_KEY" ]; then
    cat > /usr/local/bin/bark-webhook.py << 'PYEOF'
#!/usr/bin/env python3
"""
Bark Webhook Bridge — listens on 127.0.0.1:9095 for Alertmanager webhook POSTs
and forwards each alert to the Bark push notification API.

Reads BARK_KEY from environment (set via EnvironmentFile=/etc/xray-monitor.env).
"""
import os
import sys
import json
import signal
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote

BARK_KEY = os.environ.get("BARK_KEY", "")
if not BARK_KEY:
    print("ERROR: BARK_KEY environment variable is not set or empty.", flush=True)
    sys.exit(1)


def send_bark(title: str, body: str) -> None:
    if not BARK_KEY:
        return
    encoded_title = quote(title, safe="")
    encoded_body  = quote(body,  safe="")
    url = f"https://api.day.app/{BARK_KEY}/{encoded_title}/{encoded_body}"
    subprocess.run(
        ["curl", "-s", "-o", "/dev/null", url],
        timeout=10,
    )


class WebhookHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # suppress default access log
        pass

    def do_POST(self):
        if self.path != "/bark":
            self.send_response(404)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        raw    = self.rfile.read(length)

        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        alerts = data.get("alerts", [])
        for alert in alerts:
            status      = alert.get("status", "firing")
            labels      = alert.get("labels", {})
            annotations = alert.get("annotations", {})

            alert_name = labels.get("alertname", "Unknown")
            summary    = annotations.get("summary", alert_name)
            description = annotations.get("description", summary)

            if status == "resolved":
                title = f"[RESOLVED] {summary}"
            else:
                title = f"[ALERT] {summary}"

            send_bark(title, description)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")


def shutdown(signum, frame):
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, shutdown)
    server = HTTPServer(("127.0.0.1", 9095), WebhookHandler)
    print(f"bark-webhook listening on 127.0.0.1:9095", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
PYEOF
    chmod +x /usr/local/bin/bark-webhook.py

    cat > /etc/systemd/system/bark-webhook.service << 'EOF'
[Unit]
Description=Bark Webhook Bridge for Alertmanager
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
EnvironmentFile=/etc/xray-monitor.env
ExecStart=/usr/bin/python3 /usr/local/bin/bark-webhook.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now bark-webhook
    echo "[8/12] Bark webhook bridge installed (127.0.0.1:9095)."
else
    echo "[8/12] BARK_KEY not set — skipping Bark webhook bridge."
fi

# ── Step 9: Let's Encrypt + Nginx HTTPS reverse proxy for Grafana ────────────
echo "[9/12] Obtaining Let's Encrypt certificate and configuring nginx..."

# Stop nginx so certbot standalone can bind port 80
systemctl stop nginx 2>/dev/null || true

if command -v ufw &>/dev/null; then
    ufw allow 80/tcp
    echo "       UFW: opened port 80 for ACME challenge"
fi

echo "       Requesting certificate for ${KUMA_DOMAIN}..."
certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "$KUMA_DOMAIN" \
    --pre-hook "ufw allow 80/tcp" --post-hook "ufw delete allow 80/tcp"

if command -v ufw &>/dev/null; then
    ufw delete allow 80/tcp 2>/dev/null || true
    echo "[Nginx] UFW port 80 closed (ACME done)"
fi

CERT_PATH="/etc/letsencrypt/live/${KUMA_DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${KUMA_DOMAIN}/privkey.pem"

# Grafana listens on 127.0.0.1:13000; nginx proxies public :3000 SSL -> 13000
cat > /etc/nginx/sites-available/grafana-proxy << EOF
server {
    listen 3000 ssl;
    server_name ${KUMA_DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass         http://127.0.0.1:13000;
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
ln -sf /etc/nginx/sites-available/grafana-proxy /etc/nginx/sites-enabled/grafana-proxy

nginx -t
systemctl enable nginx
systemctl reload-or-restart nginx

if command -v ufw &>/dev/null; then
    ufw delete allow 3000/tcp 2>/dev/null || true
    ufw allow 3000/tcp
    echo "       UFW: opened port 3000 (Grafana HTTPS dashboard)"
fi

systemctl enable certbot.timer 2>/dev/null || true
echo "[9/12] nginx HTTPS proxy active: ${KUMA_DOMAIN}:3000 -> 127.0.0.1:13000 (Grafana)"

# ── Step 10: UFW rules for monitoring ports ───────────────────────────────────
echo "[10/12] Configuring UFW firewall rules..."
if command -v ufw &>/dev/null; then
    if [ -n "$EU_IP" ]; then
        ufw delete allow from "$EU_IP" to any port 9091 proto tcp 2>/dev/null || true
        ufw allow from "$EU_IP" to any port 9091 proto tcp
        echo "       UFW: allowed port 9091 (Pushgateway) from ${EU_IP}"
    fi
    # Block all other inbound access to Pushgateway
    ufw delete deny 9091/tcp 2>/dev/null || true
    ufw deny 9091/tcp 2>/dev/null || true
    echo "       UFW: denied port 9091 from all other sources"
    # Ports 9090, 9093, 9095, 9100, 9115 all bind to 127.0.0.1 — no UFW needed
else
    echo "       UFW not found — skipping firewall rules (configure manually)"
fi
echo "[10/12] UFW rules applied."

# ── Step 11: Write env file for tls-push-monitor (DPI mode) ──────────────────
echo "[11/12] Writing tls-push-monitor env file (DPI mode)..."
cat > /etc/xray-monitor.env << EOF
TLS_TARGETS=debian.snt.utwente.nl:443,nl.archive.ubuntu.com:8443,eclipse.mirror.liteserver.nl:9443
TLS_RESOLVE_TO=${EU_IP}
TLS_MODE=dpi
TLS_PUSHGATEWAY_URL=http://127.0.0.1:9091
BARK_KEY=${BARK_KEY}
EOF
chmod 600 /etc/xray-monitor.env
echo "[11/12] Env file written to /etc/xray-monitor.env (mode 600)."

# ── Step 12: Install tls-push-monitor (DPI mode) ─────────────────────────────
echo "[12/12] Installing tls-push-monitor service (DPI mode)..."
cp "$REPO_DIR/tls-push-monitor.sh" /usr/local/bin/tls-push-monitor.sh
chmod +x /usr/local/bin/tls-push-monitor.sh
cp "$REPO_DIR/tls-push-monitor.service" /etc/systemd/system/tls-push-monitor.service
systemctl daemon-reload
systemctl enable --now tls-push-monitor
echo "[12/12] tls-push-monitor started (30s interval, DPI mode)."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=========================================================="
echo "         MONITORING STACK INSTALLED (RU NODE)            "
echo "=========================================================="
echo "Grafana dashboard: https://${KUMA_DOMAIN}:3000"
echo "Prometheus:        http://127.0.0.1:9090 (local only)"
echo "Pushgateway:       http://0.0.0.0:9091 (EU IP whitelisted)"
echo "Alertmanager:      http://127.0.0.1:9093 (local only)"
echo ""
echo "tls-push-monitor:  running in DPI mode"
echo "Bark alerts:       $([ -n "$BARK_KEY" ] && echo "enabled" || echo "disabled — no BARK_KEY")"
echo "=========================================================="
