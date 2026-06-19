#!/bin/bash
# setup-named-tunnel.sh — One-time setup for a Cloudflare Named Tunnel.
#
# This creates a persistent tunnel with a fixed URL that survives restarts.
# After running this script, set the env vars in your shell profile and
# use `start-bridge.sh` as before — it will auto-detect the named tunnel.
#
# Prerequisites:
#   - cloudflared installed (brew install cloudflared)
#   - A Cloudflare account (free tier is fine)
#   - A domain added to Cloudflare DNS
#
# Usage:
#   bash scripts/setup-named-tunnel.sh <tunnel-name> <subdomain.yourdomain.com>
#
# Example:
#   bash scripts/setup-named-tunnel.sh magi-bridge opend.dogma.jp
#
# After setup, add to ~/.zshrc or ~/.bash_profile:
#   export CLOUDFLARE_TUNNEL_NAME="magi-bridge"
#   export CLOUDFLARE_TUNNEL_URL="https://opend.dogma.jp"

set -e

if [ $# -lt 2 ]; then
  echo "Usage: $0 <tunnel-name> <subdomain.domain.com>"
  echo ""
  echo "Example:"
  echo "  $0 magi-bridge opend.dogma.jp"
  echo ""
  echo "Prerequisites:"
  echo "  1. cloudflared installed: brew install cloudflared"
  echo "  2. Logged in to Cloudflare: cloudflared tunnel login"
  echo "  3. Domain added to Cloudflare DNS"
  exit 1
fi

TUNNEL_NAME="$1"
HOSTNAME="$2"
BRIDGE_PORT=11436
CONFIG_FILE="${HOME}/.cloudflared/config-${TUNNEL_NAME}.yml"

echo "=== Cloudflare Named Tunnel Setup ==="
echo "  Tunnel name: ${TUNNEL_NAME}"
echo "  Hostname:    ${HOSTNAME}"
echo "  Bridge port: ${BRIDGE_PORT}"
echo ""

# --- Step 1: Check cloudflared login ---
if [ ! -f "${HOME}/.cloudflared/cert.pem" ]; then
  echo "[Step 1] Logging in to Cloudflare..."
  echo "  A browser window will open. Select the domain: $(echo ${HOSTNAME} | rev | cut -d. -f1-2 | rev)"
  cloudflared tunnel login
else
  echo "[Step 1] Already logged in (cert.pem exists)"
fi

# --- Step 2: Create the tunnel ---
echo ""
echo "[Step 2] Creating tunnel '${TUNNEL_NAME}'..."
if cloudflared tunnel list | grep -q "${TUNNEL_NAME}"; then
  echo "  Tunnel '${TUNNEL_NAME}' already exists"
  TUNNEL_ID=$(cloudflared tunnel list --output json | python3 -c "
import json, sys
tunnels = json.load(sys.stdin)
for t in tunnels:
    if t['name'] == '${TUNNEL_NAME}':
        print(t['id'])
        break
")
else
  TUNNEL_ID=$(cloudflared tunnel create "${TUNNEL_NAME}" 2>&1 | grep -oE '[0-9a-f-]{36}' | head -1)
  echo "  Created tunnel ID: ${TUNNEL_ID}"
fi

echo "  Tunnel ID: ${TUNNEL_ID}"

# --- Step 3: Create DNS route ---
echo ""
echo "[Step 3] Creating DNS route: ${HOSTNAME} → tunnel..."
cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}" 2>&1 || echo "  (DNS route may already exist — OK)"

# --- Step 4: Write config file ---
echo ""
echo "[Step 4] Writing config: ${CONFIG_FILE}"
mkdir -p "${HOME}/.cloudflared"
cat > "${CONFIG_FILE}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${HOME}/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:${BRIDGE_PORT}
  - service: http_status:404
EOF

echo "  Config written successfully"

# --- Step 5: Register in BigQuery ---
echo ""
echo "[Step 5] Registering fixed URL in BigQuery..."
TUNNEL_URL="https://${HOSTNAME}"
if command -v python3 >/dev/null 2>&1; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  python3 "${SCRIPT_DIR}/register-tunnel.py" "${TUNNEL_URL}" 2>/dev/null && echo "  Registered: opend-proxy → ${TUNNEL_URL}" || echo "  [SKIP] BigQuery registration (run manually: python3 scripts/register-tunnel.py ${TUNNEL_URL})"
else
  echo "  [SKIP] python3 not available. Register manually:"
  echo "  python3 scripts/register-tunnel.py ${TUNNEL_URL}"
fi

# --- Done ---
echo ""
echo "=== Setup complete ==="
echo ""
echo "Add these to your shell profile (~/.zshrc or ~/.bash_profile):"
echo ""
echo "  export CLOUDFLARE_TUNNEL_NAME=\"${TUNNEL_NAME}\""
echo "  export CLOUDFLARE_TUNNEL_URL=\"${TUNNEL_URL}\""
echo ""
echo "Then restart the bridge:"
echo "  cd ~/magi-moomoo && bash scripts/start-bridge.sh"
echo ""
echo "The URL ${TUNNEL_URL} is now permanent and will not change on restart."
echo "No more stale URLs in BigQuery!"
