#!/bin/bash
# Revokes a user's access from the RU Bridge Xray config.

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

# Check if the user actually exists in the config
USER_EXISTS=$(jq --arg email "$USERNAME" '[.inbounds[0].settings.clients[] | select(.email == $email)] | length' "$CONFIG_FILE")

if [ "$USER_EXISTS" -eq 0 ]; then
    echo "[FAIL] User '$USERNAME' not found in the Xray configuration."
    exit 1
fi

echo "1. Removing $USERNAME from config.json..."
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
if ! jq --arg email "$USERNAME" '.inbounds[0].settings.clients |= map(select(.email != $email))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
    echo "[FAIL] Failed to modify config.json!"
    rm -f "${CONFIG_FILE}.tmp"
    exit 1
fi
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

echo "2. Testing Xray configuration..."
if ! xray -test -c "$CONFIG_FILE"; then
    echo "[FAIL] Configuration error after removing user! Rolling back."
    mv "${CONFIG_FILE}.bak" "$CONFIG_FILE" 2>/dev/null
    exit 1
fi

echo "3. Restarting Xray to terminate their active sessions immediately..."
systemctl restart xray

echo "=========================================================="
echo "            🚫 USER REVOKED: $USERNAME                    "
echo "=========================================================="
echo "Their VLESS link will no longer connect to the bridge."

# Optional: Disable the link in the user_links.txt file
LINKS_FILE="/usr/local/etc/xray/user_links.txt"
if [ -f "$LINKS_FILE" ]; then
    # Escape regex metacharacters in username to prevent injection (e.g. '.' or '/')
    SAFE_USER=$(printf '%s' "$USERNAME" | sed 's/[]\.*^$()[+?{|/]/\\&/g')
    sed -i "s~.*${SAFE_USER}:.*~[REVOKED] &~" "$LINKS_FILE"
    echo "Marked as revoked in $LINKS_FILE."
fi
echo "=========================================================="