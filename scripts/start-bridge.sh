#!/bin/bash
# start-bridge.sh — Start moomoo-bridge + ngrok, then register URL in BigQuery.
#
# Usage (on TIALA):
#   cd ~/magi-moomoo && bash scripts/start-bridge.sh
#
# Prerequisites:
#   - python3 with moomoo-api, flask, google-cloud-bigquery
#     pip install -r bridge/requirements.txt google-cloud-bigquery
#   - MooMoo OpenD running on localhost:11111
#   - ngrok installed and authenticated
#   - GCP credentials (ADC or GOOGLE_APPLICATION_CREDENTIALS)

set -e

BRIDGE_PORT=11436
BRIDGE_SCRIPT="${BRIDGE_SCRIPT:-bridge/moomoo_bridge.py}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- 1. Start moomoo-bridge if not running ---
if lsof -i ":${BRIDGE_PORT}" >/dev/null 2>&1; then
  echo "[bridge] Already running on port ${BRIDGE_PORT}"
else
  echo "[bridge] Starting ${BRIDGE_SCRIPT} on port ${BRIDGE_PORT}..."
  python3 "${BRIDGE_SCRIPT}" &
  BRIDGE_PID=$!
  sleep 2
  if ! kill -0 "${BRIDGE_PID}" 2>/dev/null; then
    echo "[bridge] Failed to start. Check ${BRIDGE_SCRIPT}."
    exit 1
  fi
  echo "[bridge] Started (PID ${BRIDGE_PID})"
fi

# --- 2. Start ngrok if not running ---
if curl -s http://localhost:4040/api/tunnels >/dev/null 2>&1; then
  echo "[ngrok] Already running"
else
  echo "[ngrok] Starting ngrok http ${BRIDGE_PORT}..."
  ngrok http "${BRIDGE_PORT}" --log=stdout > /tmp/ngrok.log 2>&1 &
  NGROK_PID=$!

  # Wait for ngrok to be ready
  for i in $(seq 1 10); do
    if curl -s http://localhost:4040/api/tunnels >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! curl -s http://localhost:4040/api/tunnels >/dev/null 2>&1; then
    echo "[ngrok] Failed to start. Check /tmp/ngrok.log"
    exit 1
  fi
  echo "[ngrok] Started (PID ${NGROK_PID})"
fi

# --- 3. Register ngrok URL in BigQuery ---
echo "[register] Updating BigQuery service_endpoints..."
python3 "${SCRIPT_DIR}/register-ngrok.py"

echo ""
echo "=== MooMoo bridge ready ==="
echo "  bridge:  http://localhost:${BRIDGE_PORT}"
NGROK_URL=$(curl -s http://localhost:4040/api/tunnels | python3 -c "import sys,json; print(json.load(sys.stdin)['tunnels'][0]['public_url'])" 2>/dev/null || echo "unknown")
echo "  ngrok:   ${NGROK_URL}"
echo "  BigQuery: opend-proxy → ${NGROK_URL}"
