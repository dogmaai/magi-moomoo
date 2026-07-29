#!/bin/bash
# start-ollama-named-tunnel.sh — Start the Cloudflare named tunnel for Ollama.
#
# Usage:
#   bash scripts/start-ollama-named-tunnel.sh
#
# This requires setup-ollama-named-tunnel.sh to have been run once.

set -e

TUNNEL_NAME="${OLLAMA_TUNNEL_NAME:-magi-ollama}"
CONFIG_FILE="${HOME}/.cloudflared/config-${TUNNEL_NAME}.yml"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "[ERROR] No tunnel config found at ${CONFIG_FILE}"
  echo "        Run: bash scripts/setup-ollama-named-tunnel.sh <hostname>"
  exit 1
fi

echo "[cloudflared] Starting named tunnel '${TUNNEL_NAME}'..."
cloudflared tunnel --config "${CONFIG_FILE}" run "${TUNNEL_NAME}"
