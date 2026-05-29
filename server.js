import express from 'express';
import { BigQuery } from '@google-cloud/bigquery';
import fetch from 'node-fetch';

const app = express();
app.use(express.json());

const bigquery = new BigQuery({ projectId: 'screen-share-459802' });

const PROXY_TIMEOUT_MS = 10000; // 10 second timeout for bridge requests

// moomoo-bridge URL cache (avoid BQ query on every request)
let cachedBridgeUrl = null;
let lastFetchTime = 0;
const CACHE_TTL_MS = 60_000; // 1 minute

// moomoo-bridge ngrok URLをBigQueryから取得（with cache）
async function getMoomooBridgeUrl() {
  if (cachedBridgeUrl && (Date.now() - lastFetchTime < CACHE_TTL_MS)) {
    return cachedBridgeUrl;
  }
  const query = `
    SELECT url FROM \`screen-share-459802.magi_core.service_endpoints\`
    WHERE service = 'opend-proxy'
    ORDER BY updated_at DESC
    LIMIT 1
  `;
  const [rows] = await bigquery.query({ query });
  if (!rows.length) throw new Error('moomoo-bridge URL not found in BigQuery');
  cachedBridgeUrl = rows[0].url;
  lastFetchTime = Date.now();
  console.log('[CACHE] Bridge URL refreshed:', cachedBridgeUrl);
  return cachedBridgeUrl;
}

// Clear cached URL (called on connection errors so next request re-fetches)
function invalidateBridgeUrlCache() {
  cachedBridgeUrl = null;
  lastFetchTime = 0;
}

// moomoo-bridgeへプロキシリクエスト送信 (with timeout)
async function proxyToBridge(path, options = {}) {
  const baseUrl = await getMoomooBridgeUrl();
  const url = `${baseUrl}${path}`;
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), PROXY_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      ...options,
      signal: controller.signal,
    });
    const body = await res.json();
    return { status: res.status, body };
  } catch (e) {
    if (e.name === 'AbortError') {
      invalidateBridgeUrlCache();
      throw new Error('moomoo-bridge timeout');
    }
    // Connection errors (tunnel URL stale) → clear cache so next request re-fetches
    if (e.code === 'ENOTFOUND' || e.code === 'ECONNREFUSED' || e.code === 'ECONNRESET') {
      invalidateBridgeUrlCache();
    }
    throw e;
  } finally {
    clearTimeout(timeoutId);
  }
}

// ヘルスチェック
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'magi-moomoo', timestamp: new Date().toISOString() });
});

// URL確認（デバッグ用）
app.get('/url', async (req, res) => {
  try {
    const url = await getMoomooBridgeUrl();
    res.json({ url });
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
