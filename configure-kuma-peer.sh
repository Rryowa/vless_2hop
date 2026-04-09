#!/bin/bash
# Adds EU peer TCP monitors (443/8443/9443/SSH) to an existing Uptime Kuma instance.
# Run on the RU node (Kuma host) if peer monitors were skipped during initial setup.
#
# Usage:
#   bash configure-kuma-peer.sh <EU_IP>

set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo or as root."
    echo "Usage: sudo bash $0 <EU_IP>"
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 <EU_IP>"
    exit 1
fi

EU_IP="$1"
SSH_PORT="${SSH_PORT:-48022}"
KUMA_URL="${KUMA_URL:-http://127.0.0.1:13001}"

echo "Adding EU peer TCP monitors for ${EU_IP}..."

if [ ! -f /etc/xray-kuma.env ]; then
    echo "[ERROR] /etc/xray-kuma.env not found. Has install-uptime-kuma.sh been run?"
    exit 1
fi

KUMA_PASS=$(grep '^KUMA_PASS=' /etc/xray-kuma.env | cut -d= -f2-)
if [ -z "$KUMA_PASS" ]; then
    echo "[ERROR] KUMA_PASS not found in /etc/xray-kuma.env. Re-run install-uptime-kuma.sh --kuma-host."
    exit 1
fi

KUMA_USER=$(grep '^KUMA_USER=' /etc/xray-kuma.env | cut -d= -f2-)
if [ -z "$KUMA_USER" ]; then
    echo "[WARNING] KUMA_USER not found in env, defaulting to 'admin'."
    KUMA_USER="admin"
fi

SSH_PORT="$SSH_PORT" EU_IP="$EU_IP" KUMA_URL="$KUMA_URL" KUMA_PASS="$KUMA_PASS" KUMA_USER="$KUMA_USER" python3 << 'PYEOF'
import os
from uptime_kuma_api import UptimeKumaApi, MonitorType

eu_ip = os.environ["EU_IP"]
ssh_port = int(os.environ.get("SSH_PORT", "48022"))
kuma_url = os.environ.get("KUMA_URL", "http://127.0.0.1:13001")
kuma_pass = os.environ["KUMA_PASS"]
kuma_user = os.environ.get("KUMA_USER", "admin")

api = UptimeKumaApi(kuma_url, wait_events=0.5)
with api:
    if api.need_setup():
        print("[ERROR] Kuma has no admin account yet. Run install-uptime-kuma.sh --kuma-host first.")
        api.disconnect()
        exit(1)
    api.login(kuma_user, kuma_pass)

    existing = {m["name"] for m in api.get_monitors()}

    monitors = [
        ("EU Xray :443", eu_ip, 443),
        ("EU Xray :8443", eu_ip, 8443),
        ("EU Xray :9443", eu_ip, 9443),
        (f"EU SSH :{ssh_port}", eu_ip, ssh_port),
    ]

    for name, host, port in monitors:
        if name not in existing:
            api.add_monitor(
                type=MonitorType.TCP,
                name=name,
                hostname=host,
                port=port,
                interval=60,
                maxretries=3,
            )
            print(f"Added: {name}")
        else:
            print(f"Already exists: {name}")

print("Done.")
PYEOF
