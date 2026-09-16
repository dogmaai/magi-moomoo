import express from 'express';
import { BigQuery } from '@google-cloud/bigquery';
import { OAuth2Client } from 'google-auth-library';
import fetch from 'node-fetch';
import { createOrderGate } from './lib/order-gate.mjs';

const app = express();
app.use(express.json());

const bigquery = new BigQuery({ projectId: 'screen-share-459802' });

const PROXY_TIMEOUT_MS = 10000; // 10 second timeout for bridge requests
const PROXY_RETRIES = 1; // Retry once after refreshing a stale tunnel URL from BigQuery
const BRIDGE_AUTH_TOKEN = process.env.BRIDGE_AUTH_TOKEN || '';
if (BRIDGE_AUTH_TOKEN) {
  console.log('[AUTH] bridge bearer token enabled');
} else {
  console.warn('[AUTH] BRIDGE_AUTH_TOKEN unset — bridge requests are unauthenticated');
}

function bridgeFetchOptions(options = {}) {
  const headers = { ...(options.headers || {}) };
  if (BRIDGE_AUTH_TOKEN) headers.Authorization = `Bearer ${BRIDGE_AUTH_TOKEN}`;
  return { ...options, headers };
}

// moomoo-bridge URL cache (avoid BQ query on every request)
let cachedBridgeUrl = null;
let cachedBridgeUrlUpdatedAt = null;
let lastFetchTime = 0;
const CACHE_TTL_MS = 60_000; // 1 minute
const STALE_URL_HOURS = 24; // quick-tunnel URLs rarely survive > 24h

// === Dual-route bridge selection (private VPC link / Cloudflare tunnel fallback) ===
// BRIDGE_ROUTE_MODE: legacy (tunnel only, default), auto (private preferred,
// Cloudflare fallback with hysteresis), private (private only — post-cutover).
// BRIDGE_PRIVATE_URL: static private endpoint, e.g. http://10.42.0.10:11436.
// Health is probed lazily on requests — Cloud Run freezes idle instances, so a
// setInterval background prober would never fire reliably.
const BRIDGE_PRIVATE_URL = (process.env.BRIDGE_PRIVATE_URL || '').replace(/\/+$/, '');
let BRIDGE_ROUTE_MODE = (process.env.BRIDGE_ROUTE_MODE || 'legacy').toLowerCase();
const BRIDGE_PRIVATE_HEALTH_SEC = Math.max(5, Number(process.env.BRIDGE_PRIVATE_HEALTH_SEC) || 15);
const PRIVATE_HEALTH_TIMEOUT_MS = 3000;
const PRIVATE_FAIL_THRESHOLD = 2; // consecutive request failures before marking private down
const PRIVATE_OK_THRESHOLD = 3;   // consecutive probe successes to mark private recovered

if (!['legacy', 'auto', 'private'].includes(BRIDGE_ROUTE_MODE)) {
  console.warn(`[ROUTE] unknown BRIDGE_ROUTE_MODE='${BRIDGE_ROUTE_MODE}' — coerced to legacy`);
  BRIDGE_ROUTE_MODE = 'legacy';
}
if (BRIDGE_ROUTE_MODE !== 'legacy' && !BRIDGE_PRIVATE_URL) {
  console.warn(`[ROUTE] BRIDGE_ROUTE_MODE=${BRIDGE_ROUTE_MODE} but BRIDGE_PRIVATE_URL unset — private route disabled`);
}
if (BRIDGE_PRIVATE_URL) {
  console.log(`[ROUTE] private bridge endpoint configured: ${BRIDGE_PRIVATE_URL} (mode=${BRIDGE_ROUTE_MODE})`);
}

let privateUp = true; // optimistic: try private first in auto mode
let privateConsecFail = 0;
let privateConsecOk = 0;
let lastPrivateProbe = 0;
let routeFallbackEvents = 0;

const ROUTE_STATS_LAT_MAX = 256;
const routeStats = {
  private:    { requests: 0, errors: 0, latencies: [] },
  cloudflare: { requests: 0, errors: 0, latencies: [] },
};

function recordRouteMetric(route, latencyMs, ok) {
  const s = routeStats[route];
  if (!s) return;
  s.requests++;
  if (!ok) s.errors++;
  s.latencies.push(latencyMs);
  if (s.latencies.length > ROUTE_STATS_LAT_MAX) s.latencies.shift();
}

function onPrivateRouteFailure(reason) {
  privateConsecFail++;
  privateConsecOk = 0;
  if (privateUp && privateConsecFail >= PRIVATE_FAIL_THRESHOLD) {
    privateUp = false;
    routeFallbackEvents++;
    console.warn(`[ROUTE] private->cloudflare fallback (${reason}; ${privateConsecFail} consecutive failures)`);
  }
}

function onPrivateRouteSuccess() {
  privateConsecFail = 0;
}

// Lazy health probe while private is down. Runs on the request path only;
// consecutive successes re-arm the private route (hysteresis).
async function maybeProbePrivateRoute() {
  if (!BRIDGE_PRIVATE_URL) return;
  if (Date.now() - lastPrivateProbe < BRIDGE_PRIVATE_HEALTH_SEC * 1000) return;
  lastPrivateProbe = Date.now();
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), PRIVATE_HEALTH_TIMEOUT_MS);
    const res = await fetch(`${BRIDGE_PRIVATE_URL}/health`, { ...bridgeFetchOptions(), signal: controller.signal });
    clearTimeout(timeoutId);
    if (res.ok) {
      privateConsecOk++;
      if (!privateUp && privateConsecOk >= PRIVATE_OK_THRESHOLD) {
        privateUp = true;
        privateConsecFail = 0;
        console.log(`[ROUTE] private route recovered (${privateConsecOk} consecutive health probes ok) — resuming private`);
      }
    } else {
      privateConsecOk = 0;
    }
  } catch {
    privateConsecOk = 0;
  }
}

// Pick the upstream for one proxy request. The choice is made once per request;
// a request never straddles both routes (orders are never duplicated).
async function selectBridgeRoute() {
  if (BRIDGE_ROUTE_MODE === 'private') {
    if (!BRIDGE_PRIVATE_URL) throw new Error('BRIDGE_ROUTE_MODE=private but BRIDGE_PRIVATE_URL unset');
    return { route: 'private', baseUrl: BRIDGE_PRIVATE_URL };
  }
  if (BRIDGE_ROUTE_MODE === 'auto' && BRIDGE_PRIVATE_URL) {
    if (!privateUp) await maybeProbePrivateRoute();
    if (privateUp) return { route: 'private', baseUrl: BRIDGE_PRIVATE_URL };
    return { route: 'cloudflare', baseUrl: await getMoomooBridgeUrl() };
  }
  return { route: 'cloudflare', baseUrl: await getMoomooBridgeUrl() };
}

// moomoo-bridge URLをBigQueryから取得（with cache）
async function getMoomooBridgeUrl() {
  if (cachedBridgeUrl && (Date.now() - lastFetchTime < CACHE_TTL_MS)) {
    return cachedBridgeUrl;
  }
  // updated_at is stored as STRING; cast to TIMESTAMP for reliable ordering
  const query = `
    SELECT
      url,
      IFNULL(SAFE_CAST(updated_at AS TIMESTAMP), TIMESTAMP('1970-01-01')) AS updated_at_ts
    FROM \`screen-share-459802.magi_core.service_endpoints\`
    WHERE service = 'opend-proxy'
    ORDER BY updated_at_ts DESC
    LIMIT 1
  `;
  const [rows] = await bigquery.query({ query, location: 'US' });
  if (!rows.length) throw new Error('moomoo-bridge URL not found in BigQuery');
  cachedBridgeUrl = rows[0].url;
  cachedBridgeUrlUpdatedAt = new Date(rows[0].updated_at_ts.value);
  lastFetchTime = Date.now();
  const ageHours = (Date.now() - cachedBridgeUrlUpdatedAt.getTime()) / 3600000;
  if (ageHours > STALE_URL_HOURS) {
    console.warn(`[CACHE] Warning: opend-proxy URL is ${ageHours.toFixed(1)}h old — quick tunnel may be stale`);
  }
  console.log('[CACHE] Bridge URL refreshed:', cachedBridgeUrl, 'registered at', cachedBridgeUrlUpdatedAt.toISOString());
  return cachedBridgeUrl;
}

// Clear cached URL (called on connection errors so next request re-fetches)
function invalidateBridgeUrlCache() {
  cachedBridgeUrl = null;
  cachedBridgeUrlUpdatedAt = null;
  lastFetchTime = 0;
}

function getCachedBridgeUrlAgeText() {
  if (!cachedBridgeUrlUpdatedAt) return null;
  const ageHours = (Date.now() - cachedBridgeUrlUpdatedAt.getTime()) / 3600000;
  if (ageHours > 6) {
    return `opend-proxy URL is ${ageHours.toFixed(1)}h old (quick tunnel may be stale; run start-bridge.sh on TIALA or switch to a named tunnel)`;
  }
  return null;
}

// moomoo-bridgeへプロキシリクエスト送信 (with timeout + stale URL retry)
// If the cached tunnel URL is dead (e.g. Cloudflare quick-tunnel rotated),
// clear the cache, re-fetch the latest opend-proxy URL from BigQuery, and retry once.
// Retry is only safe for idempotent GET requests; POST /trade/place_order must not
// be re-sent because the bridge may have already processed the order.
const RETRYABLE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

async function proxyToBridge(path, options = {}) {
  const method = (options.method || 'GET').toUpperCase();
  const canRetry = RETRYABLE_METHODS.has(method);
  let { route, baseUrl } = await selectBridgeRoute();

  for (let attempt = 0; attempt <= PROXY_RETRIES; attempt++) {
    const url = `${baseUrl}${path}`;
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), PROXY_TIMEOUT_MS);
    const startedAt = Date.now();
    let res = null;

    try {
      res = await fetch(url, { ...bridgeFetchOptions(options), signal: controller.signal });
      const latencyMs = Date.now() - startedAt;
      const ageHint = route === 'cloudflare' ? getCachedBridgeUrlAgeText() : null;

      // Cloudflare returns 5xx for a dead quick-tunnel — refresh the cached
      // URL and retry GETs.  A 5xx on the private route means the bridge is
      // reachable-but-broken (the route itself is alive — an HTTP response
      // proved it); failing over to the tunnel would hit the same broken
      // bridge and flap, so private liveness is left to the /health probes
      // rather than counted here.  POSTs are never retried on either route.
      if (res.status >= 500) {
        recordRouteMetric(route, latencyMs, false);
        if (route === 'cloudflare') invalidateBridgeUrlCache();
        if (canRetry && attempt < PROXY_RETRIES) {
          // Drain the error body before retrying to release the connection.
          try { await res.text(); } catch { /* ignore */ }
          console.warn(`[PROXY] Bridge returned HTTP ${res.status} via ${route} at ${baseUrl}; re-selecting route and retrying...` + (ageHint ? ` (${ageHint})` : ''));
          ({ route, baseUrl } = await selectBridgeRoute());
          continue;
        }
      } else {
        recordRouteMetric(route, latencyMs, true);
        if (route === 'private') onPrivateRouteSuccess();
      }

      const contentType = res.headers.get('content-type') || '';
      let body;
      if (contentType.includes('application/json')) {
        body = await res.json();
      } else {
        const text = await res.text();
        try { body = JSON.parse(text); } catch { body = { raw: text.slice(0, 500) }; }
      }
      return { status: res.status, body };
    } catch (e) {
      recordRouteMetric(route, Date.now() - startedAt, false);
      const ageHint = route === 'cloudflare' ? getCachedBridgeUrlAgeText() : null;
      if (route === 'private') onPrivateRouteFailure(e.name === 'AbortError' ? 'timeout' : (e.message || e.name));
      else invalidateBridgeUrlCache();

      // Network/DNS/connection errors often mean the cached quick-tunnel URL is
      // stale or the private link went down.  Re-select the route once (which
      // refreshes the tunnel URL from BigQuery or falls back off private) for
      // idempotent GET requests.  AbortError is our own timeout, so do not
      // loop again (avoid doubling the wait for a genuinely slow bridge).
      // POST requests are never retried to avoid duplicate orders.
      if (canRetry && attempt < PROXY_RETRIES && e.name !== 'AbortError') {
        console.warn(`[PROXY] Bridge unreachable via ${route} at ${baseUrl}; re-selecting route and retrying...` + (ageHint ? ` (${ageHint})` : ''));
        try {
          ({ route, baseUrl } = await selectBridgeRoute());
        } catch (bqErr) {
          throw new Error(`moomoo-bridge unreachable; failed to resolve fallback URL: ${bqErr.message}`);
        }
        continue;
      }

      if (e.name === 'AbortError') {
        throw new Error('moomoo-bridge timeout' + (ageHint ? `; ${ageHint}` : ''));
      }
      const message = e.message || e.name || 'unknown bridge error';
      throw new Error(message + (ageHint ? `; ${ageHint}` : ''));
    } finally {
      clearTimeout(timeoutId);
    }
  }

  throw new Error('moomoo-bridge unreachable after retry');
}

// ヘルスチェック
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'magi-moomoo', timestamp: new Date().toISOString() });
});

function percentile(sortedAsc, p) {
  if (!sortedAsc.length) return null;
  const idx = Math.min(sortedAsc.length - 1, Math.ceil(p * sortedAsc.length) - 1);
  return sortedAsc[Math.max(0, idx)];
}

// Route status / metrics: per-route request counts, error counts and latency
// percentiles so the private-vs-tunnel comparison in the migration plan can be
// verified empirically before cutover.
app.get('/route_status', (req, res) => {
  const summarize = (s) => {
    const sorted = [...s.latencies].sort((a, b) => a - b);
    return {
      requests: s.requests,
      errors: s.errors,
      latency_ms: sorted.length ? { p50: percentile(sorted, 0.5), p95: percentile(sorted, 0.95), samples: sorted.length } : null,
    };
  };
  res.json({
    mode: BRIDGE_ROUTE_MODE,
    private_url: BRIDGE_PRIVATE_URL || null,
    private_health: {
      up: privateUp,
      consecutive_failures: privateConsecFail,
      consecutive_probe_ok: privateConsecOk,
      last_probe: lastPrivateProbe ? new Date(lastPrivateProbe).toISOString() : null,
      probe_interval_sec: BRIDGE_PRIVATE_HEALTH_SEC,
    },
    active_route: BRIDGE_ROUTE_MODE === 'private' ? 'private'
      : (BRIDGE_ROUTE_MODE === 'auto' && BRIDGE_PRIVATE_URL && privateUp ? 'private' : 'cloudflare'),
    fallback_events: routeFallbackEvents,
    routes: { private: summarize(routeStats.private), cloudflare: summarize(routeStats.cloudflare) },
    timestamp: new Date().toISOString(),
  });
});

// URL確認（デバッグ用）
app.get('/url', async (req, res) => {
  try {
    const url = await getMoomooBridgeUrl();
    const ageText = getCachedBridgeUrlAgeText();
    res.json({ url, stale_hint: ageText || null });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// === Phase 2: Trade Proxy Endpoints ===

// === OIDC caller verification (service-to-service auth) ===
// Cloud Run already enforces IAM (run.invoker) on this service; this layer adds
// SUBJECT verification — the trusted-pipeline exemption is granted only to a
// Google-signed ID token whose `email` claim is in GATE_TRUSTED_CALLER_EMAILS.
// The token Cloud Run validated is forwarded to the container as
// X-Serverless-Authorization — Google strips its signature, so in-app
// verifyIdToken() can never succeed on it; for that path we validate the
// claims (iss/aud/exp/email_verified) and rely on Cloud Run IAM having
// already authenticated the signature. Authorization tokens from direct
// callers still carry a signature and are fully re-verified in-app.
const oidcClient = new OAuth2Client();
const TRUSTED_CALLER_EMAILS = (process.env.GATE_TRUSTED_CALLER_EMAILS || '')
  .split(',').map(s => s.trim()).filter(Boolean);
if (TRUSTED_CALLER_EMAILS.length) {
  console.log('[GATE] OIDC subject verification enabled; trusted callers:', TRUSTED_CALLER_EMAILS.join(', '));
} else {
  console.warn('[GATE] GATE_TRUSTED_CALLER_EMAILS unset — legacy source-label mode (spoofable)');
}

let _selfAudience = null;
let _selfAudienceAt = 0;
const SELF_AUDIENCE_TTL_MS = 300_000;

// Audience for caller tokens = this service's own URL. Env override first,
// else the latest 'magi-moomoo' row in service_endpoints (the same URL
// magi-core mints tokens against).
async function getSelfAudience() {
  if (process.env.GATE_OIDC_AUDIENCE) return process.env.GATE_OIDC_AUDIENCE;
  if (_selfAudience && Date.now() - _selfAudienceAt < SELF_AUDIENCE_TTL_MS) return _selfAudience;
  const [rows] = await bigquery.query({
    query: `SELECT url FROM \`screen-share-459802.magi_core.service_endpoints\`
            WHERE service = 'magi-moomoo'
            ORDER BY IFNULL(SAFE_CAST(updated_at AS TIMESTAMP), TIMESTAMP('1970-01-01')) DESC
            LIMIT 1`,
    location: 'US'
  });
  if (!rows.length) throw new Error('magi-moomoo own URL not found in service_endpoints (set GATE_OIDC_AUDIENCE)');
  _selfAudience = rows[0].url;
  _selfAudienceAt = Date.now();
  return _selfAudience;
}

const GOOGLE_ISSUERS = new Set(['accounts.google.com', 'https://accounts.google.com']);

// Validate claims every path requires beyond identity: right issuer, right
// audience, unexpired, verified SA email. For the platform path this is the
// ONLY verification (the signature is gone), so it must stay strict.
function checkTokenClaims(claims, audience) {
  if (!claims || !GOOGLE_ISSUERS.has(claims.iss)) throw new Error('unexpected issuer: ' + (claims && claims.iss));
  if (claims.aud !== audience) throw new Error('unexpected audience');
  if (!claims.exp || claims.exp * 1000 <= Date.now()) throw new Error('token expired');
  if (claims.email_verified !== true) throw new Error('email claim not verified');
  if (!claims.email) throw new Error('no email claim');
  return claims;
}

// `platformVerified` — the token arrived via X-Serverless-Authorization, i.e.
// Cloud Run's IAM proxy already validated its signature and stripped it, so
// in-app verifyIdToken() can never succeed on it; we validate claims only and
// rely on the platform boundary (clients cannot inject this header).
// Otherwise the token came from Authorization and still carries a signature —
// fully re-verify it in-app.
async function verifyCallerIdToken(idToken, platformVerified) {
  const audience = await getSelfAudience();
  if (platformVerified) {
    const parts = String(idToken).split('.');
    if (parts.length !== 3) throw new Error('malformed platform token');
    const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    return checkTokenClaims(claims, audience);
  }
  const ticket = await oidcClient.verifyIdToken({ idToken, audience });
  return checkTokenClaims(ticket.getPayload(), audience);
}

function bearerToken(headerValue) {
  const m = /^Bearer\s+(\S+)\s*$/i.exec(headerValue || '');
  return m ? m[1] : null;
}

// 発注 (Phase 2: forward to moomoo-bridge)
// 発注ゲート — 全呼び出し元共通のサーバーサイド境界（R07/R08）
// kill switch / reduce-only / 承認トークンをここで強制する
const orderGate = createOrderGate({
  bqQuery: async (query, params) => {
    const [rows] = await bigquery.query({ query, params, location: 'US' });
    return rows;
  },
  getPositions: async () => {
    const result = await proxyToBridge('/positions');
    if (result.status !== 200) throw new Error(`positions bridge returned HTTP ${result.status}`);
    return result.body?.positions || [];
  },
  trustedCallerEmails: TRUSTED_CALLER_EMAILS,
  verifyIdToken: verifyCallerIdToken
});

app.post('/trade/place_order', async (req, res) => {
  try {
    const { approval_token: approvalToken, source, ...orderBody } = req.body || {};
    const platformToken = bearerToken(req.get('x-serverless-authorization'));
    const idToken = platformToken || bearerToken(req.get('authorization'));
    const verdict = await orderGate.checkOrder({
      symbol: orderBody.symbol,
      side: orderBody.side,
      qty: orderBody.qty,
      approvalToken,
      source,
      idToken,
      idTokenPlatformVerified: Boolean(platformToken)
    });
    if (!verdict.allow) {
      console.warn(`[GATE] order rejected (${verdict.code}):`, orderBody.symbol, orderBody.side, orderBody.qty, '-', verdict.reason);
      return res.status(verdict.status).json({ error: verdict.code, detail: verdict.reason });
    }
    const result = await proxyToBridge('/place_order', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(orderBody),
    });
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] place_order error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// ポジション取得
app.get('/trade/positions', async (req, res) => {
  try {
    const result = await proxyToBridge('/positions');
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] positions error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// 残高取得
app.get('/trade/account_info', async (req, res) => {
  try {
    const result = await proxyToBridge('/account_info');
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] account_info error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// 注文ステータス確認
app.get('/trade/order/:orderId', async (req, res) => {
  try {
    const result = await proxyToBridge(`/order/${req.params.orderId}`);
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] order_status error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// 気配値取得
app.get('/trade/quote', async (req, res) => {
  try {
    const symbol = req.query.symbol;
    if (!symbol) return res.status(400).json({ error: 'symbol query param required' });
    const result = await proxyToBridge(`/quote?symbol=${encodeURIComponent(symbol)}`);
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] quote error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// ヒストリカルK線データ取得
app.get('/trade/bars', async (req, res) => {
  try {
    const symbol = req.query.symbol;
    const limit = req.query.limit || 21;
    if (!symbol) return res.status(400).json({ error: 'symbol query param required' });
    const timeframe = req.query.timeframe || '1Day';
    const result = await proxyToBridge(`/bars?symbol=${encodeURIComponent(symbol)}&limit=${limit}&timeframe=${encodeURIComponent(timeframe)}`);
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] bars error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// アカウント一覧（SIMULATE accounts discovery）
app.get('/trade/accounts', async (req, res) => {
  try {
    const result = await proxyToBridge('/accounts');
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] accounts error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// 複数銘柄バッチスナップショット取得
app.get('/trade/snapshot', async (req, res) => {
  try {
    const symbols = req.query.symbols;
    if (!symbols) return res.status(400).json({ error: 'symbols query param required (comma-separated)' });
    const result = await proxyToBridge(`/snapshot?symbols=${encodeURIComponent(symbols)}`);
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] snapshot error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// 板情報（オーダーブック）取得
app.get('/trade/orderbook', async (req, res) => {
  try {
    const symbol = req.query.symbol;
    if (!symbol) return res.status(400).json({ error: 'symbol query param required' });
    const result = await proxyToBridge(`/orderbook?symbol=${encodeURIComponent(symbol)}`);
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] orderbook error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// 注文履歴取得
app.get('/trade/order_history', async (req, res) => {
  try {
    const code = req.query.code || '';
    const days = req.query.days || 7;
    let path = `/order_history?days=${days}`;
    if (code) path += `&code=${encodeURIComponent(code)}`;
    const result = await proxyToBridge(path);
    res.status(result.status).json(result.body);
  } catch (e) {
    console.error('[PROXY] order_history error:', e.message);
    res.status(503).json({ error: 'moomoo-bridge unreachable', detail: e.message });
  }
});

// === Connectivity Check ===

// End-to-end connectivity test: proxy → bridge → OpenD
app.get('/connectivity', async (req, res) => {
  const checks = { proxy: 'ok', bridge_url: null, bridge_route: null, bridge_health: null, route_mode: BRIDGE_ROUTE_MODE, timestamp: new Date().toISOString() };
  try {
    // Resolve through the route selector so private/auto modes report the URL
    // that would actually serve traffic — in private mode the BigQuery tunnel
    // row may not exist post-cutover and must not fail this check.
    const { route, baseUrl } = await selectBridgeRoute();
    checks.bridge_url = baseUrl;
    checks.bridge_route = route;
  } catch (e) {
    checks.bridge_url = 'ERROR: ' + e.message;
    return res.status(503).json({ status: 'error', checks, error: 'bridge URL not resolvable' });
  }
  try {
    const result = await proxyToBridge('/health');
    checks.bridge_health = result.body;
  } catch (e) {
    checks.bridge_health = 'ERROR: ' + e.message;
    return res.status(503).json({ status: 'error', checks, error: 'bridge unreachable' });
  }
  res.json({ status: 'ok', checks });
});

// Snapshot freshness check: reads magi_core.moomoo_snapshots latest timestamp.
// This complements /health and /connectivity by verifying that real market data
// is actually being persisted, not just that the bridge/proxy are reachable.
app.get('/snapshot_freshness', async (req, res) => {
  let thresholdSeconds = 900;
  if (req.query.threshold !== undefined) {
    const parsed = Number.parseInt(req.query.threshold, 10);
    if (Number.isNaN(parsed)) {
      return res.status(400).json({ status: 'error', error: 'invalid threshold', threshold_seconds: null });
    }
    thresholdSeconds = Math.max(1, Math.min(parsed, 86400));
  }
  try {
    const [rows] = await bigquery.query({
      query: 'SELECT MAX(snapshot_ts) AS latest_ts FROM `screen-share-459802.magi_core.moomoo_snapshots`',
      location: 'US',
    });
    const latest = rows[0]?.latest_ts;
    if (!latest) {
      return res.status(503).json({
        status: 'error',
        freshness_seconds: null,
        latest_snapshot_ts: null,
        threshold_seconds: thresholdSeconds,
        error: 'No snapshots found in moomoo_snapshots',
      });
    }
    const latestTs = latest instanceof Date ? latest : new Date(latest.value || latest.toString() || latest);
    const now = Date.now();
    const latestMs = latestTs.getTime();
    if (Number.isNaN(latestMs)) {
      return res.status(500).json({
        status: 'error',
        freshness_seconds: null,
        latest_snapshot_ts: String(latest),
        threshold_seconds: thresholdSeconds,
        error: 'Could not parse latest snapshot timestamp',
      });
    }
    const freshnessSeconds = Math.floor((now - latestMs) / 1000);
    const ok = freshnessSeconds <= thresholdSeconds;
    const payload = {
      status: ok ? 'ok' : 'stale',
      freshness_seconds: freshnessSeconds,
      latest_snapshot_ts: latestTs.toISOString(),
      threshold_seconds: thresholdSeconds,
    };
    res.status(ok ? 200 : 503).json(payload);
  } catch (e) {
    console.error('[FRESHNESS] BigQuery error:', e.message);
    res.status(500).json({ status: 'error', error: e.message, threshold_seconds: thresholdSeconds });
  }
});

// === Legacy Phase 1 Endpoints (kept for backward compatibility) ===

// 残高確認 (Phase 1 - legacy)
app.get('/account', async (req, res) => {
  try {
    const url = await getMoomooBridgeUrl();
    res.json({ 
      message: 'OpenD connected',
      opend_url: url,
      note: 'Use /trade/account_info for Phase 2 API'
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 発注 (Phase 1 - legacy stub)
app.post('/order', async (req, res) => {
  const { symbol, side, qty } = req.body;
  if (!symbol || !side || !qty) {
    return res.status(400).json({ error: 'symbol, side, qty are required' });
  }
  try {
    const url = await getMoomooBridgeUrl();
    res.json({
      status: 'phase1_deprecated',
      message: 'Use POST /trade/place_order for Phase 2.',
      opend_url: url,
      order: { symbol, side, qty }
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// === Service Registration Helper ===

// Register this service's URL in BigQuery (called once after deployment)
app.post('/register', async (req, res) => {
  const body = req.body || {};
  const serviceUrl = body.url;
  if (!serviceUrl) {
    return res.status(400).json({ error: 'url is required in request body' });
  }
  try {
    await bigquery.query({
      query: `INSERT INTO \`screen-share-459802.magi_core.service_endpoints\` (service, url, updated_at)
              VALUES (@service, @url, CAST(CURRENT_TIMESTAMP() AS STRING))`,
      params: { service: 'magi-moomoo', url: serviceUrl },
      location: 'US'
    });
    res.json({ status: 'registered', service: 'magi-moomoo', url: serviceUrl });
  } catch (e) {
    console.error('[REGISTER] BigQuery error:', e.message);
    res.status(500).json({ error: e.message });
  }
});

export default app;
