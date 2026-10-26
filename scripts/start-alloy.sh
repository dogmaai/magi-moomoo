#!/bin/bash
# start-alloy.sh — Launch wrapper for Grafana Alloy on TIALA (com.magi.alloy).
#
# Sources the host-local env file (never checked in) and execs `alloy run`
# on the repo config. Nothing credential- or host-specific lives in this
# repo — the env file holds the token, the Hosted Metrics instance ID,
# and the scrape target.
#
# Env file:   ${ALLOY_ENV_FILE:-~/.config/magi-moomoo/alloy.env}   (mode 600)
# Config:     scripts/alloy/config.alloy
# Storage:    ${ALLOY_STORAGE_PATH:-~/Library/Application Support/magi-alloy}
# Binary:     ${ALLOY_BIN:-alloy on PATH}
#
# Config problems exit 0 on purpose: launchd KeepAlive{SuccessfulExit:false}
# treats a nonzero exit as restartable, so a permanent configuration error
# (missing env file / missing vars) must exit cleanly to avoid a restart
# loop — same intent as the bridge's EX_CONFIG mapping.

set -u

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ENV_FILE="${ALLOY_ENV_FILE:-${HOME}/.config/magi-moomoo/alloy.env}"
STORAGE_PATH="${ALLOY_STORAGE_PATH:-${HOME}/Library/Application Support/magi-alloy}"

if [ ! -f "${ENV_FILE}" ]; then
  log "FATAL: env file ${ENV_FILE} not found — run scripts/install-alloy-launchagent.sh first"
  exit 0
fi
# shellcheck source=/dev/null
. "${ENV_FILE}"

missing=0
for v in GRAFANA_ALLOY_REMOTE_WRITE_TOKEN PROM_REMOTE_WRITE_URL \
         PROM_REMOTE_WRITE_USERNAME ALLOY_SCRAPE_ADDRESS \
         ALLOY_SCRAPE_METRICS_PATH; do
  eval "val=\${${v}:-}"
  if [ -z "${val}" ]; then
    log "FATAL: ${v} is unset in ${ENV_FILE}"
    missing=1
  fi
done
if [ "${missing}" -eq 1 ]; then
  exit 0
fi

ALLOY_BIN="${ALLOY_BIN:-alloy}"
if ! command -v "${ALLOY_BIN}" >/dev/null 2>&1; then
  log "FATAL: ${ALLOY_BIN} not found on PATH=${PATH}"
  exit 0
fi

CONFIG="${ALLOY_CONFIG:-$(cd "$(dirname "$0")" && pwd)/alloy/config.alloy}"
if [ ! -f "${CONFIG}" ]; then
  log "FATAL: config not found at ${CONFIG}"
  exit 0
fi

mkdir -p "${STORAGE_PATH}"

log "starting alloy (config=${CONFIG}, storage=${STORAGE_PATH})"
exec "${ALLOY_BIN}" run "${CONFIG}" \
  --storage.path "${STORAGE_PATH}" \
  --disable-reporting
