---
name: testing-moomoo-bridge
description: Test the MooMoo bridge end-to-end including connectivity, order placement, RTH handling, and integration with magi-core trade cycles. Use when verifying bridge changes or paper trading functionality.
---

# Testing MooMoo Bridge

## Prerequisites

- Bridge must be running on TIALA with cloudflared tunnel active
- Cloudflared tunnel URL must be registered in BigQuery `magi_core.service_endpoints`
- OpenD must be running on TIALA (port 11111) with "Unlock Trade" enabled

## Devin Secrets Needed

- `GCP_SERVICE_ACCOUNT_KEY` — for BigQuery queries
- `moomoomstral` — Mistral API key (for magi-core trade cycle tests)

## Getting the Bridge URL

The cloudflared tunnel URL changes each restart. To find the current URL:

```bash
export GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcp-key.json
node -e "
const {BigQuery} = require('@google-cloud/bigquery');
const bq = new BigQuery();
bq.query({query: 'SELECT url FROM magi_core.service_endpoints WHERE name=\"opend-proxy\" ORDER BY updated_at DESC LIMIT 1', location: 'US'}).then(([r]) => console.log(r[0]?.url));
"
```

## Test Procedures

### 1. Bridge Connectivity
```bash
curl -s https://<TUNNEL_URL>/health
# Expected: {"status":"ok","trd_env":"SIMULATE","trd_market":"US"}
```

### 2. Account Info
```bash
curl -s https://<TUNNEL_URL>/account_info
# Expected: total_assets, cash, market_value fields
# Verify acc_id matches expected account (currently 1302593)
```

### 3. Quote Fetch
```bash
curl -s https://<TUNNEL_URL>/quote?symbol=MSFT
# Expected: last_price > 0, bid/ask spread reasonable
# This is critical for MARKET→LIMIT auto-conversion
```

### 4. Order Placement

**LIMIT order (works anytime):**
```bash
curl -s -X POST https://<TUNNEL_URL>/place_order \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"AAPL","side":"BUY","qty":1,"price":<last_price>,"order_type":"NORMAL","remark":"devin-test"}'
# Expected: success=true, order_id present
```

**MARKET order (RTH only, or auto-converted outside RTH after PR #15):**
```bash
curl -s -X POST https://<TUNNEL_URL>/place_order \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"AAPL","side":"BUY","qty":1,"order_type":"MARKET","remark":"devin-test"}'
# Outside RTH without PR #15: "Can only place RTH market orders"
# Outside RTH with PR #15: auto-converts to LIMIT at last_price
# Inside RTH: succeeds as MARKET order
```

### 5. RTH Detection
Regular Trading Hours: 9:30 AM – 4:00 PM ET, Monday–Friday.
Use `TZ=America/New_York date "+%H:%M %Z %A"` to check current ET time.

Key boundaries to test:
- 9:29 AM ET → outside RTH
- 9:30 AM ET → inside RTH (boundary)
- 4:00 PM ET → inside RTH (closing bell)
- 4:01 PM ET → outside RTH
- Any time Saturday/Sunday → outside RTH

### 6. Full Trade Cycle (magi-core integration)

Start magi-core Express server:
```bash
cd ~/repos/magi-core
export MISTRAL_API_KEY="$moomoomstral"
export GOOGLE_APPLICATION_CREDENTIALS=/tmp/gcp-key.json
export LLM_PROVIDER=mistral
node src/index.js &
```

Trigger trade cycle:
```bash
curl -s --max-time 300 -X POST http://localhost:8080/run
# Expected: {"status":"completed",...}
# Duration: typically 2-5 minutes
```

Verify in BigQuery:
```sql
SELECT timestamp, symbol, action, confidence, reasoning
FROM magi_core.thoughts
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 10 MINUTE)
ORDER BY timestamp DESC
```

## Important Notes

- Entry point is `src/index.js` (Express server), NOT `bootstrap.js` or `magi-core.js` (deprecated)
- `src/session.js` is the session runner but exits immediately when run directly — use `src/index.js` which wraps it in an HTTP server
- Bridge has no cancel order endpoint — pending orders must be cancelled via MooMoo app
- AAPL positions may show `can_sell_qty: 0` if a sell order is already pending
- The `moomoomstral` secret is the Mistral API key, not a separate secret
- MooMoo paper trading uses SIMULATE environment (hardcoded in bridge for safety)
- Default account ID is set in `scripts/start-bridge.sh` via `MOOMOO_ACC_ID` env var

## Common Issues

- **"Can only place RTH market orders"**: MARKET orders rejected outside RTH. Use LIMIT orders or ensure PR #15 is merged.
- **Cloudflared tunnel down**: User needs to restart on TIALA: `cd ~/repos/magi-moomoo && bash scripts/start-bridge.sh`
- **401 from Mistral API**: Check that `moomoomstral` secret is set and exported as `MISTRAL_API_KEY`
- **L7 composite score blocking**: Guard layer may block orders even when bridge is working. Check `magi_core.thoughts` for BLOCKED entries.
- **OpenD connection refused**: OpenD might not be running on TIALA. User needs to start it manually.
