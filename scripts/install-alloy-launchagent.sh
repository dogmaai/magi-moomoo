#!/bin/bash
# install-alloy-launchagent.sh — Install the TIALA Grafana Alloy host-metrics
# agent (prometheus.exporter.unix -> grafanacloud-aka-prom, magi-core#667).
#
# What it does:
#   1. brew tap grafana/grafana && brew install grafana/grafana/alloy && brew pin alloy
#   2. Fetch GRAFANA_ALLOY_REMOTE_WRITE_TOKEN from GCP Secret Manager
#   3. Write ~/.config/magi-moomoo/alloy.env (mode 600) — the credential file
#   4. Install /opt/homebrew/etc/alloy/{config.alloy,config.env} for the brew
#      wrapper (config.env is a shim that sources alloy.env)
#   5. Install the newsyslog rotation entry (needs sudo; prints the command
#      if sudo -n is unavailable)
#   6. Install + load ~/Library/LaunchAgents/com.magi.alloy.plist
#
# Usage:
#   bash scripts/install-alloy-launchagent.sh <hosted-metrics-instance-id>
#
# <hosted-metrics-instance-id> is the Prometheus "Instance ID" shown in
# Grafana Cloud Portal -> aka -> Prometheus -> Details. It is NOT the stack
# ID (1557976) — the stack ID is rejected with "invalid authentication
# credentials" (see secrets-inventory.md).

set -e

INSTANCE_ID="${1:-}"
PROJECT_ID="${GCP_PROJECT:-screen-share-459802}"
TOKEN_SECRET="GRAFANA_ALLOY_REMOTE_WRITE_TOKEN"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="${HOME}/.config/magi-moomoo"
ENV_FILE="${ENV_DIR}/alloy.env"
ALLOY_ETC="/opt/homebrew/etc/alloy"
PLIST_NAME="com.magi.alloy"
PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"
NEWSYSLOG_SRC="${REPO_DIR}/scripts/alloy/magi-alloy.newsyslog.conf"
NEWSYSLOG_DST="/etc/newsyslog.d/magi-alloy.conf"

if [ -z "$INSTANCE_ID" ]; then
  echo "Usage: bash scripts/install-alloy-launchagent.sh <hosted-metrics-instance-id>"
  exit 1
fi
case "$INSTANCE_ID" in
  *[!0-9]*) echo "[ERROR] instance ID must be digits only (got: $INSTANCE_ID)"; exit 1 ;;
esac

# --- 1. Homebrew (official grafana/grafana tap; 'brew install alloy' from the
#        default tap is a different tool — the Alloy modelling language) -------
command -v brew >/dev/null 2>&1 || { echo "[ERROR] brew not found"; exit 1; }
brew tap grafana/grafana
brew install grafana/grafana/alloy
brew pin alloy

# --- 2. Token from GSM (same ADC/SA-key convention as install-openclaw) ------
DEFAULT_SA_KEY="${HOME}/.config/gcloud/service-account-key.json"
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS}" ] && [ -f "${DEFAULT_SA_KEY}" ]; then
  export GOOGLE_APPLICATION_CREDENTIALS="${DEFAULT_SA_KEY}"
fi
command -v gcloud >/dev/null 2>&1 || { echo "[ERROR] gcloud not found"; exit 1; }

echo "[install-alloy] fetching ${TOKEN_SECRET} from GSM (${PROJECT_ID})"
TOKEN="$(gcloud secrets versions access latest --secret="${TOKEN_SECRET}" --project="${PROJECT_ID}")"
[ -n "$TOKEN" ] || { echo "[ERROR] empty token"; exit 1; }

# --- 3. Credential env file (mode 600) ---------------------------------------
umask 077
mkdir -p "$ENV_DIR"
cat > "$ENV_FILE" <<EOF
GRAFANA_ALLOY_REMOTE_WRITE_TOKEN=${TOKEN}
GRAFANA_PROM_REMOTE_WRITE_USER=${INSTANCE_ID}
EOF
echo "[install-alloy] wrote ${ENV_FILE} (mode 600)"

# --- 4. Brew-wrapper config: shim + alloy config ------------------------------
mkdir -p "$ALLOY_ETC"
# config.env must resolve the env file regardless of launchd HOME quirks.
cat > "$ALLOY_ETC/config.env" <<EOF
# Sourced by /opt/homebrew/opt/alloy/bin/alloy-wrapper (set -a).
# Real values live in ${ENV_FILE} (mode 600) per TIALA conventions.
. "${ENV_FILE}"
EOF
chmod 600 "$ALLOY_ETC/config.env"
cp "${REPO_DIR}/scripts/alloy/config.alloy" "$ALLOY_ETC/config.alloy"
echo "[install-alloy] installed ${ALLOY_ETC}/config.env + config.alloy"

# --- 5. newsyslog rotation (system dir needs root) ----------------------------
if sudo -n install -m 644 "$NEWSYSLOG_SRC" "$NEWSYSLOG_DST" 2>/dev/null; then
  echo "[install-alloy] installed ${NEWSYSLOG_DST}"
else
  echo "[install-alloy] newsyslog entry NOT installed (needs sudo):"
  echo "    sudo install -m 644 '${NEWSYSLOG_SRC}' '${NEWSYSLOG_DST}'"
fi

# --- 6. LaunchAgent -----------------------------------------------------------
mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"
cp "${REPO_DIR}/scripts/${PLIST_NAME}.plist" "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "[install-alloy] loaded ${PLIST_DST}"
echo "[install-alloy] done. Verify: launchctl print gui/$(id -u)/${PLIST_NAME}"
