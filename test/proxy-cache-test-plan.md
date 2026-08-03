# MooMoo Proxy Stale-URL Retry — End-to-End Test Plan

## Scope

Verify PR #60 (`devin/1785200000-proxy-cache-invalidation-fix`) behavior in `magi-moomoo/server.js`:

- `getMoomooBridgeUrl()` caches the `opend-proxy` URL from BigQuery for 60s (`server.js:16-18`).
- `proxyToBridge()` only invalidates that cache on HTTP 5xx or connection errors (`server.js:88-90`, `110`), not on every response.
- Idempotent `GET/HEAD/OPTIONS` requests are retried once after refreshing the URL (`server.js:69-96`, `116-123`).
- `POST /trade/place_order` is never retried to avoid duplicate orders (`server.js:69`, `90`, `116`).
- The `AbortController` timeout is cleared in `finally`, so it stays armed through body reading (`server.js:79-132`).
- When the bridge is genuinely unreachable, the proxy returns HTTP 503 with a helpful `moomoo-bridge unreachable` message (`server.js:126-137`, `trade` endpoint `catch` blocks).

## Test harness

Because we cannot safely write GCP credentials to disk and a real opend-proxy tunnel is not guaranteed, the test intercepts `@google-cloud/bigquery` at module-load time (`test/register.mjs`, `test/loader.mjs`, `test/bigquery-mock.mjs`) and substitutes a fake BigQuery client that returns a configurable sequence of bridge URLs.

A local fake bridge (`test/fake-bridge.mjs`) exposes:

- `/live/*` — returns HTTP 200 JSON for `GET /live/positions`, `/live/quote`, `/live/bars`, `/live/place_order`, `/live/health`.
- `/dead/*` — returns HTTP 503 for every method.
- `/slow/positions` — sends headers immediately, then waits 15s before completing the JSON body.
- `/counts/:side` and `POST /reset` for request counting.

The real `server.js` and `bootstrap.js` are run unmodified; only the BigQuery import is redirected via Node's module customization hooks.

## Test cases

### 1. Cached GETs do not query BigQuery on every call

1. Start the proxy with `TEST_BQ_URLS=http://localhost:9001/live,http://localhost:1/should-not-be-called`.
2. `GET http://localhost:8080/trade/positions`
3. `GET http://localhost:8080/trade/quote?symbol=AAPL` within 60s.

**Pass criteria:**
- Both responses return HTTP 200 with JSON bodies.
- The proxy log contains exactly one `[BQ MOCK] query` call.
- The fake bridge `/live/positions` and `/live/quote` each receive one request.

**Adversarial signal:** If `proxyToBridge()` invalidated the cache on every successful response, the second call would re-query BigQuery and receive the invalid second URL, causing a 503.

### 2. Dead cached bridge URL refreshes from BigQuery and GET retries transparently

1. Start the proxy with `TEST_BQ_URLS=http://localhost:9001/dead,http://localhost:9001/live`.
2. `GET http://localhost:8080/trade/positions`

**Pass criteria:**
- Response returns HTTP 200 with the live bridge JSON body.
- Proxy log shows two BigQuery mock calls.
- Proxy log contains `[PROXY] Bridge returned HTTP 503 ... refreshing URL from BigQuery and retrying...`.
- Fake bridge log shows exactly one `/dead/positions` request and one `/live/positions` request.

**Adversarial signal:** A broken retry would return 503, or would query BigQuery only once and keep hitting the dead URL.

### 3. POST /trade/place_order does not retry on 5xx and does not duplicate

1. Start the proxy with `TEST_BQ_URLS=http://localhost:9001/dead,http://localhost:9001/live`.
2. `POST http://localhost:8080/trade/place_order` with a MooMoo order body.

**Pass criteria:**
- Response is HTTP 503 with the dead-bridge error body.
- Fake bridge `/live/place_order` request count stays at 0 (no live POST).
- BigQuery mock is called exactly once.

**Adversarial signal:** If POST were retried like GET, the live `/live/place_order` endpoint would receive the order, returning 200 and risking duplication.

### 4. Genuinely unreachable bridge returns HTTP 503

1. Start the proxy with `TEST_BQ_URLS=http://localhost:2`.
2. `GET http://localhost:8080/trade/positions`

**Pass criteria:**
- Response is HTTP 503.
- Response body contains `moomoo-bridge unreachable`.
- BigQuery mock is called exactly twice (one try + one retry).

### 5. 10s timeout fires while reading a slow body

1. Start the proxy with `TEST_BQ_URLS=http://localhost:9001/slow`.
2. `GET http://localhost:8080/trade/positions` and time the response.

**Pass criteria:**
- Response is HTTP 503 and body contains `moomoo-bridge timeout`.
- Elapsed time is between 8s and 13s (the 10s timeout), not 15s+.
- BigQuery mock is called exactly once and no retry is attempted (`AbortError` path does not loop).

**Adversarial signal:** If `clearTimeout` were placed before body reading, the timeout would be disarmed and the proxy would return the slow 200 response after 15s.

## Execution command

```bash
cd /home/ubuntu/repos/magi-moomoo
bash test/run-proxy-cache-tests.sh
```

The script writes results to `/tmp/proxy-test-results.txt` and proxy logs to `/tmp/proxy-test.log`.
