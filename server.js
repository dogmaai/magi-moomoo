import express from 'express';
import { BigQuery } from '@google-cloud/bigquery';
import fetch from 'node-fetch';

const app = express();
app.use(express.json());

const bigquery = new BigQuery({ projectId: 'screen-share-459802' });

const PROXY_TIMEOUT_MS = 10000; // 10 second timeout for bridge requests

// moomoo-bridge ngrok URLをBigQueryから取得
async function getMoomooBridgeUrl() {
  const query = `
    SELECT url FROM \`screen-share-459802.magi_core.service_endpoints\`
    WHERE service = 'opend-proxy'
    ORDER BY updated_at DESC
    LIMIT 1
  `;
  const [rows] = await bigquery.query({ query });
  if (!rows.length) throw new Error('moomoo-bridge URL not found in BigQuery');
  return rows[0].url;
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
      throw new Error('moomoo-bridge timeout');
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

export default app;
