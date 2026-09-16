#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PROXY_PORT=8080
BRIDGE_PORT=9001
BRIDGE_LOG=/tmp/fake-bridge.log
PROXY_LOG=/tmp/proxy-test.log
RESULTS=/tmp/proxy-test-results.txt
TOKEN_FILE=/tmp/fake-bridge-auth-token

cleanup() {
  set +e
  [ -n "${BRIDGE_PID:-}" ] && kill "$BRIDGE_PID" 2>/dev/null
  [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null
  fuser -k "$PROXY_PORT"/tcp 2>/dev/null
  fuser -k "$BRIDGE_PORT"/tcp 2>/dev/null
  rm -f "$TOKEN_FILE"
}
trap cleanup EXIT

rm -f "$BRIDGE_LOG" "$PROXY_LOG" "$RESULTS" "$TOKEN_FILE"
: > "$RESULTS"

echo "=== Starting fake bridge on port $BRIDGE_PORT ===" | tee -a "$RESULTS"
FAKE_BRIDGE_PORT=$BRIDGE_PORT FAKE_BRIDGE_LOG=$BRIDGE_LOG node test/fake-bridge.mjs &
BRIDGE_PID=$!

for i in {1..30}; do
  if curl -fsS "http://localhost:$BRIDGE_PORT/live/health" >/dev/null 2>&1; then
    echo "Fake bridge ready" | tee -a "$RESULTS"
    break
  fi
  sleep 0.2
done

wait_for_proxy() {
  for i in {1..30}; do
    if curl -fsS "http://localhost:$PROXY_PORT/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  echo "Proxy failed to start" | tee -a "$RESULTS" >&2
  cat "$PROXY_LOG" | tail -40 | tee -a "$RESULTS" >&2
  return 1
}

run_proxy() {
  local bq_urls=$1
  local log_file=$2
  rm -f "$log_file"
  TEST_BQ_URLS="$bq_urls" node --import ./test/register.mjs bootstrap.js >"$log_file" 2>&1 &
  PROXY_PID=$!
  wait_for_proxy
}

stop_proxy() {
  set +e
  if [ -n "${PROXY_PID:-}" ]; then
    kill "$PROXY_PID" 2>/dev/null
    wait "$PROXY_PID" 2>/dev/null
  fi
  fuser -k "$PROXY_PORT"/tcp 2>/dev/null
  PROXY_PID=""
  set -e
}

# Reset fake bridge request counters before each proxy test.
reset_bridge() {
  curl -fsS -X POST "http://localhost:$BRIDGE_PORT/reset" >/dev/null 2>&1 || true
}

json_value() {
  python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"
}

# ---------------------------------------------------------------
# Test 1: Cached GETs do not re-query BigQuery (cache persists)
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 1: Cached GETs use cache and do not call BigQuery on every request ===" | tee -a "$RESULTS"
run_proxy "http://localhost:$BRIDGE_PORT/live,http://localhost:1/should-not-be-called" "$PROXY_LOG"
reset_bridge

echo "First GET /trade/positions" | tee -a "$RESULTS"
RESP1=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
STATUS1=$(echo "$RESP1" | tail -1 | sed 's/HTTP_STATUS://')
BODY1=$(echo "$RESP1" | sed '$d')
echo "status=$STATUS1 body=$BODY1" | tee -a "$RESULTS"

echo "Second GET /trade/quote?symbol=AAPL (should use cache)" | tee -a "$RESULTS"
RESP2=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/quote?symbol=AAPL")
STATUS2=$(echo "$RESP2" | tail -1 | sed 's/HTTP_STATUS://')
BODY2=$(echo "$RESP2" | sed '$d')
echo "status=$STATUS2 body=$BODY2" | tee -a "$RESULTS"

BQ_CALLS=$(grep -c '\[BQ MOCK\] query' "$PROXY_LOG" || true)
echo "BigQuery mock calls in proxy log: $BQ_CALLS" | tee -a "$RESULTS"

echo "--- proxy log ---" | tee -a "$RESULTS"
cat "$PROXY_LOG" | tee -a "$RESULTS" >/dev/null || true

if [ "$STATUS1" = "200" ] && [ "$STATUS2" = "200" ] && [ "$BQ_CALLS" = "1" ]; then
  echo "TEST 1: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 1: FAILED" | tee -a "$RESULTS"
fi
stop_proxy

# ---------------------------------------------------------------
# Test 2: Stale dead bridge URL triggers BQ refresh and GET retry
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 2: Stale/dead bridge URL refreshes from BigQuery and GET retries once ===" | tee -a "$RESULTS"
run_proxy "http://localhost:$BRIDGE_PORT/dead,http://localhost:$BRIDGE_PORT/live" "$PROXY_LOG"
reset_bridge

echo "GET /trade/positions (expect transparent retry -> 200)" | tee -a "$RESULTS"
RESP3=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
STATUS3=$(echo "$RESP3" | tail -1 | sed 's/HTTP_STATUS://')
BODY3=$(echo "$RESP3" | sed '$d')
echo "status=$STATUS3 body=$BODY3" | tee -a "$RESULTS"

BQ_CALLS=$(grep -c '\[BQ MOCK\] query' "$PROXY_LOG" || true)
RETRY_MSG=$(grep -c 're-selecting route and retrying' "$PROXY_LOG" || true)
echo "BigQuery mock calls: $BQ_CALLS, retry log messages: $RETRY_MSG" | tee -a "$RESULTS"

echo "--- proxy log ---" | tee -a "$RESULTS"
cat "$PROXY_LOG" | tee -a "$RESULTS" >/dev/null || true

if [ "$STATUS3" = "200" ] && [ "$BQ_CALLS" = "2" ] && [ "$RETRY_MSG" -ge "1" ]; then
  echo "TEST 2: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 2: FAILED" | tee -a "$RESULTS"
fi
stop_proxy

# ---------------------------------------------------------------
# Test 3: POST /trade/place_order does NOT retry on 5xx
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 3: POST /trade/place_order does NOT retry and does not duplicate ===" | tee -a "$RESULTS"
# Single dead bridge URL: every bridge call (positions lookup + place_order)
# hits the dead side. The approval token lets the order through the gate so
# the POST itself is what we exercise.
run_proxy "http://localhost:$BRIDGE_PORT/dead" "$PROXY_LOG"
reset_bridge

LIVE_BEFORE_TOTAL=$(curl -sS "http://localhost:$BRIDGE_PORT/counts/live" | json_value total)
LIVE_BEFORE_POST=$(curl -sS "http://localhost:$BRIDGE_PORT/counts/live" | json_value post)
echo "Live bridge counts before: total=$LIVE_BEFORE_TOTAL post=$LIVE_BEFORE_POST" | tee -a "$RESULTS"

echo "POST /trade/place_order (expect 503, no live POST observed)" | tee -a "$RESULTS"
RESP4=$(curl -sS -X POST -H 'Content-Type: application/json' -d '{"symbol":"AAPL","side":"BUY","qty":1,"order_type":"MARKET","approval_token":"TEST-APPROVAL"}' -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/place_order")
STATUS4=$(echo "$RESP4" | tail -1 | sed 's/HTTP_STATUS://')
BODY4=$(echo "$RESP4" | sed '$d')
echo "status=$STATUS4 body=$BODY4" | tee -a "$RESULTS"

LIVE_AFTER_TOTAL=$(curl -sS "http://localhost:$BRIDGE_PORT/counts/live" | json_value total)
LIVE_AFTER_POST=$(curl -sS "http://localhost:$BRIDGE_PORT/counts/live" | json_value post)
BQ_CALLS=$(grep -c '\[BQ MOCK\] query' "$PROXY_LOG" || true)
echo "Live bridge counts after: total=$LIVE_AFTER_TOTAL post=$LIVE_AFTER_POST" | tee -a "$RESULTS"
echo "BigQuery calls=$BQ_CALLS" | tee -a "$RESULTS"

echo "--- proxy log ---" | tee -a "$RESULTS"
cat "$PROXY_LOG" | tee -a "$RESULTS" >/dev/null || true

if [ "$STATUS4" = "503" ] && [ "$LIVE_AFTER_TOTAL" = "$LIVE_BEFORE_TOTAL" ] && [ "$LIVE_AFTER_POST" = "$LIVE_BEFORE_POST" ]; then
  echo "TEST 3: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 3: FAILED" | tee -a "$RESULTS"
fi
stop_proxy

# ---------------------------------------------------------------
# Test 4: Genuinely unreachable bridge returns 503 with helpful message
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 4: Genuinely unreachable bridge returns 503 ===" | tee -a "$RESULTS"
run_proxy "http://localhost:2" "$PROXY_LOG"
reset_bridge

echo "GET /trade/positions (expect 503)" | tee -a "$RESULTS"
RESP5=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
STATUS5=$(echo "$RESP5" | tail -1 | sed 's/HTTP_STATUS://')
BODY5=$(echo "$RESP5" | sed '$d')
echo "status=$STATUS5 body=$BODY5" | tee -a "$RESULTS"

BQ_CALLS=$(grep -c '\[BQ MOCK\] query' "$PROXY_LOG" || true)
echo "BigQuery mock calls: $BQ_CALLS" | tee -a "$RESULTS"

echo "--- proxy log ---" | tee -a "$RESULTS"
cat "$PROXY_LOG" | tee -a "$RESULTS" >/dev/null || true

if [ "$STATUS5" = "503" ] && [ "$BQ_CALLS" = "2" ] && echo "$BODY5" | grep -q 'moomoo-bridge unreachable'; then
  echo "TEST 4: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 4: FAILED" | tee -a "$RESULTS"
fi
stop_proxy

# ---------------------------------------------------------------
# Test 5: Slow response body reading triggers the 10s timeout
# (verifies AbortController timeout stays armed through body read)
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 5: 10s timeout fires while reading a slow response body ===" | tee -a "$RESULTS"
run_proxy "http://localhost:$BRIDGE_PORT/slow" "$PROXY_LOG"
reset_bridge

START=$(date +%s)
echo "GET /trade/positions to slow bridge (expect 503 within ~10s, not 200 after 15s)" | tee -a "$RESULTS"
RESP6=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" -m 20 "http://localhost:$PROXY_PORT/trade/positions")
END=$(date +%s)
ELAPSED=$((END - START))
STATUS6=$(echo "$RESP6" | tail -1 | sed 's/HTTP_STATUS://')
BODY6=$(echo "$RESP6" | sed '$d')
echo "status=$STATUS6 elapsed=${ELAPSED}s body=$BODY6" | tee -a "$RESULTS"

BQ_CALLS=$(grep -c '\[BQ MOCK\] query' "$PROXY_LOG" || true)
TIMEOUT_MSG=$(grep -c 'moomoo-bridge timeout' "$PROXY_LOG" || true)
echo "BigQuery mock calls: $BQ_CALLS, timeout log messages: $TIMEOUT_MSG" | tee -a "$RESULTS"

echo "--- proxy log ---" | tee -a "$RESULTS"
cat "$PROXY_LOG" | tee -a "$RESULTS" >/dev/null || true

if [ "$STATUS6" = "503" ] && [ "$ELAPSED" -ge "8" ] && [ "$ELAPSED" -le "13" ] && [ "$BQ_CALLS" = "1" ] && [ "$TIMEOUT_MSG" -ge "1" ]; then
  echo "TEST 5: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 5: FAILED" | tee -a "$RESULTS"
fi
stop_proxy

# ---------------------------------------------------------------
# Test 6: proxy forwards BRIDGE_AUTH_TOKEN to the bridge
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 6: proxy forwards bearer token; unauthenticated bridge call rejected ===" | tee -a "$RESULTS"
echo "test-token-$$" > "$TOKEN_FILE"
BRIDGE_AUTH_TOKEN="test-token-$$" run_proxy "http://localhost:$BRIDGE_PORT/live" "$PROXY_LOG"
reset_bridge

echo "GET /trade/positions via proxy (expect 200 with token)" | tee -a "$RESULTS"
RESP7=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
STATUS7=$(echo "$RESP7" | tail -1 | sed 's/HTTP_STATUS://')
BODY7=$(echo "$RESP7" | sed '$d')
echo "status=$STATUS7 body=$BODY7" | tee -a "$RESULTS"

echo "Direct GET /live/positions without token (expect 401)" | tee -a "$RESULTS"
STATUS8=$(curl -sS -o /dev/null -w "%{http_code}" "http://localhost:$BRIDGE_PORT/live/positions")
echo "status=$STATUS8" | tee -a "$RESULTS"

if [ "$STATUS7" = "200" ] && [ "$STATUS8" = "401" ]; then
  echo "TEST 6: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 6: FAILED" | tee -a "$RESULTS"
fi
stop_proxy
rm -f "$TOKEN_FILE"

# ---------------------------------------------------------------
# Test 7: order-gate unit tests (kill-switch states, approvals, sanity)
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 7: order-gate unit tests ===" | tee -a "$RESULTS"
if node --test test/order-gate.test.mjs > /tmp/order-gate-test.log 2>&1; then
  echo "TEST 7: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 7: FAILED" | tee -a "$RESULTS"
  cat /tmp/order-gate-test.log | tee -a "$RESULTS"
fi

# ---------------------------------------------------------------
# Test 8: legacy mode ignores BRIDGE_PRIVATE_URL (rollback state)
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 8: BRIDGE_ROUTE_MODE=legacy ignores BRIDGE_PRIVATE_URL ===" | tee -a "$RESULTS"
BRIDGE_PRIVATE_URL="http://localhost:3" BRIDGE_ROUTE_MODE=legacy run_proxy "http://localhost:$BRIDGE_PORT/live" "$PROXY_LOG"
reset_bridge

echo "GET /trade/positions (expect 200 via cloudflare route)" | tee -a "$RESULTS"
RESP8=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
STATUS8=$(echo "$RESP8" | tail -1 | sed 's/HTTP_STATUS://')

RS8=$(curl -sS "http://localhost:$PROXY_PORT/route_status")
echo "route_status=$RS8" | tee -a "$RESULTS"
BQ_CALLS=$(grep -c '\[BQ MOCK\] query' "$PROXY_LOG" || true)
PRIV_REQS=$(echo "$RS8" | python3 -c "import json,sys; print(json.load(sys.stdin)['routes']['private']['requests'])")
MODE8=$(echo "$RS8" | python3 -c "import json,sys; print(json.load(sys.stdin)['mode'])")

if [ "$STATUS8" = "200" ] && [ "$BQ_CALLS" = "1" ] && [ "$PRIV_REQS" = "0" ] && [ "$MODE8" = "legacy" ]; then
  echo "TEST 8: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 8: FAILED (status=$STATUS8 bq=$BQ_CALLS priv_reqs=$PRIV_REQS mode=$MODE8)" | tee -a "$RESULTS"
fi
stop_proxy

# ---------------------------------------------------------------
# Test 9: auto mode serves via private when healthy — BQ never queried
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 9: auto mode uses private route; BigQuery not queried ===" | tee -a "$RESULTS"
# TEST_BQ_URLS points at a dead URL — proves the private path never touches BQ.
BRIDGE_PRIVATE_URL="http://localhost:$BRIDGE_PORT/live" BRIDGE_ROUTE_MODE=auto run_proxy "http://localhost:4/dead" "$PROXY_LOG"
reset_bridge

echo "GET /trade/positions (expect 200 via private)" | tee -a "$RESULTS"
RESP9=$(curl -sS -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
STATUS9=$(echo "$RESP9" | tail -1 | sed 's/HTTP_STATUS://')

echo "POST /trade/place_order via gate (positions lookup also private)" | tee -a "$RESULTS"
RESP9B=$(curl -sS -X POST -H 'Content-Type: application/json' -d '{"symbol":"AAPL","side":"BUY","qty":1,"order_type":"MARKET","approval_token":"TEST-APPROVAL"}' -w "\nHTTP_STATUS:%{http_code}" "http://localhost:$PROXY_PORT/trade/place_order")
STATUS9B=$(echo "$RESP9B" | tail -1 | sed 's/HTTP_STATUS://')

RS9=$(curl -sS "http://localhost:$PROXY_PORT/route_status")
echo "route_status=$RS9" | tee -a "$RESULTS"
BQ_CALLS=$(grep -c '\[BQ MOCK\] query' "$PROXY_LOG" || true)
PRIV_REQS=$(echo "$RS9" | python3 -c "import json,sys; print(json.load(sys.stdin)['routes']['private']['requests'])")
CF_REQS=$(echo "$RS9" | python3 -c "import json,sys; print(json.load(sys.stdin)['routes']['cloudflare']['requests'])")
ACTIVE9=$(echo "$RS9" | python3 -c "import json,sys; print(json.load(sys.stdin)['active_route'])")
LIVE_POST=$(curl -sS "http://localhost:$BRIDGE_PORT/counts/live" | json_value post)

if [ "$STATUS9" = "200" ] && [ "$STATUS9B" = "200" ] && [ "$BQ_CALLS" = "0" ] && [ "$CF_REQS" = "0" ] && [ "$PRIV_REQS" -ge "2" ] && [ "$ACTIVE9" = "private" ] && [ "$LIVE_POST" = "1" ]; then
  echo "TEST 9: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 9: FAILED (s1=$STATUS9 s2=$STATUS9B bq=$BQ_CALLS cf=$CF_REQS priv=$PRIV_REQS active=$ACTIVE9 live_post=$LIVE_POST)" | tee -a "$RESULTS"
fi
stop_proxy

# ---------------------------------------------------------------
# Test 10: auto mode falls back to cloudflare after private failures
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 10: auto mode falls back to cloudflare when private is down ===" | tee -a "$RESULTS"
BRIDGE_PRIVATE_URL="http://localhost:3" BRIDGE_ROUTE_MODE=auto run_proxy "http://localhost:$BRIDGE_PORT/live" "$PROXY_LOG"
reset_bridge

echo "GET /trade/positions #1 (private dead: expect 503, marks route down)" | tee -a "$RESULTS"
STATUS10A=$(curl -sS -o /dev/null -w "%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
echo "status=$STATUS10A" | tee -a "$RESULTS"

echo "GET /trade/positions #2 (expect 200 via cloudflare fallback)" | tee -a "$RESULTS"
STATUS10B=$(curl -sS -o /dev/null -w "%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
echo "status=$STATUS10B" | tee -a "$RESULTS"

RS10=$(curl -sS "http://localhost:$PROXY_PORT/route_status")
echo "route_status=$RS10" | tee -a "$RESULTS"
PRIV_UP10=$(echo "$RS10" | python3 -c "import json,sys; print(json.load(sys.stdin)['private_health']['up'])")
FB10=$(echo "$RS10" | python3 -c "import json,sys; print(json.load(sys.stdin)['fallback_events'])")
CF_REQS=$(echo "$RS10" | python3 -c "import json,sys; print(json.load(sys.stdin)['routes']['cloudflare']['requests'])")
ROUTE_LOG=$(grep -c 'private->cloudflare fallback' "$PROXY_LOG" || true)

if [ "$STATUS10A" = "503" ] && [ "$STATUS10B" = "200" ] && [ "$PRIV_UP10" = "False" ] && [ "$FB10" -ge "1" ] && [ "$CF_REQS" -ge "1" ] && [ "$ROUTE_LOG" -ge "1" ]; then
  echo "TEST 10: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 10: FAILED (s1=$STATUS10A s2=$STATUS10B up=$PRIV_UP10 fb=$FB10 cf=$CF_REQS log=$ROUTE_LOG)" | tee -a "$RESULTS"
fi
stop_proxy

# ---------------------------------------------------------------
# Test 11: private mode is private-only — no cloudflare, no BQ
# ---------------------------------------------------------------
echo "" | tee -a "$RESULTS"
echo "=== TEST 11: BRIDGE_ROUTE_MODE=private never touches cloudflare/BQ ===" | tee -a "$RESULTS"
BRIDGE_PRIVATE_URL="http://localhost:$BRIDGE_PORT/live" BRIDGE_ROUTE_MODE=private run_proxy "http://localhost:5/dead" "$PROXY_LOG"
reset_bridge

STATUS11A=$(curl -sS -o /dev/null -w "%{http_code}" "http://localhost:$PROXY_PORT/trade/positions")
echo "GET positions via private (expect 200): status=$STATUS11A" | tee -a "$RESULTS"

RS11=$(curl -sS "http://localhost:$PROXY_PORT/route_status")
BQ_CALLS=$(grep -c '\[BQ MOCK\] query' "$PROXY_LOG" || true)
CF_REQS=$(echo "$RS11" | python3 -c "import json,sys; print(json.load(sys.stdin)['routes']['cloudflare']['requests'])")
ACTIVE11=$(echo "$RS11" | python3 -c "import json,sys; print(json.load(sys.stdin)['active_route'])")

if [ "$STATUS11A" = "200" ] && [ "$BQ_CALLS" = "0" ] && [ "$CF_REQS" = "0" ] && [ "$ACTIVE11" = "private" ]; then
  echo "TEST 11: PASSED" | tee -a "$RESULTS"
else
  echo "TEST 11: FAILED (s=$STATUS11A bq=$BQ_CALLS cf=$CF_REQS active=$ACTIVE11)" | tee -a "$RESULTS"
fi
stop_proxy

echo "" | tee -a "$RESULTS"
echo "=== TEST SUMMARY ===" | tee -a "$RESULTS"
grep -E 'TEST [0-9]+:' "$RESULTS" || true
echo "Results written to $RESULTS"
echo "Bridge log: $BRIDGE_LOG"
echo "Last proxy log: $PROXY_LOG"
