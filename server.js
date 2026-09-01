import express from 'express';
import { BigQuery } from '@google-cloud/bigquery';
import fetch from 'node-fetch';

const app = express();
app.use(express.json());

const bigquery = new BigQuery({ projectId: 'screen-share-459802' });

const PROXY_TIMEOUT_MS = 10000; // 10 second timeout for bridge requests
const PROXY_RETRIES = 1; // Retry once after refreshing a stale tunnel URL from BigQuery

// moomoo-bridge URL cache (avoid BQ query on every request)
let cachedBridgeUrl = null;
let cachedBridgeUrlUpdatedAt = null;
let lastFetchTime = 0;
const CACHE_TTL_MS = 60_000; // 1 minute
const STALE_URL_HOURS = 24; // quick-tunnel URLs rarely survive > 24h

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
  let baseUrl = await getMoomooBridgeUrl();

  for (let attempt = 0; attempt <= PROXY_RETRIES; attempt++) {
    const url = `${baseUrl}${path}`;
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), PROXY_TIMEOUT_MS);
    let res = null;

    try {
      res = await fetch(url, { ...options, signal: controller.signal });
      const ageHint = getCachedBridgeUrlAgeText();

      // Cloudflare returns 5xx for a dead quick-tunnel.  Only invalidate the cache on
      // server errors, and retry once for idempotent GET requests.
      if (res.status >= 500) {
        invalidateBridgeUrlCache();
        if (canRetry && attempt < PROXY_RETRIES) {
          // Drain the error body before retrying to release the connection.
          try { await res.text(); } catch { /* ignore */ }
          console.warn(`[PROXY] Bridge returned HTTP ${res.status} at ${baseUrl}; refreshing URL from BigQuery and retrying...` + (ageHint ? ` (${ageHint})` : ''));
          baseUrl = await getMoomooBridgeUrl();
          continue;
        }
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
      const ageHint = getCachedBridgeUrlAgeText();
      invalidateBridgeUrlCache();

      // Network/DNS/connection errors often mean the cached quick-tunnel URL is stale.
      // Refresh once from BigQuery and retry.  AbortError is our own timeout, so do not
      // loop again (avoid doubling the wait for a genuinely slow bridge).
      // POST requests are never retried to avoid duplicate orders.
      if (canRetry && attempt < PROXY_RETRIES && e.name !== 'AbortError') {
        console.warn(`[PROXY] Bridge unreachable at ${baseUrl}; refreshing URL from BigQuery and retrying...` + (ageHint ? ` (${ageHint})` : ''));
        try {
          baseUrl = await getMoomooBridgeUrl();
        } catch (bqErr) {
          throw new Error(`moomoo-bridge unreachable; failed to refresh URL from BigQuery: ${bqErr.message}`);
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

// 発注 (Phase 2: forward to moomoo-bridge)
app.post('/trade/place_order', async (req, res) => {
  try {
    const result = await proxyToBridge('/place_order', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
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
  const checks = { proxy: 'ok', bridge_url: null, bridge_health: null, timestamp: new Date().toISOString() };
  try {
    const url = await getMoomooBridgeUrl();
    checks.bridge_url = url;
  } catch (e) {
    checks.bridge_url = 'ERROR: ' + e.message;
    return res.status(503).json({ status: 'error', checks, error: 'bridge URL not found in BigQuery' });
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
  const thresholdSeconds = Math.max(1, Math.min(parseInt(req.query.threshold || '900', 10), 86400));
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
