#!/bin/bash
# tunnel-pattern.sh — shared pgrep patterns for the bridge's own cloudflared
# tunnel. Sourced by start-bridge.sh and start-bridge-daemon.sh so the
# process that start-bridge.sh spawns and the processes the watchdog /
# launcher look for are always the same definition.
#
# Both patterns are anchored to the exact command line that start-bridge.sh
# spawns, and regex metacharacters in the tunnel name are escaped, so that
#   - a sibling tunnel whose name merely *contains* this one (e.g.
#     `<name>-yml`) is never matched (and never killed)
#   - unrelated processes whose arguments contain the pattern text
#     (`tail`, `grep`, editors) cannot mask a dead tunnel
#
# If the spawn form in start-bridge.sh changes, update these together and
# re-run test/tunnel-pattern-test.sh.
#
# Usage:
#   source "$(dirname "$0")/lib/tunnel-pattern.sh"
#   pgrep -f "$(named_tunnel_pattern "$CLOUDFLARE_TUNNEL_NAME")"
#   pgrep -f "$(quick_tunnel_pattern "$BRIDGE_PORT")"
#   pgrep -f "$(bridge_tunnel_pattern "$CLOUDFLARE_TUNNEL_NAME" "$BRIDGE_PORT")"

# Escape ERE metacharacters so a tunnel name is matched literally.
_tunnel_regex_escape() {
  printf '%s' "$1" | sed 's/[][\.*^$+?(){}|\\]/\\&/g'
}

# Pattern for a named tunnel spawned as:
#   cloudflared tunnel --config <dir>/config-<name>.yml run <name>
named_tunnel_pattern() {
  local name
  name=$(_tunnel_regex_escape "$1")
  echo "^[^ ]*cloudflared tunnel --config [^ ]*/config-${name}\\.yml run ${name}\$"
}

# Pattern for a quick tunnel spawned as:
#   cloudflared tunnel --url http://localhost:<port>
quick_tunnel_pattern() {
  local port=$1
  echo "^[^ ]*cloudflared tunnel --url [^ ]*:${port}\$"
}

# Pattern for whichever tunnel this bridge is configured to use:
# named when a tunnel name is given, otherwise the quick tunnel on <port>.
bridge_tunnel_pattern() {
  local name=$1 port=$2
  if [ -n "${name}" ]; then
    named_tunnel_pattern "${name}"
  else
    quick_tunnel_pattern "${port}"
  fi
}
