#!/bin/bash
# tls-push-monitor — TLS handshake telemetry for Uptime Kuma push monitors.
#
# Runs as a systemd service with a 30-second sleep loop between runs.
# Mode is auto-detected from /etc/xray-kuma.env:
#   - TLS_RESOLVE_TO empty → Baseline mode (EU node): tests real mirror servers on port 443
#   - TLS_RESOLVE_TO set   → DPI probe mode (RU node): tests EU proxy ports with --resolve
#
# Env file variables:
#   TLS_TARGETS     — comma-separated host:port pairs
#   TLS_RESOLVE_TO  — EU VPS IP (empty = baseline mode)
#   TLS_PUSH_TOKENS — JSON map of host:port → push token
#   KUMA_PUSH_URL   — base URL for Kuma push API

ENV_FILE="/etc/xray-kuma.env"

if [ ! -f "$ENV_FILE" ]; then
    exit 0
fi

source "$ENV_FILE"

if [ -z "$TLS_TARGETS" ] || [ -z "$TLS_PUSH_TOKENS" ] || [ -z "$KUMA_PUSH_URL" ]; then
    exit 0
fi

TOKEN_LOOKUP=$(TLS_PUSH_TOKENS="$TLS_PUSH_TOKENS" python3 << 'PYEOF'
import json, os, sys
raw = os.environ.get("TLS_PUSH_TOKENS", "")
if not raw:
    sys.exit(0)
try:
    m = json.loads(raw)
except:
    sys.exit(0)
for target, token in m.items():
    print(f'{target}\t{token}')
PYEOF
)

if [ -z "$TOKEN_LOOKUP" ]; then
    exit 0
fi

declare -A TOKENS
while IFS=$'\t' read -r TARGET TOKEN; do
    TOKENS["$TARGET"]="$TOKEN"
done <<< "$TOKEN_LOOKUP"

IFS=',' read -ra TARGET_LIST <<< "$TLS_TARGETS"

for TARGET in "${TARGET_LIST[@]}"; do
    HOSTNAME="${TARGET%%:*}"
    PORT="${TARGET##*:}"

    TOKEN="${TOKENS[$TARGET]}"
    [ -z "$TOKEN" ] && continue

    if [ -n "$TLS_RESOLVE_TO" ]; then
        RESULT=$(curl --resolve "${HOSTNAME}:${PORT}:${TLS_RESOLVE_TO}" \
            --head -o /dev/null -w "%{time_appconnect}" \
            -s --connect-timeout 4 --max-time 5 \
            "https://${HOSTNAME}:${PORT}" 2>&1)
        FAIL_MSG="dpi_blocked"
    else
        RESULT=$(curl --head -o /dev/null -w "%{time_appconnect}" \
            -s --connect-timeout 2 --max-time 3 \
            "https://${HOSTNAME}" 2>&1)
        FAIL_MSG="mirror_offline"
    fi

    if echo "$RESULT" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        MS=$(echo "$RESULT" | awk '{printf "%.0f", $1 * 1000}')
        if [ "$MS" -gt 0 ] 2>/dev/null; then
            curl -sf "${KUMA_PUSH_URL}/api/push/${TOKEN}?status=up&ping=${MS}" > /dev/null 2>&1
            continue
        fi
    fi

    curl -sf "${KUMA_PUSH_URL}/api/push/${TOKEN}?status=down&msg=${FAIL_MSG}" > /dev/null 2>&1
done
