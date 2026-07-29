#!/bin/bash
# start-openclaw-named-tunnel.sh — Start the Cloudflare named tunnel for OpenClaw Gateway.
#
# Usage:
#   bash scripts/start-openclaw-named-tunnel.sh
#
# This requires setup-openclaw-named-tunnel.sh to have been run once.

set -e

TUNNEL_NAME="${OPENCLAW_TUNNEL_NAME:-magi-openclaw}"
CONFIG_FILE="${HOME}/.cloudflared/config-${TUNNEL_NAME}.yml"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "[ERROR] No tunnel config found at ${CONFIG_FILE}"
  echo "        Run: bash scripts/setup-openclaw-named-tunnel.sh <hostname>"
  exit 1
fi

echo "[cloudflared] Starting named tunnel '${TUNNEL_NAME}' for OpenClaw Gateway..."
cloudflared tunnel --config "${CONFIG_FILE}" run "${TUNNEL_NAME}"
