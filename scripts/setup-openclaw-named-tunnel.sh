#!/bin/bash
# setup-openclaw-named-tunnel.sh — One-time setup for a Cloudflare Named Tunnel
# exposing TIALA's OpenClaw Gateway on a fixed hostname.
#
# This replaces the ephemeral *.trycloudflare.com URL used by magi-moni/AKA-1
# and Devin with a stable hostname that does not change when cloudflared restarts.
#
# Prerequisites:
#   - cloudflared installed (brew install cloudflared)
#   - Logged in to Cloudflare: cloudflared tunnel login
#   - A domain added to Cloudflare DNS (the khaos.company zone in Squarespace must
#     point its nameservers to Cloudflare, or be transferred, before this script runs)
#   - OpenClaw Gateway running on localhost:18789 (default)
#   - Python + google-cloud-bigquery (run scripts/setup-tools.sh on TIALA)
#
# Usage:
#   bash scripts/setup-openclaw-named-tunnel.sh <hostname>
#
# Example:
#   bash scripts/setup-openclaw-named-tunnel.sh openclaw.khaos.company

set -e

if [ $# -lt 1 ]; then
  echo "Usage: $0 <hostname>"
  echo ""
  echo "Example:"
  echo "  $0 openclaw.khaos.company"
  echo ""
  echo "Prerequisites:"
  echo "  1. cloudflared installed: brew install cloudflared"
  echo "  2. Logged in to Cloudflare: cloudflared tunnel login"
  echo "  3. Domain added to Cloudflare DNS (e.g. khaos.company)"
  echo "  4. OpenClaw Gateway running on localhost:\${OPENCLAW_PORT:-18789}"
  exit 1
fi

HOSTNAME="$1"
TUNNEL_NAME="${OPENCLAW_TUNNEL_NAME:-magi-openclaw}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_HOST_HEADER="${OPENCLAW_HOST_HEADER:-localhost:${OPENCLAW_PORT}}"
PROJECT_ID="${GCP_PROJECT:-screen-share-459802}"
SERVICE_NAME="${OPENCLAW_SERVICE_NAME:-openclaw}"
CONFIG_FILE="${HOME}/.cloudflared/config-${TUNNEL_NAME}.yml"
TUNNEL_URL="https://${HOSTNAME}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# If a service-account key exists, prefer it for gcloud/ADC.
DEFAULT_SA_KEY="${HOME}/.config/gcloud/service-account-key.json"
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS}" ] && [ -f "${DEFAULT_SA_KEY}" ]; then
  export GOOGLE_APPLICATION_CREDENTIALS="${DEFAULT_SA_KEY}"
fi

echo "=== OpenClaw Gateway Named Tunnel Setup ==="
echo "  Hostname:       ${HOSTNAME}"
echo "  Tunnel name:    ${TUNNEL_NAME}"
echo "  OpenClaw port:  ${OPENCLAW_PORT}"
echo "  Host header:    ${OPENCLAW_HOST_HEADER}"
echo "  Config:         ${CONFIG_FILE}"
echo "  GCP project:    ${PROJECT_ID}"
echo "  BQ service:     ${SERVICE_NAME}"
echo ""

# --- Step 1: Check cloudflared login ---
CERT_FILE="${HOME}/.cloudflared/cert.pem"
HAVE_AUTH=0
EXISTING_TUNNEL=""

if [ -f "${CERT_FILE}" ]; then
  HAVE_AUTH=1
  echo "[Step 1] Cloudflare login certificate found"
fi

if [ "${HAVE_AUTH}" -eq 0 ] && [ -n "${CLOUDFLARE_API_TOKEN}" ] && [ -n "${CLOUDFLARE_ACCOUNT_ID}" ]; then
  HAVE_AUTH=1
  echo "[Step 1] Using CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID for authentication"
fi

if [ "${HAVE_AUTH}" -eq 0 ] && [ -f "${CONFIG_FILE}" ]; then
  TUNNEL_ID=$(grep -oE '[0-9a-f-]{36}' "${CONFIG_FILE}" | head -1)
  if [ -n "${TUNNEL_ID}" ]; then
    # Prefer the credentials-file path written in the existing config.
    CONF_CRED_FILE=$(awk '/^credentials-file:/{print $2}' "${CONFIG_FILE}" | head -1)
    CONF_CRED_FILE="${CONF_CRED_FILE/#\~/${HOME}}"
    if [ -n "${CONF_CRED_FILE}" ] && [ -f "${CONF_CRED_FILE}" ]; then
      TUNNEL_CRED_FILE="${CONF_CRED_FILE}"
      EXISTING_TUNNEL=1
    elif [ -f "${HOME}/.cloudflared/${TUNNEL_ID}.json" ]; then
      TUNNEL_CRED_FILE="${HOME}/.cloudflared/${TUNNEL_ID}.json"
      EXISTING_TUNNEL=1
    elif [ -f "${HOME}/.cloudflared/${TUNNEL_NAME}.json" ]; then
      TUNNEL_CRED_FILE="${HOME}/.cloudflared/${TUNNEL_NAME}.json"
      EXISTING_TUNNEL=1
    fi
  fi
  if [ -n "${EXISTING_TUNNEL}" ]; then
    echo "[Step 1] No Cloudflare login certificate found, but existing tunnel config found."
    echo "         Tunnel ID: ${TUNNEL_ID}"
    echo "         Credentials: ${TUNNEL_CRED_FILE}"
    echo "         Will reuse the existing tunnel (DNS route must already exist)."
  fi
fi

if [ "${HAVE_AUTH}" -eq 0 ] && [ -z "${EXISTING_TUNNEL}" ]; then
  echo "[Step 1] No Cloudflare login certificate or existing tunnel config found."
  echo "         Run 'cloudflared tunnel login' first, or set CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID."
  exit 1
fi

# --- Step 2: Check OpenClaw is reachable ---
echo ""
echo "[Step 2] Checking OpenClaw Gateway on localhost:${OPENCLAW_PORT}..."
# Use curl instead of `timeout` because `timeout` is not available on stock macOS.
# Any HTTP response (including 404) means the port is reachable.
if ! curl --max-time 3 --connect-timeout 2 -s -o /dev/null "http://localhost:${OPENCLAW_PORT}/" >/dev/null 2>&1; then
  echo "[ERROR] OpenClaw Gateway is not responding on localhost:${OPENCLAW_PORT}"
  echo "        Start the OpenClaw Gateway before creating the tunnel."
  exit 1
fi
echo "  OpenClaw Gateway is healthy"

# --- Step 3: Create or reuse the tunnel ---
echo ""
echo "[Step 3] Creating tunnel '${TUNNEL_NAME}'..."
if [ -n "${EXISTING_TUNNEL}" ]; then
  echo "  Reusing existing tunnel '${TUNNEL_NAME}' (${TUNNEL_ID})"
elif cloudflared tunnel list | grep -q "${TUNNEL_NAME}"; then
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
TUNNEL_CRED_FILE="${TUNNEL_CRED_FILE:-${HOME}/.cloudflared/${TUNNEL_ID}.json}"

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
credentials-file: ${TUNNEL_CRED_FILE}

ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:${OPENCLAW_PORT}
    originRequest:
      httpHostHeader: ${OPENCLAW_HOST_HEADER}
  - service: http_status:404
EOF
echo "  Config written"

# --- Step 6: Register the fixed URL in BigQuery service_endpoints ---
echo ""
echo "[Step 6] Registering ${SERVICE_NAME} URL in BigQuery service_endpoints..."
if [ ! -f "${REPO_DIR}/scripts/register-tunnel.py" ]; then
  echo "[ERROR] register-tunnel.py not found in ${REPO_DIR}/scripts"
  exit 1
fi

if ! python3 "${REPO_DIR}/scripts/register-tunnel.py" --service "${SERVICE_NAME}" "${TUNNEL_URL}"; then
  echo "[WARN] Failed to register URL in BigQuery automatically."
  echo "       Register manually once the tunnel is running:"
  echo "         python3 scripts/register-tunnel.py --service ${SERVICE_NAME} ${TUNNEL_URL}"
fi

# --- Step 7: Store the base64 tunnel token for Secret Manager ---
echo ""
echo "[Step 7] Storing OpenClaw tunnel token for LaunchAgent installs..."
TUNNEL_CRED_FILE="${TUNNEL_CRED_FILE:-${HOME}/.cloudflared/${TUNNEL_ID}.json}"
TOKEN_FILE="${HOME}/.cloudflared/${TUNNEL_NAME}-token.b64"
if [ -f "${TUNNEL_CRED_FILE}" ]; then
  python3 - <<PY > "${TOKEN_FILE}"
import base64, json, os
cred_path = os.path.expanduser('${TUNNEL_CRED_FILE}')
with open(cred_path) as f:
    c = json.load(f)
token = {
    't': c.get('TunnelID') or c.get('tunnel_id') or '${TUNNEL_ID}',
    'a': c.get('AccountTag') or c.get('account_tag'),
    's': c.get('TunnelSecret') or c.get('tunnel_secret'),
}
with open(os.path.expanduser('${TOKEN_FILE}'), 'w') as out:
    out.write(base64.b64encode(json.dumps(token).encode()).decode())
PY
  chmod 600 "${TOKEN_FILE}"

  if command -v gcloud >/dev/null 2>&1; then
    if gcloud secrets describe "OPENCLAW_TUNNEL_TOKEN" --project="${PROJECT_ID}" >/dev/null 2>&1; then
      gcloud secrets versions add "OPENCLAW_TUNNEL_TOKEN" --project="${PROJECT_ID}" --data-file="${TOKEN_FILE}"
    else
      gcloud secrets create "OPENCLAW_TUNNEL_TOKEN" --project="${PROJECT_ID}" --data-file="${TOKEN_FILE}"
    fi
    echo "  Secret Manager: OPENCLAW_TUNNEL_TOKEN updated"
    rm -f "${TOKEN_FILE}"
  else
    echo "  [WARN] gcloud not found. Store the token manually and then remove ${TOKEN_FILE}:"
    echo "         gcloud secrets create OPENCLAW_TUNNEL_TOKEN --project=${PROJECT_ID} --data-file=${TOKEN_FILE}"
    echo "    or if the secret already exists:"
    echo "         gcloud secrets versions add OPENCLAW_TUNNEL_TOKEN --project=${PROJECT_ID} --data-file=${TOKEN_FILE}"
  fi
else
  echo "  [WARN] Credential file not found at ${CRED_FILE}"
  echo "         Re-run after cloudflared finishes writing credentials."
fi

# --- Step 8: Start the tunnel (foreground) ---
echo ""
echo "=== Setup complete ==="
echo ""
echo "Start the tunnel with:"
echo "  bash scripts/start-openclaw-named-tunnel.sh"
echo ""
echo "Or install as a macOS LaunchAgent (requires OPENCLAW_TUNNEL_TOKEN in Secret Manager):"
echo "  bash scripts/install-openclaw-launchagent.sh ${HOSTNAME}"
echo ""
echo "The public URL ${TUNNEL_URL} is now fixed."
echo "magi-moni and Devin will discover it via BigQuery service='${SERVICE_NAME}'."
