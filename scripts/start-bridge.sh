#!/bin/bash
# start-bridge.sh — Start moomoo-bridge + tunnel (named cloudflared, quick cloudflared, or ngrok),
# then register the tunnel URL in BigQuery.
#
# Usage (on TIALA):
#   cd ~/magi-moomoo && bash scripts/start-bridge.sh              # named tunnel (if configured) or quick tunnel
#   cd ~/magi-moomoo && bash scripts/start-bridge.sh --ngrok       # ngrok (legacy)
#
# Environment variables:
#   CLOUDFLARE_TUNNEL_NAME   — Named tunnel name (e.g. "magi-bridge"). If set, uses named tunnel.
#   CLOUDFLARE_TUNNEL_URL    — Fixed public URL for named tunnel (e.g. "https://opend.yourdomain.com").
#                              Required when CLOUDFLARE_TUNNEL_NAME is set.
#   MOOMOO_ACC_ID            — (optional) Pin a specific SIMULATE account by ID.
#
# Prerequisites:
#   - python3 with moomoo-api, flask, google-cloud-bigquery
#     pip install -r bridge/requirements.txt google-cloud-bigquery
#   - MooMoo OpenD running on localhost:11111
#   - cloudflared installed (brew install cloudflared) OR ngrok
#   - GCP credentials (ADC or GOOGLE_APPLICATION_CREDENTIALS)
#   - For named tunnels: run `bash scripts/setup-named-tunnel.sh` first (one-time)

set -e

BRIDGE_PORT=11436
BRIDGE_SCRIPT="${BRIDGE_SCRIPT:-bridge/moomoo_bridge.py}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TUNNEL_MODE="${1:-cloudflared}"

# Helper: stop any stale quick cloudflared tunnels targeting this bridge port.
# Quick tunnels are ephemeral; leftover processes cause duplicate/invalid URLs
# and can prevent the new tunnel from establishing.
_cleanup_quick_tunnels() {
  local pids
  pids=$(pgrep -f "cloudflared.*tunnel.*--url.*:${BRIDGE_PORT}" 2>/dev/null || true)
  if [ -n "${pids}" ]; then
    echo "[cloudflared] Stopping stale quick tunnel PIDs: ${pids}"
    kill -TERM ${pids} 2>/dev/null || true
    sleep 2
    kill -KILL ${pids} 2>/dev/null || true
  fi
}

# Helper: wait for a public tunnel URL to return HTTP 200 from the bridge /health.
# Prevents BigQuery from being updated with a tunnel that is not yet reachable.
_wait_for_tunnel_health() {
  local url=$1
  local max_attempts=${2:-30}
  local i
  for i in $(seq 1 ${max_attempts}); do
    if curl -s --fail --max-time 10 "${url}/health" >/dev/null 2>&1; then
      echo "[cloudflared] Tunnel health OK: ${url}/health"
      return 0
    fi
    sleep 1
  done
  echo "[cloudflared] Tunnel health check failed after ${max_attempts}s: ${url}/health"
  return 1
}

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

elif [ -n "${CLOUDFLARE_TUNNEL_NAME}" ]; then
  # ---- Named Tunnel (persistent URL, recommended) ----
  if [ -z "${CLOUDFLARE_TUNNEL_URL}" ]; then
    echo "[ERROR] CLOUDFLARE_TUNNEL_URL must be set when using named tunnel."
    echo "        Example: export CLOUDFLARE_TUNNEL_URL=https://opend.yourdomain.com"
    exit 1
  fi

  TUNNEL_URL="${CLOUDFLARE_TUNNEL_URL}"

  # Check if named tunnel is already running
  if pgrep -f "cloudflared.*tunnel.*run.*${CLOUDFLARE_TUNNEL_NAME}" >/dev/null 2>&1; then
    echo "[cloudflared] Named tunnel '${CLOUDFLARE_TUNNEL_NAME}' already running"
  else
    echo "[cloudflared] Starting named tunnel '${CLOUDFLARE_TUNNEL_NAME}'..."
    cloudflared tunnel --config "${HOME}/.cloudflared/config-${CLOUDFLARE_TUNNEL_NAME}.yml" run "${CLOUDFLARE_TUNNEL_NAME}" > /tmp/cloudflared.log 2>&1 &
    CF_PID=$!

    # Wait for tunnel to establish
    sleep 3
    if ! kill -0 "${CF_PID}" 2>/dev/null; then
      echo "[cloudflared] Named tunnel failed to start. Check /tmp/cloudflared.log"
      cat /tmp/cloudflared.log
      exit 1
    fi
    echo "[cloudflared] Named tunnel started (PID ${CF_PID})"
  fi

  echo "[cloudflared] URL: ${TUNNEL_URL} (fixed — does not change on restart)"

  # Wait for tunnel to be externally reachable before claiming it is up.
  if ! _wait_for_tunnel_health "${TUNNEL_URL}" 30; then
    echo "[cloudflared] Named tunnel ${CLOUDFLARE_TUNNEL_NAME} is not serving traffic."
    kill -KILL "${CF_PID}" 2>/dev/null || true
    exit 1
  fi

  # Register in BigQuery (idempotent — only inserts if URL differs from latest)
  echo "[register] Ensuring BigQuery service_endpoints is up-to-date..."
  python3 "${SCRIPT_DIR}/register-tunnel.py" "${TUNNEL_URL}"

else
  # ---- Quick Tunnel (ephemeral URL, legacy default) ----
  echo "[cloudflared] Starting quick tunnel to http://localhost:${BRIDGE_PORT}..."
  echo "[WARNING] Quick tunnels generate a new URL on every restart."
  echo "          Consider using a named tunnel for stability."
  echo "          Run: bash scripts/setup-named-tunnel.sh"
  echo ""

  # Kill any leftover quick tunnel processes; they can create conflicting URLs
  # and cause control-stream failures when a fresh tunnel starts.
  _cleanup_quick_tunnels

  # Use a fresh log file so we do not read a stale URL from an old process.
  LOG_FILE=$(mktemp /tmp/cloudflared.XXXXXX.log 2>/dev/null || echo "/tmp/cloudflared.log")
  : > "${LOG_FILE}"

  cloudflared tunnel --url "http://localhost:${BRIDGE_PORT}" > "${LOG_FILE}" 2>&1 &
  CF_PID=$!

  # Wait for cloudflared to output the tunnel URL
  TUNNEL_URL=""
  for i in $(seq 1 30); do
    TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "${LOG_FILE}" 2>/dev/null | head -1)
    if [ -n "${TUNNEL_URL}" ]; then
      break
    fi
    sleep 1
  done

  if [ -z "${TUNNEL_URL}" ]; then
    echo "[cloudflared] Failed to obtain tunnel URL after 30s. Check ${LOG_FILE}"
    kill -KILL "${CF_PID}" 2>/dev/null || true
    exit 1
  fi
  echo "[cloudflared] Started (PID ${CF_PID})"
  echo "[cloudflared] URL: ${TUNNEL_URL}"

  # Do not register until the tunnel is actually serving traffic.
  if ! _wait_for_tunnel_health "${TUNNEL_URL}" 30; then
    echo "[cloudflared] Quick tunnel is not serving traffic. Check ${LOG_FILE}"
    kill -KILL "${CF_PID}" 2>/dev/null || true
    exit 1
  fi

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
if [ -n "${CLOUDFLARE_TUNNEL_NAME}" ]; then
  echo "  mode:    Named Tunnel (persistent URL)"
else
  echo "  mode:    Quick Tunnel (ephemeral URL — changes on restart!)"
fi
echo ""
echo "To stop: kill %1 %2  (or pkill -f moomoo_bridge; pkill -f cloudflared)"
