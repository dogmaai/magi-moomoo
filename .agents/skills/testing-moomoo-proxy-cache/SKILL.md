---
name: testing-moomoo-proxy-cache
description: >
  End-to-end testing of the magi-moomoo proxy cache/stale-URL retry logic
  using a fake BigQuery client and a fake bridge server.
---

# Testing MooMoo Proxy Cache / Stale-URL Retry

## When to use

Use when changing `magi-moomoo/server.js`, especially:

- `getMoomooBridgeUrl()` caching behavior.
- `proxyToBridge()` retry/invalidation logic for dead Cloudflare quick-tunnel URLs.
- `POST /trade/place_order` no-retry safety.
- `AbortController` timeout handling.

## Devin Secrets Needed

- None for the mocked path.
- `GCP_SERVICE_ACCOUNT_KEY` only if you switch to a real `opend-proxy` BigQuery row.

## Test Harness (mocked BigQuery)

The proxy hardcodes the BigQuery query in `server.js`. To avoid touching the
real `screen-share-459802.magi_core.service_endpoints` table, use a Node ESM
module-customization hook to replace `@google-cloud/bigquery` with an
in-memory mock and run a local fake bridge.

Files (created on demand):

- `test/register.mjs` — registers `test/loader.mjs` via `node:module`.
- `test/loader.mjs` — redirects `@google-cloud/bigquery` to the mock.
- `test/bigquery-mock.mjs` — returns a sequence of bridge URLs from `TEST_BQ_URLS`.
- `test/fake-bridge.mjs` — returns 200, 503, or a slow chunked response on demand.
- `test/run-proxy-cache-tests.sh` — orchestrates all scenarios.

### Run the tests

```bash
cd /home/ubuntu/repos/magi-moomoo
npm install
bash test/run-proxy-cache-tests.sh
```

The script exits non-zero if any assertion fails and writes detailed output to
`/tmp/proxy-test-results.txt`.

### What it verifies

1. **Cache hit:** two `GET`s within 60s call BigQuery exactly once.
2. **Stale URL retry:** a dead `GET` transparently re-fetches the bridge URL
   from BigQuery and retries once.
3. **POST no-retry:** `POST /trade/place_order` on a 5xx does not retry to a
   new URL, preventing duplicate orders.
4. **Unreachable bridge:** connection errors return `503` with
   `moomoo-bridge unreachable`.
5. **Timeout:** a slow body read is aborted after 10s and returns
   `moomoo-bridge timeout` without retrying.

## Notes / Gotchas

- `node --import ./test/register.mjs bootstrap.js` must be run from the repo
  root so the loader resolves `./test/...` paths correctly.
- The fake-bridge `/slow/positions` endpoint sends chunked headers then waits
  15s; this proves the `AbortController` signal stays armed through body reading.
- For real-bridge tests, first register a live tunnel with
  `scripts/register-tunnel.py` and ensure `GOOGLE_APPLICATION_CREDENTIALS`
  points to a GCP service-account key. Do not run real/order tests unless the
  environment is meant for paper/simulate trading.
