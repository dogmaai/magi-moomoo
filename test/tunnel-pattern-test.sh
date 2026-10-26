#!/bin/bash
# tunnel-pattern-test.sh — unit tests for scripts/lib/tunnel-pattern.sh and
# its three call sites (start-bridge-daemon.sh check/restart, start-bridge.sh
# "already running" check, start-bridge.sh stale quick-tunnel cleanup).
#
# Verifies:
#   1. the spawn command lines in start-bridge.sh match the shared patterns
#   2. all three call sites use the shared helper (no private pgrep patterns)
#   3. a decoy process (`tail`) and a similarly named tunnel (`<name>-yml`)
#      are rejected, so both the daemon and the launcher say "stopped"
#
# Usage: bash test/tunnel-pattern-test.sh

set -u
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=../scripts/lib/tunnel-pattern.sh
. scripts/lib/tunnel-pattern.sh

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
# expect <1|0> <label> <pattern> <cmdline>
expect() {
  local exp=$1 label=$2 pat=$3 cmd=$4 got
  if printf '%s\n' "$cmd" | grep -Eq "$pat"; then got=1; else got=0; fi
  [ "$got" = "$exp" ] && ok "$label" || bad "$label (got=$got exp=$exp)"
}

# A unique, non-existent tunnel name so §4 stays at zero matches even on a
# host where the real bridge tunnel is running. Port likewise non-default.
NAME="tp-test-$$"
PORT=19436
NAMED=$(named_tunnel_pattern "$NAME")
QUICK=$(quick_tunnel_pattern "$PORT")

echo "== 1. spawn forms in start-bridge.sh match the shared patterns =="
# Named: cloudflared tunnel --config "${HOME}/.cloudflared/config-${CLOUDFLARE_TUNNEL_NAME}.yml" run "${CLOUDFLARE_TUNNEL_NAME}"
spawn_named_src=$(grep -E '^\s*cloudflared tunnel --config .*config-\$\{CLOUDFLARE_TUNNEL_NAME\}\.yml" run "\$\{CLOUDFLARE_TUNNEL_NAME\}"' scripts/start-bridge.sh | head -1)
[ -n "$spawn_named_src" ] && ok "named spawn line present in start-bridge.sh" || bad "named spawn line not found in start-bridge.sh"
# Render the spawn exactly as the shell would (expand the two variables, drop quotes/redirect).
spawn_named=$(HOME=/home/u CLOUDFLARE_TUNNEL_NAME=$NAME eval "echo ${spawn_named_src%%>*}" | sed 's/[[:space:]]*$//')
expect 1 "rendered named spawn: $spawn_named" "$NAMED" "$spawn_named"

# Quick: cloudflared tunnel --url "http://localhost:${BRIDGE_PORT}"
spawn_quick_src=$(grep -E '^\s*cloudflared tunnel --url "http://localhost:\$\{BRIDGE_PORT\}"' scripts/start-bridge.sh | head -1)
[ -n "$spawn_quick_src" ] && ok "quick spawn line present in start-bridge.sh" || bad "quick spawn line not found in start-bridge.sh"
spawn_quick=$(BRIDGE_PORT=$PORT eval "echo ${spawn_quick_src%%>*}" | sed 's/[[:space:]]*$//')
expect 1 "rendered quick spawn: $spawn_quick" "$QUICK" "$spawn_quick"

echo "== 2. the three call sites use the shared helper =="
grep -q 'pgrep -f "\$(named_tunnel_pattern "\${CLOUDFLARE_TUNNEL_NAME}")"' scripts/start-bridge.sh \
  && ok "start-bridge.sh already-running check uses named_tunnel_pattern" \
  || bad "start-bridge.sh already-running check does not use named_tunnel_pattern"
grep -q 'pgrep -f "\$(quick_tunnel_pattern "\${BRIDGE_PORT}")"' scripts/start-bridge.sh \
  && ok "start-bridge.sh stale quick-tunnel cleanup uses quick_tunnel_pattern" \
  || bad "start-bridge.sh stale quick-tunnel cleanup does not use quick_tunnel_pattern"
[ "$(grep -c 'pgrep -f "\$(tunnel_pattern)"' scripts/start-bridge-daemon.sh)" -eq 2 ] \
  && ok "daemon check_bridge_alive + restart_bridge both use tunnel_pattern" \
  || bad "daemon call sites using tunnel_pattern != 2"
grep -q 'bridge_tunnel_pattern "\${CLOUDFLARE_TUNNEL_NAME:-}" "\${BRIDGE_PORT}"' scripts/start-bridge-daemon.sh \
  && ok "daemon tunnel_pattern delegates to bridge_tunnel_pattern" \
  || bad "daemon tunnel_pattern does not delegate to bridge_tunnel_pattern"
# No leftover ad-hoc cloudflared pgrep patterns in either script
if grep -nE 'pgrep[^"]*"cloudflared' scripts/start-bridge.sh scripts/start-bridge-daemon.sh; then
  bad "ad-hoc cloudflared pgrep pattern remains"
else
  ok "no ad-hoc cloudflared pgrep patterns remain"
fi

echo "== 3. decoys and similar names are rejected (daemon and launcher agree) =="
expect 1 "real named tunnel"                    "$NAMED" "cloudflared tunnel --config /home/u/.cloudflared/config-$NAME.yml run $NAME"
expect 1 "absolute binary path"                 "$NAMED" "/opt/homebrew/bin/cloudflared tunnel --config /home/u/.cloudflared/config-$NAME.yml run $NAME"
expect 0 "sibling tunnel (other name)"          "$NAMED" "cloudflared tunnel --config /home/u/.cloudflared/config-other.yml run other"
expect 0 "similar name <name>-yml"              "$NAMED" "cloudflared tunnel --config /home/u/.cloudflared/config-$NAME-yml.yml run $NAME-yml"
expect 0 "dot wildcard abuse"                   "$NAMED" "cloudflared tunnel --config /home/u/.cloudflared/config-${NAME}Xyml run $NAME"
expect 0 "decoy: tail of a log with the text"   "$NAMED" "tail -f /tmp/cloudflared tunnel --config /x/config-$NAME.yml run $NAME.log"
expect 0 "decoy: grep with the text"            "$NAMED" "grep -f cloudflared tunnel --config /x/config-$NAME.yml run $NAME"
expect 0 "quick tunnel does not satisfy named"  "$NAMED" "cloudflared tunnel --url http://localhost:$PORT"

expect 1 "real quick tunnel"                    "$QUICK" "cloudflared tunnel --url http://localhost:$PORT"
expect 0 "quick tunnel on another port"         "$QUICK" "cloudflared tunnel --url http://localhost:$((PORT+1))"
expect 0 "named tunnel does not satisfy quick"  "$QUICK" "cloudflared tunnel --config /x/config-other.yml run other"
expect 0 "decoy: grep with quick text"          "$QUICK" "grep cloudflared tunnel --url http://localhost:$PORT"

# bridge_tunnel_pattern dispatch
[ "$(bridge_tunnel_pattern "$NAME" "$PORT")" = "$NAMED" ] && ok "bridge_tunnel_pattern(name) -> named" || bad "bridge_tunnel_pattern(name) != named"
[ "$(bridge_tunnel_pattern ""      "$PORT")" = "$QUICK" ] && ok "bridge_tunnel_pattern('') -> quick"   || bad "bridge_tunnel_pattern('') != quick"

# Regex metacharacters in a name are literal
DOT=$(named_tunnel_pattern "a.b")
expect 1 "escaped dot matches literal"          "$DOT" "cloudflared tunnel --config /x/config-a.b.yml run a.b"
expect 0 "escaped dot rejects aXb"              "$DOT" "cloudflared tunnel --config /x/config-aXb.yml run aXb"

echo "== 4. live pgrep semantics: decoy + similar-name processes do not mask a stopped tunnel =="
# Spawn harmless decoys whose argv contains the pattern text, then confirm pgrep
# with the shared pattern finds none of them (the real tunnel is not running here).
DECOY_LOG="$(mktemp -d)/cloudflared tunnel --config x config-$NAME.yml run $NAME.log"
: > "$DECOY_LOG"
tail -f "$DECOY_LOG" >/dev/null 2>&1 &
D1=$!
bash -c "exec -a 'cloudflared tunnel --config /x/config-$NAME-yml.yml run $NAME-yml' sleep 30" &
D2=$!
sleep 0.5
kill -0 "$D1" "$D2" 2>/dev/null && ok "decoy processes are running (tail + <name>-yml)" || bad "decoy processes failed to start"
if pgrep -f "$NAMED" >/dev/null 2>&1; then
  bad "pgrep matched a decoy / similar-name process: $(pgrep -fl "$NAMED")"
else
  ok "pgrep with shared pattern ignores decoy and <name>-yml processes"
fi
# Sanity: the decoys ARE visible to the old, unanchored style of pattern
pgrep -f "cloudflared.*config-$NAME.yml.*run" >/dev/null 2>&1 \
  && ok "control: the pre-fix unanchored pattern would have matched the decoys" \
  || bad "control: unanchored pattern unexpectedly matched nothing"
kill "$D1" "$D2" 2>/dev/null; wait "$D1" "$D2" 2>/dev/null
rm -rf "$(dirname "$DECOY_LOG")"

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
