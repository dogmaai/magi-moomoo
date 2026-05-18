#!/bin/bash
# start-bridge.sh — Start moomoo-bridge + tunnel (cloudflared or ngrok),
# then register the tunnel URL in BigQuery.
#
# Usage (on TIALA):
#   cd ~/magi-moomoo && bash scripts/start-bridge.sh              # cloudflared (default)
#   cd ~/magi-moomoo && bash scripts/start-bridge.sh --ngrok       # ngrok (legacy)
#
# Prerequisites:
#   - python3 with moomoo-api, flask, google-cloud-bigquery
#     pip install -r bridge/requirements.txt google-cloud-bigquery
#   - MooMoo OpenD running on localhost:11111
#   - cloudflared installed (brew install cloudflared) OR ngrok
#   - GCP credentials (ADC or GOOGLE_APPLICATION_CREDENTIALS)

set -e

BRIDGE_PORT=11436
BRIDGE_SCRIPT="${BRIDGE_SCRIPT:-bridge/moomoo_bridge.py}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TUNNEL_MODE="${1:-cloudflared}"

# Optional: pin a specific SIMULATE account by ID.
# If not set, the bridge auto-discovers the correct account
# (US → STOCK_AND_OPTION, HK → STOCK) via get_acc_list().
# Use /accounts endpoint to verify the selected account.
if [ -n "${MOOMOO_ACC_ID}" ]; then
  export MOOMOO_ACC_ID
  echo "[config] MOOMOO_ACC_ID=${MOOMOO_ACC_ID} (from env)"
else
  echo "[config] MOOMOO_ACC_ID not set — bridge will auto-discover SIMULATE account"
fi

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

# --- 2. Start tunnel ---
if [ "${TUNNEL_MODE}" = "--ngrok" ]; then
  # ---- ngrok (legacy) ----
  if curl -s http://localhost:4040/api/tunnels >/dev/null 2>&1; then
    echo "[ngrok] Already running"
  else
    echo "[ngrok] Starting ngrok http ${BRIDGE_PORT}..."
    ngrok http "${BRIDGE_PORT}" --log=stdout > /tmp/ngrok.log 2>&1 &
    NGROK_PID=$!

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

  # Register via ngrok API
  echo "[register] Updating BigQuery service_endpoints..."
  python3 "${SCRIPT_DIR}/register-tunnel.py" --ngrok

  TUNNEL_URL=$(curl -s http://localhost:4040/api/tunnels | python3 -c "import sys,json; print(json.load(sys.stdin)['tunnels'][0]['public_url'])" 2>/dev/null || echo "unknown")

else
  # ---- cloudflared (default) ----
  echo "[cloudflared] Starting tunnel to http://localhost:${BRIDGE_PORT}..."
  cloudflared tunnel --url "http://localhost:${BRIDGE_PORT}" > /tmp/cloudflared.log 2>&1 &
  CF_PID=$!

  # Wait for cloudflared to output the tunnel URL
  TUNNEL_URL=""
  for i in $(seq 1 30); do
    TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
    if [ -n "${TUNNEL_URL}" ]; then
      break
    fi
    sleep 1
  done

  if [ -z "${TUNNEL_URL}" ]; then
    echo "[cloudflared] Failed to obtain tunnel URL after 30s. Check /tmp/cloudflared.log"
    kill "${CF_PID}" 2>/dev/null || true
    exit 1
  fi
  echo "[cloudflared] Started (PID ${CF_PID})"
  echo "[cloudflared] URL: ${TUNNEL_URL}"

  # Register tunnel URL in BigQuery
  echo "[register] Updating BigQuery service_endpoints..."
  python3 "${SCRIPT_DIR}/register-tunnel.py" "${TUNNEL_URL}"
fi

# --- 3. Summary ---
echo ""
echo "=== MooMoo bridge ready ==="
echo "  bridge:  http://localhost:${BRIDGE_PORT}"
echo "  tunnel:  ${TUNNEL_URL}"
echo "  BigQuery: opend-proxy → ${TUNNEL_URL}"
echo ""
echo "To stop: kill %1 %2  (or pkill -f moomoo_bridge; pkill -f cloudflared)"
