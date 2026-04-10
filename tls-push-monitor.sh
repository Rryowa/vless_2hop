#!/bin/bash
# tls-push-monitor — TLS handshake telemetry pushed to Prometheus Pushgateway.
#
# Runs as a systemd service with a 30-second sleep loop between runs.
# Mode is determined by TLS_MODE in /etc/xray-monitor.env:
#   - TLS_MODE=baseline → EU node mode: tests real mirror servers on port 443
#   - TLS_MODE=dpi      → RU node mode: tests EU proxy ports with --resolve
#
# Env file variables (/etc/xray-monitor.env):
#   TLS_TARGETS          — comma-separated host:port pairs
#   TLS_RESOLVE_TO       — EU VPS IP (only set in DPI mode; empty in baseline)
#   TLS_MODE             — "baseline" or "dpi"
#   TLS_PUSHGATEWAY_URL  — base URL of Pushgateway, e.g. http://127.0.0.1:9091

ENV_FILE="/etc/xray-monitor.env"

if [ ! -f "$ENV_FILE" ]; then
    exit 0
fi

source "$ENV_FILE"

if [ -z "$TLS_TARGETS" ] || [ -z "$TLS_PUSHGATEWAY_URL" ] || [ -z "$TLS_MODE" ]; then
    exit 0
fi

INSTANCE=$(hostname -f 2>/dev/null)
[ -z "$INSTANCE" ] && INSTANCE=$(hostname -s 2>/dev/null)
[ -z "$INSTANCE" ] && INSTANCE="unknown"

while true; do
    IFS=',' read -ra TARGET_LIST <<< "$TLS_TARGETS"

    for TARGET in "${TARGET_LIST[@]}"; do
        HOSTNAME="${TARGET%%:*}"
        PORT="${TARGET##*:}"

        SNI_LABEL="${HOSTNAME}"
        MODE="${TLS_MODE}"
        PUSH_URL="${TLS_PUSHGATEWAY_URL}/metrics/job/tls_probes/instance/${INSTANCE}/sni/${SNI_LABEL}/mode/${MODE}"

        if [ -n "$TLS_RESOLVE_TO" ]; then
            RESULT=$(curl --resolve "${HOSTNAME}:${PORT}:${TLS_RESOLVE_TO}" \
                --head -o /dev/null -w "%{time_appconnect}" \
                -s --connect-timeout 4 --max-time 5 \
                "https://${HOSTNAME}:${PORT}" 2>&1)
        else
            RESULT=$(curl --head -o /dev/null -w "%{time_appconnect}" \
                -s --connect-timeout 2 --max-time 3 \
                "https://${HOSTNAME}:${PORT}" 2>&1)
        fi

        if echo "$RESULT" | grep -qE '^[0-9]+\.?[0-9]*$'; then
            MS=$(echo "$RESULT" | awk '{printf "%.0f", $1 * 1000}')
            if [ "$MS" -gt 0 ] 2>/dev/null; then
                curl -s -H "Content-Type: text/plain; version=0.0.4; charset=utf-8" --data-binary @- "${PUSH_URL}" << EOF
# TYPE tls_probe_success gauge
tls_probe_success 1
# TYPE tls_probe_latency_ms gauge
tls_probe_latency_ms ${MS}
EOF
                continue
            fi
        fi

        curl -s -H "Content-Type: text/plain; version=0.0.4; charset=utf-8" --data-binary @- "${PUSH_URL}" << EOF
# TYPE tls_probe_success gauge
tls_probe_success 0
# TYPE tls_probe_latency_ms gauge
tls_probe_latency_ms 0
EOF
    done

    sleep 30
done
