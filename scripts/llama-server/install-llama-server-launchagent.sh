#!/bin/bash
# install-llama-server-launchagent.sh — Install the macOS LaunchAgent and
# newsyslog rotation entry for the local PrismML llama-server.
#
# Prerequisites (host-local, kept out of this public repo):
#   Create ~/.config/magi-moomoo/llama-server.env (mode 600) with at least:
#     LLAMA_SERVER_BIN=/path/to/prism-llama/llama-server
#     LLAMA_MODEL_PATH=/path/to/Ternary-Bonsai-2.5-27B-PTQ1_0.gguf
#     LLAMA_PORT=<local-loopback-port>
#   Optional overrides (defaults shown):
#     LLAMA_HOST=127.0.0.1
#     LLAMA_CTX_SIZE=32768
#     LLAMA_PARALLEL=1
#     LLAMA_CACHE_TYPE_K=q8_0
#     LLAMA_CACHE_TYPE_V=q8_0
#     LLAMA_TEMP=1.0
#     LLAMA_TOP_P=0.95
#     LLAMA_TOP_K=20
#     LLAMA_MIN_P=0
#     LLAMA_REASONING_EFFORT=medium
#     LLAMA_REASONING_BUDGET=2048
#
# Usage:
#   bash scripts/llama-server/install-llama-server-launchagent.sh

set -e

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${LLAMA_SERVER_ENV_FILE:-$HOME/.config/magi-moomoo/llama-server.env}"
PLIST_NAME="com.magi.llama-server"
PLIST_SRC="${REPO_DIR}/scripts/llama-server/${PLIST_NAME}.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"
NEWSYSLOG_SRC="${REPO_DIR}/scripts/llama-server/magi-llama-server.newsyslog.conf"
NEWSYSLOG_DST="/etc/newsyslog.d/magi-llama-server.conf"

if [ ! -f "$ENV_FILE" ]; then
  echo "[ERROR] ${ENV_FILE} not found."
  echo "Create it with mode 600 (LLAMA_SERVER_BIN, LLAMA_MODEL_PATH, LLAMA_PORT) before installing."
  exit 1
fi

chmod +x "${REPO_DIR}/scripts/llama-server/start-llama-server.sh"

# --- 1. newsyslog rotation (system dir needs root) ----------------------------
mkdir -p "${HOME}/Library/Logs"
NEWSYSLOG_RENDERED="${HOME}/Library/Logs/magi-llama-server.newsyslog.rendered"
sed -e "s|@HOME@|${HOME}|g" -e "s|@USER@|$(id -un)|g" "$NEWSYSLOG_SRC" > "$NEWSYSLOG_RENDERED"
if sudo -n install -m 644 "$NEWSYSLOG_RENDERED" "$NEWSYSLOG_DST" 2>/dev/null; then
  echo "[install-llama-server] installed ${NEWSYSLOG_DST}"
else
  echo "[install-llama-server] newsyslog entry NOT installed (needs sudo):"
  echo "    sudo install -m 644 '${NEWSYSLOG_RENDERED}' '${NEWSYSLOG_DST}'"
fi

# --- 2. LaunchAgent -----------------------------------------------------------
mkdir -p "${HOME}/Library/LaunchAgents"
sed -e "s|@HOME@|${HOME}|g" -e "s|@REPO_DIR@|${REPO_DIR}|g" "$PLIST_SRC" > "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "[install-llama-server] loaded ${PLIST_DST}"
echo "[install-llama-server] done. Verify: launchctl print gui/$(id -u)/${PLIST_NAME}"
