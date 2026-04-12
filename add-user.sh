#!/bin/bash
# Adds a new user to the RU Bridge Xray config and generates a share link.

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run with sudo or as root."
    echo "Usage: sudo bash $0 <username>"
    exit 1
fi

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <username>"
    echo "Example: $0 Alice"
    exit 1
fi

USERNAME=$1
CONFIG_FILE="/usr/local/etc/xray/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[FAIL] Xray config not found at $CONFIG_FILE. Are you running this on the RU Bridge VPS?"
    exit 1
fi

echo "1. Generating new UUID for $USERNAME..."
NEW_UUID=$(xray uuid)

echo "2. Adding user to config.json..."
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
if ! jq --arg uuid "$NEW_UUID" --arg email "$USERNAME" '
  (.inbounds[] | select(.tag == "vless-vision-in").settings.clients) += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}] |
  (.inbounds[] | select(.tag == "vless-xhttp-in").settings.clients) += [{"id": $uuid, "email": $email}]
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
    echo "[FAIL] Failed to modify config.json!"
    rm -f "${CONFIG_FILE}.tmp"
    exit 1
fi
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

echo "3. Testing Xray configuration..."
if ! xray -test -c "$CONFIG_FILE"; then
    echo "[FAIL] Configuration error after adding user! Rolling back."
    mv "${CONFIG_FILE}.bak" "$CONFIG_FILE" 2>/dev/null
    exit 1
fi

echo "4. Restarting Xray to apply changes..."
systemctl restart xray

echo "5. Reconstructing VLESS Links..."
# Extract values from the current config
IP=$(curl -4 -s https://ifconfig.me)
TCP_PORT=$(jq -r '.inbounds[] | select(.tag == "vless-vision-in").port' "$CONFIG_FILE")
XHTTP_PORT=$(jq -r '.inbounds[] | select(.tag == "vless-xhttp-in").port' "$CONFIG_FILE")
SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$CONFIG_FILE")
PRIV_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$CONFIG_FILE")
SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$CONFIG_FILE")

# Derive public key from the private key
KEYS_OUT=$(xray x25519 -i "$PRIV_KEY")
PUB_KEY=$(echo "$KEYS_OUT" | awk '/Public/ {print $NF}')

if [ -z "$PUB_KEY" ]; then
    PUB_KEY=$(echo "$KEYS_OUT" | tail -n 1 | awk '{print $NF}')
fi

# Convert Public Key to URL safe base64
PUB_URLSAFE=$(echo "$PUB_KEY" | tr '+/' '-_' | tr -d '=')

LINK_TCP="vless://$NEW_UUID@$IP:$TCP_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB_URLSAFE&sid=$SHORT_ID&type=tcp&headerType=none#RU-Bridge-${USERNAME}-TCP"
LINK_XHTTP="vless://$NEW_UUID@$IP:$XHTTP_PORT?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUB_URLSAFE&sid=$SHORT_ID&type=xhttp&mode=packet-up&path=%2Funicorn-magic#RU-Bridge-${USERNAME}-xHTTP"

echo ""
echo "=========================================================="
echo "               ✅ USER ADDED: $USERNAME                   "
echo "=========================================================="
echo "Send these exact links to $USERNAME to import into their app:"
echo ""
echo "1. VLESS Reality TCP (Vision):"
echo -e "\e[32m$LINK_TCP\e[0m"
echo ""
echo "2. VLESS Reality xHTTP (Packet-up):"
echo -e "\e[32m$LINK_XHTTP\e[0m"
echo "=========================================================="

# Save the links to a permanent file for future reference
mkdir -p /usr/local/etc/xray
LINKS_FILE="/usr/local/etc/xray/user_links.txt"
{
  echo "$(date -Iseconds) - $USERNAME (TCP): $LINK_TCP"
  echo "$(date -Iseconds) - $USERNAME (xHTTP): $LINK_XHTTP"
} >> "$LINKS_FILE"
echo "✅ Links successfully saved to: $LINKS_FILE"
