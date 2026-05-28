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
export GOOGLE_APPLICATION_CREDENTIALS=/home/ubuntu/gcp-key.json
cd /home/ubuntu/repos/magi-core && node --input-type=module -e "
import { BigQuery } from '@google-cloud/bigquery';
const bq = new BigQuery({ projectId: 'screen-share-459802' });
const [rows] = await bq.query({
  query: \`SELECT url FROM \\\`screen-share-459802.magi_core.service_endpoints\\\` WHERE service='opend-proxy' ORDER BY updated_at DESC LIMIT 1\`,
  location: 'US'
});
console.log(rows[0]?.url || 'NOT FOUND');
"
```

**Important**: The column name is `service` (not `name`). The table is `magi_core.service_endpoints`.

## Test Procedures

### 1. Bridge Connectivity
```bash
curl -s https://<TUNNEL_URL>/health
# Expected: {"status":"ok","trd_env":"SIMULATE","trd_market":"US","acc_id":1302593}
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

**MARKET order (auto-converted to LIMIT in SIMULATE):**
```bash
curl -s -X POST https://<TUNNEL_URL>/place_order \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"AAPL","side":"BUY","qty":1,"order_type":"MARKET","remark":"devin-test"}'
# Bridge auto-converts MARKET→LIMIT using snapshot price
# If snapshot fails, uses request body price as fallback
# If neither available, returns 400 error
```

**MARKET order with price hint (simulates AUTO_CLOSE path):**
```bash
curl -s -X POST https://<TUNNEL_URL>/place_order \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"AAPL","side":"SELL","qty":1,"price":150.0,"order_type":"MARKET","remark":"devin-test-hint"}'
# Bridge tries snapshot first; if fails, uses price=150.0 from request body
# This is how AUTO_CLOSE orders work: magi-core passes currentPrice as hint
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

### 6. Testing MARKET→LIMIT Fallback Logic Locally

When the bridge on TIALA can't be modified (e.g., PR not merged yet), test the fallback logic via Python simulation:

```python
# Simulate the bridge's place_order MARKET→LIMIT conversion logic
def simulate_fallback(request_price, snapshot_succeeds, snapshot_price=0):
    """Returns (final_price, order_type, source) or (400, error)"""
    snap = snapshot_price if snapshot_succeeds else 0.0
    limit_price = snap if snap > 0 else request_price
    if limit_price > 0:
        source = "snapshot" if snap > 0 else "request_hint"
        return (limit_price, "LIMIT", source)
    else:
        return (400, "No price available", None)
```

Key test cases:
- `simulate_fallback(150.0, False)` → `(150.0, "LIMIT", "request_hint")` — the fix
- `simulate_fallback(0, False)` → `(400, "No price available", None)` — safe failure
- `simulate_fallback(0, True, 312.51)` → `(312.51, "LIMIT", "snapshot")` — happy path
- `simulate_fallback(100, True, 312.51)` → `(312.51, "LIMIT", "snapshot")` — snapshot wins

### 7. Testing magi-core Price Hint (executeMoomooOrder)

Verify the hintPrice validation logic from `lib/moomoo.js`:

```javascript
// The hintPrice logic extracted from executeMoomooOrder
const validate = (opts) => {
  const hp = typeof opts.price === 'number' && Number.isFinite(opts.price) && opts.price > 0 ? opts.price : 0;
  return hp;
};
// validate({ price: 150.5 }) === 150.5  (AUTO_CLOSE with currentPrice)
// validate({}) === 0                    (normal LLM orders, no hint)
// validate({ price: NaN }) === 0        (bad value rejected)
// validate({ price: -1 }) === 0         (negative rejected)
```

### 8. Full Trade Cycle (magi-core integration)

Start magi-core Express server:
```bash
cd ~/repos/magi-core
export MISTRAL_API_KEY="$moomoomstral"
export GOOGLE_APPLICATION_CREDENTIALS=/home/ubuntu/gcp-key.json
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
- Default account ID is auto-discovered (STOCK_AND_OPTION type, currently 1302593)
- NEVER run/execute magi-moomoo bridge on Devin's VM — it must run on TIALA only
- Bridge on TIALA must be restarted after merging PRs: `cd ~/repos/magi-moomoo && git pull && bash scripts/start-bridge.sh`
- GCP key file should be written to `/home/ubuntu/gcp-key.json` (not `/tmp/` which may be wiped)

## Common Issues

- **"Can only place RTH market orders"**: Bridge's MARKET→LIMIT auto-conversion failed. Check if quote snapshot is working (`/quote?symbol=AAPL`). If quote fails and no price hint was provided, this error occurs. The fix (PR #29) adds request_price fallback.
- **Cloudflared tunnel down**: User needs to restart on TIALA: `cd ~/repos/magi-moomoo && bash scripts/start-bridge.sh`
- **401 from Mistral API**: Check that `moomoomstral` secret is set and exported as `MISTRAL_API_KEY`
- **L7 composite score blocking**: Guard layer may block orders even when bridge is working. Check `magi_core.thoughts` for BLOCKED entries.
- **OpenD connection refused**: OpenD might not be running on TIALA. User needs to start it manually.
- **BigQuery column name**: Use `service='opend-proxy'` not `name='opend-proxy'` when querying `service_endpoints` table.
