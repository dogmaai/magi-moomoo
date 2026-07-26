#!/bin/bash
# start-bridge-daemon.sh — TIALA watchdog for the MooMoo bridge + cloudflared tunnel.
#
# Usage:
#   bash scripts/start-bridge-daemon.sh              # foreground (logs to stdout)
#   nohup bash scripts/start-bridge-daemon.sh >/tmp/moomoo-bridge-daemon.log 2>&1 &
#
# This script keeps start-bridge.sh alive. Every INTERVAL seconds it checks
# the local bridge /health endpoint and the cloudflared process. After MAX_FAIL
# consecutive failures it kills the bridge + quick tunnel and re-runs start-bridge.sh.
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

# Check whether the local bridge and the cloudflared process are alive.
# TIALA often cannot curl its own public tunnel URL due to hairpin NAT,
# so use local health checks instead of an external reachability test.
check_bridge_alive() {
  if ! curl -sf --max-time 5 "http://localhost:11436/health" >/dev/null 2>&1; then
    log "Local bridge /health is not responding"
    return 1
  fi
  if ! pgrep -x cloudflared >/dev/null 2>&1; then
    log "cloudflared process is not running"
    return 1
  fi
  return 0
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

  if check_bridge_alive; then
    [ "${FAIL_COUNT}" -gt 0 ] && log "Bridge and tunnel process are healthy"
    FAIL_COUNT=0
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "Local bridge/tunnel check failed (${FAIL_COUNT}/${MAX_FAIL})"
    if [ "${FAIL_COUNT}" -ge "${MAX_FAIL}" ]; then
      FAIL_COUNT=0
      restart_bridge
    fi
  fi
done
