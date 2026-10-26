#!/bin/bash
# start-alloy.sh — LaunchAgent entry point for the TIALA Grafana Alloy agent.
#
# Runs the Homebrew-packaged alloy-wrapper, which sources
# /opt/homebrew/etc/alloy/config.env (a shim that pulls in
# ~/.config/magi-moomoo/alloy.env, mode 600) and then `alloy run`s
# /opt/homebrew/etc/alloy/config.alloy.
#
# Config problems exit 0 on purpose: launchd KeepAlive{SuccessfulExit=false}
# treats exit 0 as a clean stop and does NOT restart-loop, so a missing env
# file quietly leaves the agent down instead of thrashing. The companion
# alerts (Alloy metrics stale / disk usage) cover the "agent silently down"
# case — see magi-core's provisioning.
#
# Writes its own PID to ~/Library/Logs/magi-alloy.pid so newsyslog can
# SIGTERM the agent after rotating the log (KeepAlive restarts it and the
# new process reopens the fresh log file — see magi-alloy.newsyslog.conf).

set -u

ALLOY_WRAPPER="${ALLOY_WRAPPER:-/opt/homebrew/opt/alloy/bin/alloy-wrapper}"
ALLOY_ENV_FILE="${ALLOY_ENV_FILE:-$HOME/.config/magi-moomoo/alloy.env}"
CONFIG_ENV="/opt/homebrew/etc/alloy/config.env"
PID_FILE="${ALLOY_PID_FILE:-$HOME/Library/Logs/magi-alloy.pid}"

if [ ! -x "$ALLOY_WRAPPER" ]; then
	echo "[start-alloy] $ALLOY_WRAPPER not found; run scripts/install-alloy-launchagent.sh (brew tap grafana/grafana && brew install grafana/grafana/alloy)"
	exit 0
fi

missing=0
[ -f "$CONFIG_ENV" ] || { echo "[start-alloy] $CONFIG_ENV missing"; missing=1; }
[ -f "$ALLOY_ENV_FILE" ] || { echo "[start-alloy] $ALLOY_ENV_FILE missing"; missing=1; }
[ "$missing" -eq 0 ] || exit 0

echo $$ > "$PID_FILE"
exec "$ALLOY_WRAPPER"
