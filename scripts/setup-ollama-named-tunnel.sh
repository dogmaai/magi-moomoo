#!/bin/bash
# setup-ollama-named-tunnel.sh — One-time setup for a Cloudflare Named Tunnel
# exposing TIALA's Ollama API on a fixed hostname.
#
# This replaces the ephemeral *.trycloudflare.com URL used by ADAM (PLM) with a
# stable hostname that does not change when cloudflared restarts.
#
# Prerequisites:
#   - cloudflared installed (brew install cloudflared)
#   - Logged in to Cloudflare: cloudflared tunnel login
#   - A domain added to Cloudflare DNS (the khaos.company zone in Squarespace must
#     point its nameservers to Cloudflare, or be transferred, before this script runs)
#   - Ollama running on localhost:11434 (default)
#
# Usage:
#   bash scripts/setup-ollama-named-tunnel.sh <hostname>
#
# Example:
#   bash scripts/setup-ollama-named-tunnel.sh ollama.khaos.company

set -e

if [ $# -lt 1 ]; then
  echo "Usage: $0 <hostname>"
  echo ""
  echo "Example:"
  echo "  $0 ollama.khaos.company"
  echo ""
  echo "Prerequisites:"
  echo "  1. cloudflared installed: brew install cloudflared"
  echo "  2. Logged in to Cloudflare: cloudflared tunnel login"
  echo "  3. Domain added to Cloudflare DNS (e.g. khaos.company)"
  echo "  4. Ollama running on localhost:\${OLLAMA_PORT:-11434}"
  exit 1
fi

HOSTNAME="$1"
TUNNEL_NAME="${OLLAMA_TUNNEL_NAME:-magi-ollama}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
PROJECT_ID="${GCP_PROJECT:-screen-share-459802}"
SECRET_NAME="OLLAMA_BASE_URL"
CONFIG_FILE="${HOME}/.cloudflared/config-${TUNNEL_NAME}.yml"
TUNNEL_URL="https://${HOSTNAME}"

# Local service-account key used by register-tunnel.py for GCP auth.
DEFAULT_SA_KEY="${HOME}/.config/gcloud/service-account-key.json"

# If a service-account key exists, prefer it for gcloud/ADC.
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS}" ] && [ -f "${DEFAULT_SA_KEY}" ]; then
  export GOOGLE_APPLICATION_CREDENTIALS="${DEFAULT_SA_KEY}"
fi

echo "=== Ollama Named Tunnel Setup ==="
echo "  Hostname:    ${HOSTNAME}"
echo "  Tunnel name: ${TUNNEL_NAME}"
echo "  Ollama port: ${OLLAMA_PORT}"
echo "  Config:      ${CONFIG_FILE}"
echo "  GCP project: ${PROJECT_ID}"
echo ""

# --- Step 1: Check cloudflared login ---
if [ ! -f "${HOME}/.cloudflared/cert.pem" ]; then
  echo "[Step 1] No Cloudflare login certificate found."
  echo "         Run 'cloudflared tunnel login' first, then re-run this script."
  exit 1
fi
echo "[Step 1] Cloudflare login certificate found"

# --- Step 2: Check Ollama is reachable ---
echo ""
echo "[Step 2] Checking Ollama on http://localhost:${OLLAMA_PORT}..."
if ! curl -sf --max-time 3 "http://localhost:${OLLAMA_PORT}/" >/dev/null 2>&1; then
  echo "[ERROR] Ollama is not responding on http://localhost:${OLLAMA_PORT}"
  echo "        Start Ollama before creating the tunnel: ollama serve"
  exit 1
fi
echo "  Ollama is healthy"

# --- Step 3: Create the tunnel ---
echo ""
echo "[Step 3] Creating tunnel '${TUNNEL_NAME}'..."
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
  if [ -z "${TUNNEL_ID}" ]; then
    echo "[ERROR] Failed to create tunnel. Check 'cloudflared tunnel login' and domain permissions."
    exit 1
  fi
  echo "  Created tunnel ID: ${TUNNEL_ID}"
fi
echo "  Tunnel ID: ${TUNNEL_ID}"

# --- Step 4: Create DNS route ---
echo ""
echo "[Step 4] Creating DNS route: ${HOSTNAME} -> tunnel..."
if ! cloudflared tunnel route dns "${TUNNEL_NAME}" "${HOSTNAME}" 2>&1; then
  echo "  (DNS route may already exist — continuing)"
fi

# --- Step 5: Write cloudflared config file ---
echo ""
echo "[Step 5] Writing config: ${CONFIG_FILE}"
mkdir -p "${HOME}/.cloudflared"
cat > "${CONFIG_FILE}" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${HOME}/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:${OLLAMA_PORT}
  - service: http_status:404
EOF
echo "  Config written"

# --- Step 6: Update GCP Secret Manager OLLAMA_BASE_URL ---
echo ""
echo "[Step 6] Updating Secret Manager secret '${SECRET_NAME}'..."
if ! command -v gcloud >/dev/null 2>&1; then
  echo "  [SKIP] gcloud not installed. Update the secret manually after starting the tunnel:"
  echo "         echo -n '${TUNNEL_URL}' | gcloud secrets versions add ${SECRET_NAME} --project=${PROJECT_ID} --data-file=-"
else
  TMP_URL_FILE=$(mktemp)
  printf '%s' "${TUNNEL_URL}" > "${TMP_URL_FILE}"
  if gcloud secrets versions add "${SECRET_NAME}" --project="${PROJECT_ID}" --data-file="${TMP_URL_FILE}" 2>&1; then
    echo "  Secret updated: ${SECRET_NAME} = ${TUNNEL_URL}"
  else
    echo "  [WARN] Failed to update secret automatically. Update manually:"
    echo "         gcloud secrets versions add ${SECRET_NAME} --project=${PROJECT_ID} --data-file=<(echo -n '${TUNNEL_URL}')"
  fi
  rm -f "${TMP_URL_FILE}"
fi

# --- Step 7: Start the tunnel (foreground) ---
echo ""
echo "=== Setup complete ==="
echo ""
echo "Start the tunnel with:"
echo "  bash scripts/start-ollama-named-tunnel.sh"
echo ""
echo "Or install as a macOS LaunchAgent:"
echo "  cp scripts/com.magi.ollama.cloudflared.plist ~/Library/LaunchAgents/"
echo "  launchctl load ~/Library/LaunchAgents/com.magi.ollama.cloudflared.plist"
echo ""
echo "The public URL ${TUNNEL_URL} is now fixed."
echo "Next ADAM Cloud Run Job will use OLLAMA_BASE_URL=${TUNNEL_URL}"
