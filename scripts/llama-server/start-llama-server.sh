#!/bin/bash
# start-llama-server.sh — LaunchAgent entry point for a local PrismML llama-server
# (e.g. Ternary Bonsai 2.5 27B) on the host.
#
# Reads host-local configuration (binary path, external-SSD model path, bind/port,
# context/KV/sampling overrides) from ~/.config/magi-moomoo/llama-server.env
# (mode 600). Host-specific paths and ports stay out of this public repo.
#
# Missing config, binary, or unmounted model file exits 0 on purpose: launchd
# KeepAlive{SuccessfulExit=false} treats exit 0 as a clean stop and avoids a
# restart loop when the external SSD is unmounted or setup is incomplete.
#
# Writes its PID to ~/Library/Logs/magi-llama-server.pid so newsyslog can
# SIGTERM the server after rotating the log (KeepAlive restarts it so the new
# process reopens the fresh log file).

set -u

ENV_FILE="${LLAMA_SERVER_ENV_FILE:-$HOME/.config/magi-moomoo/llama-server.env}"
PID_FILE="${LLAMA_SERVER_PID_FILE:-$HOME/Library/Logs/magi-llama-server.pid}"

if [ ! -f "$ENV_FILE" ]; then
  echo "[start-llama-server] $ENV_FILE missing; see scripts/llama-server/install-llama-server-launchagent.sh"
  exit 0
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-}"
LLAMA_MODEL_PATH="${LLAMA_MODEL_PATH:-}"
LLAMA_HOST="${LLAMA_HOST:-127.0.0.1}"
LLAMA_PORT="${LLAMA_PORT:-}"

missing=0
[ -n "$LLAMA_SERVER_BIN" ] || { echo "[start-llama-server] LLAMA_SERVER_BIN unset"; missing=1; }
[ -n "$LLAMA_MODEL_PATH" ] || { echo "[start-llama-server] LLAMA_MODEL_PATH unset"; missing=1; }
[ -n "$LLAMA_PORT" ] || { echo "[start-llama-server] LLAMA_PORT unset"; missing=1; }
[ "$missing" -eq 0 ] || exit 0

if [ ! -x "$LLAMA_SERVER_BIN" ]; then
  echo "[start-llama-server] binary not executable: $LLAMA_SERVER_BIN"
  exit 0
fi

if [ ! -f "$LLAMA_MODEL_PATH" ]; then
  echo "[start-llama-server] model file not found (external volume unmounted?): $LLAMA_MODEL_PATH"
  exit 0
fi

# Never bind non-loopback unless explicitly opted in.
case "$LLAMA_HOST" in
  127.0.0.1|localhost|::1) ;;
  *)
    if [ "${LLAMA_ALLOW_NON_LOOPBACK:-0}" != "1" ]; then
      echo "[start-llama-server] refusing non-loopback LLAMA_HOST=$LLAMA_HOST without LLAMA_ALLOW_NON_LOOPBACK=1"
      exit 0
    fi
    ;;
esac

ARGS=(
  -m "$LLAMA_MODEL_PATH"
  --host "$LLAMA_HOST"
  --port "$LLAMA_PORT"
  -ngl "${LLAMA_NGL:-99}"
  -fa "${LLAMA_FLASH_ATTN:-on}"
  --jinja
  -np "${LLAMA_PARALLEL:-1}"
  -c "${LLAMA_CTX_SIZE:-32768}"
  --cache-type-k "${LLAMA_CACHE_TYPE_K:-q8_0}"
  --cache-type-v "${LLAMA_CACHE_TYPE_V:-q8_0}"
  --temp "${LLAMA_TEMP:-1.0}"
  --top-p "${LLAMA_TOP_P:-0.95}"
  --top-k "${LLAMA_TOP_K:-20}"
  --min-p "${LLAMA_MIN_P:-0}"
  --no-webui
)

if [ -n "${LLAMA_CHAT_TEMPLATE_KWARGS:-}" ]; then
  ARGS+=(--chat-template-kwargs "$LLAMA_CHAT_TEMPLATE_KWARGS")
elif [ -n "${LLAMA_REASONING_EFFORT:-}" ]; then
  ARGS+=(--chat-template-kwargs "{\"reasoning_effort\":\"${LLAMA_REASONING_EFFORT}\"}")
fi

if [ -n "${LLAMA_REASONING_BUDGET:-}" ]; then
  ARGS+=(--reasoning-budget "$LLAMA_REASONING_BUDGET")
fi

if [ -n "${LLAMA_EXTRA_ARGS:-}" ]; then
  read -r -a EXTRA_ARR <<< "$LLAMA_EXTRA_ARGS"
  ARGS+=("${EXTRA_ARR[@]}")
fi

mkdir -p "$(dirname "$PID_FILE")"
echo $$ > "$PID_FILE"
exec "$LLAMA_SERVER_BIN" "${ARGS[@]}"
