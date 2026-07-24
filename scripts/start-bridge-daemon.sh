#!/bin/bash
# start-bridge-daemon.sh — TIALA watchdog for the MooMoo bridge + cloudflared tunnel.
#
# Usage:
#   bash scripts/start-bridge-daemon.sh              # foreground (logs to stdout)
#   nohup bash scripts/start-bridge-daemon.sh >/tmp/moomoo-bridge-daemon.log 2>&1 &
#
# This script keeps start-bridge.sh alive. Every INTERVAL seconds it tries to
# reach the public opend-proxy URL in BigQuery. After MAX_FAIL consecutive
# failures it kills the bridge + quick tunnel and re-runs start-bridge.sh.
#
# Recommended long-term fix: switch to a Cloudflare Named Tunnel
# (scripts/setup-named-tunnel.sh) so the URL is persistent and cloudflared
# can be managed by launchd/systemd instead of quick tunnels.
#
# Environment:
#   INTERVAL    Health check interval in seconds (default: 60)
#   MAX_FAIL    Consecutive failures before restart (default: 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
INTERVAL="${INTERVAL:-60}"
MAX_FAIL="${MAX_FAIL:-2}"
FAIL_COUNT=0

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# Query BigQuery for the latest opend-proxy URL.
# Uses Application Default Credentials; set GOOGLE_APPLICATION_CREDENTIALS if needed.
get_opend_proxy_url() {
  python3 - <<'PY'
import os
from google.cloud import bigquery

# Allow an explicit service-account key to be passed as an env var
key_json = os.environ.get('GOOGLE_PRIVATE_KEY')
if key_json:
    import json
    from google.oauth2 import service_account
    creds = service_account.Credentials.from_service_account_info(json.loads(key_json))
    client = bigquery.Client(project='screen-share-459802', credentials=creds)
else:
    client = bigquery.Client(project='screen-share-459802')

rows = list(client.query("""
    SELECT url FROM `screen-share-459802.magi_core.service_endpoints`
    WHERE service = 'opend-proxy'
    ORDER BY IFNULL(SAFE_CAST(updated_at AS TIMESTAMP), TIMESTAMP('1970-01-01')) DESC
    LIMIT 1
""", location='US').result())
print(rows[0].url if rows else '')
PY
}

# Check whether the public tunnel URL is serving /health.
check_public_tunnel() {
  local url
  url=$(get_opend_proxy_url)
  if [ -z "${url}" ]; then
    log "No opend-proxy URL in BigQuery"
    return 1
  fi
  curl -sf --max-time 15 "${url}/health" >/dev/null 2>&1
}

# Kill the bridge and any quick-tunnel cloudflared process, then start fresh.
restart_bridge() {
  log "Restarting bridge/tunnel..."
  pkill -f "moomoo_bridge.py" 2>/dev/null || true

  # Kill quick-tunnel cloudflared processes pointing at the bridge port.
  # Named tunnels are left alone; this script is primarily for quick-tunnel recovery.
  local pids
  pids=$(pgrep -f "cloudflared.*tunnel.*--url.*:11436" 2>/dev/null || true)
  if [ -n "${pids}" ]; then
    log "Stopping stale quick tunnel PIDs: ${pids}"
    kill -TERM ${pids} 2>/dev/null || true
    sleep 2
    kill -KILL ${pids} 2>/dev/null || true
  fi

  sleep 3
  bash "${REPO_ROOT}/scripts/start-bridge.sh" || true
}

log "Starting MooMoo bridge daemon (INTERVAL=${INTERVAL}s, MAX_FAIL=${MAX_FAIL})"

# Initial start
restart_bridge

while true; do
  sleep "${INTERVAL}"

  if check_public_tunnel; then
    [ "${FAIL_COUNT}" -gt 0 ] && log "Public tunnel health OK"
    FAIL_COUNT=0
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "Public tunnel health check failed (${FAIL_COUNT}/${MAX_FAIL})"
    if [ "${FAIL_COUNT}" -ge "${MAX_FAIL}" ]; then
      FAIL_COUNT=0
      restart_bridge
    fi
  fi
done
