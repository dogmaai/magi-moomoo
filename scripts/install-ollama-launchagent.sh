#!/bin/bash
# install-ollama-launchagent.sh — Install a macOS LaunchAgent for the Ollama named tunnel.
#
# Fetches the tunnel token from GCP Secret Manager, decodes it to a cloudflared
# credentials file, writes a local ingress config, and installs/loads a LaunchAgent.
#
# Usage:
#   bash scripts/install-ollama-launchagent.sh [hostname]
#
# Example:
#   bash scripts/install-ollama-launchagent.sh ollama.khaos.company

set -e

HOSTNAME="${1:-ollama.khaos.company}"
TUNNEL_NAME="${OLLAMA_TUNNEL_NAME:-magi-ollama}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_HOST_HEADER="${OLLAMA_HOST_HEADER:-localhost:${OLLAMA_PORT}}"
PROJECT_ID="${GCP_PROJECT:-screen-share-459802}"
TOKEN_SECRET="OLLAMA_TUNNEL_TOKEN"

CLOUDFLARED_DIR="${HOME}/.cloudflared"
PLIST_NAME="com.magi.ollama.cloudflared"
PLIST_SRC="scripts/com.magi.ollama.cloudflared.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# If a service-account key exists, prefer it for gcloud/ADC.
DEFAULT_SA_KEY="${HOME}/.config/gcloud/service-account-key.json"
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS}" ] && [ -f "${DEFAULT_SA_KEY}" ]; then
  export GOOGLE_APPLICATION_CREDENTIALS="${DEFAULT_SA_KEY}"
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "[ERROR] gcloud not found. Install the Google Cloud SDK first."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] python3 not found."
  exit 1
fi

mkdir -p "${CLOUDFLARED_DIR}"

echo "[Step 1] Fetching tunnel token from Secret Manager..."
export TOKEN=$(gcloud secrets versions access latest --secret="${TOKEN_SECRET}" --project="${PROJECT_ID}" | tr -d '\n')
if [ -z "${TOKEN}" ]; then
  echo "[ERROR] Failed to fetch ${TOKEN_SECRET}"
  exit 1
fi

echo "[Step 2] Decoding token and writing credentials/config files..."
python3 - <<PY
import base64, json, os

token = os.environ['TOKEN']
data = json.loads(base64.b64decode(token))

tunnel_id = data['t']
account_tag = data['a']
tunnel_secret = data['s']

cred = {
    'AccountTag': account_tag,
    'TunnelID': tunnel_id,
    'TunnelName': '${TUNNEL_NAME}',
    'TunnelSecret': tunnel_secret,
}

cred_file = os.path.expanduser('${CLOUDFLARED_DIR}/${TUNNEL_NAME}.json')
with open(cred_file, 'w') as f:
    json.dump(cred, f)
os.chmod(cred_file, 0o600)
print('  credentials:', cred_file)

config_file = os.path.expanduser('${CLOUDFLARED_DIR}/config-${TUNNEL_NAME}.yml')
with open(config_file, 'w') as f:
    f.write(f"""tunnel: {tunnel_id}
credentials-file: {cred_file}

ingress:
  - hostname: ${HOSTNAME}
    service: http://localhost:${OLLAMA_PORT}
    originRequest:
      httpHostHeader: ${OLLAMA_HOST_HEADER}
  - service: http_status:404
""")
os.chmod(config_file, 0o600)
print('  config:', config_file)
PY

echo "[Step 3] Installing LaunchAgent..."
if [ ! -f "${REPO_DIR}/${PLIST_SRC}" ]; then
  echo "[ERROR] LaunchAgent template not found at ${REPO_DIR}/${PLIST_SRC}"
  exit 1
fi
cp "${REPO_DIR}/${PLIST_SRC}" "${PLIST_DST}"

# The plist template has a hardcoded WorkingDirectory for /Users/jun/magi-moomoo.
# Update it to the actual repo path so the relative start script is found.
if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :WorkingDirectory ${REPO_DIR}" "${PLIST_DST}"
else
  # Fallback for non-macOS development/testing
  sed -i '' -e "s#<string>/Users/jun/magi-moomoo</string>#<string>${REPO_DIR}</string>#" "${PLIST_DST}" 2>/dev/null || true
fi

# Unload old agent if loaded, then load.
if launchctl list "${PLIST_NAME}" >/dev/null 2>&1; then
  launchctl unload "${PLIST_DST}" >/dev/null 2>&1 || true
fi
launchctl load "${PLIST_DST}"

echo ""
echo "=== LaunchAgent installed and loaded ==="
echo "  Plist: ${PLIST_DST}"
echo "  Logs:  /tmp/magi-ollama-cloudflared.stdout.log"
echo "         /tmp/magi-ollama-cloudflared.stderr.log"
echo "  Check: launchctl list ${PLIST_NAME}"
echo ""
echo "The tunnel will start automatically on the next login/reboot."
