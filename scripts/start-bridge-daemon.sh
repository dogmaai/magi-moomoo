#!/bin/bash
# start-bridge-daemon.sh — TIALA watchdog for the MooMoo bridge + cloudflared tunnel.
#
# Usage:
#   bash scripts/start-bridge-daemon.sh              # foreground (logs to stdout)
#   nohup bash scripts/start-bridge-daemon.sh >/tmp/moomoo-bridge-daemon.log 2>&1 &
#
# This script keeps start-bridge.sh alive. Every INTERVAL seconds it checks
# the local bridge /health endpoint and the bridge's own tunnel process
# (named tunnel when CLOUDFLARE_TUNNEL_NAME is set, otherwise the quick
# tunnel). After MAX_FAIL consecutive failures it kills the bridge + its
# tunnel and re-runs start-bridge.sh, which respawns both.
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
# Fixed value, duplicated in start-bridge.sh — change both together.
BRIDGE_PORT=11436
FAIL_COUNT=0

# Shared pgrep patterns for the bridge's own tunnel (same definition that
# start-bridge.sh uses when it spawns / looks for the tunnel). A bare
# `pgrep -x cloudflared` is wrong on hosts running multiple cloudflared
# tunnels: an unrelated tunnel keeps a dead bridge tunnel invisible.
# shellcheck source=lib/tunnel-pattern.sh
. "${SCRIPT_DIR}/lib/tunnel-pattern.sh"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# The pattern matching ONLY the tunnel that serves this bridge:
# named tunnel when CLOUDFLARE_TUNNEL_NAME is set, otherwise the quick tunnel.
tunnel_pattern() {
  bridge_tunnel_pattern "${CLOUDFLARE_TUNNEL_NAME:-}" "${BRIDGE_PORT}"
}

# Check whether the local bridge and its own tunnel process are alive.
# TIALA often cannot curl its own public tunnel URL due to hairpin NAT,
# so use local health checks instead of an external reachability test.
check_bridge_alive() {
  if ! curl -sf --max-time 5 "http://localhost:${BRIDGE_PORT}/health" >/dev/null 2>&1; then
    log "Local bridge /health is not responding"
    return 1
  fi
  if ! pgrep -f "$(tunnel_pattern)" >/dev/null 2>&1; then
    if [ -n "${CLOUDFLARE_TUNNEL_NAME:-}" ]; then
      log "Bridge tunnel '${CLOUDFLARE_TUNNEL_NAME}' process is not running"
    else
      log "Bridge quick-tunnel process is not running"
    fi
    return 1
  fi
  return 0
}

# Kill the bridge and any quick-tunnel cloudflared process, then start fresh.
restart_bridge() {
  log "Restarting bridge/tunnel..."
  pkill -f "moomoo_bridge.py" 2>/dev/null || true

  # Kill the bridge's own tunnel so start-bridge.sh respawns it.
  # - quick tunnels match `--url ...:<port>` (stale ones can create
  #   conflicting URLs)
  # - named tunnels match their config file; start-bridge.sh skips a
  #   running named tunnel, so a dead-but-present process must be removed
  local pids
  pids=$(pgrep -f "$(tunnel_pattern)" 2>/dev/null || true)
  if [ -n "${pids}" ]; then
    log "Stopping bridge tunnel PIDs: ${pids}"
    kill -TERM ${pids} 2>/dev/null || true
    sleep 2
    kill -KILL ${pids} 2>/dev/null || true
  fi

  sleep 3
  # Configuration errors (exit 78 = EX_CONFIG) are permanent: retrying with
  # the same plist/env can never succeed, so the watchdog exits cleanly and
  # launchd (KeepAlive SuccessfulExit=false) does not restart it. Transient
  # startup failures keep any other exit code and stay retryable.
  local rc=0
  bash "${REPO_ROOT}/scripts/start-bridge.sh" || rc=$?
  if [ "${rc}" -eq 78 ]; then
    log "FATAL: start-bridge.sh exited 78 (configuration error) — stopping watchdog. Fix the config (plist/bridge.env) and restart the launch agent."
    exit 0
  fi
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
