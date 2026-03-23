import express from 'express';
import { BigQuery } from '@google-cloud/bigquery';
import fetch from 'node-fetch';

const app = express();
app.use(express.json());

const bigquery = new BigQuery({ projectId: 'screen-share-459802' });

// ngrok URLをBigQueryから取得
async function getOpenDUrl() {
  const query = `
    SELECT url FROM \`screen-share-459802.magi_core.service_endpoints\`
    WHERE service = 'opend-proxy'
    ORDER BY updated_at DESC
    LIMIT 1
  `;
  const [rows] = await bigquery.query({ query });
  if (!rows.length) throw new Error('opend-proxy URL not found in BigQuery');
  return rows[0].url;
}

// OpenDへHTTPリクエスト送信
async function callOpenD(payload) {
  const baseUrl = await getOpenDUrl();
  const res = await fetch(`${baseUrl}/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/octet-stream' },
    body: Buffer.from(JSON.stringify(payload))
  });
  const body = await res.buffer();
  return body;
}

// ヘルスチェック
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'magi-moomoo', timestamp: new Date().toISOString() });
});

// URL確認（デバッグ用）
app.get('/url', async (req, res) => {
  try {
    const url = await getOpenDUrl();
    res.json({ url });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 残高確認
app.get('/account', async (req, res) => {
  try {
    const url = await getOpenDUrl();
    res.json({ 
      message: 'OpenD connected',
      opend_url: url,
      note: 'Full account API requires moomoo SDK - Phase 2'
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 発注（Phase 1はURL疎通確認のみ）
app.post('/order', async (req, res) => {
  const { symbol, side, qty } = req.body;
  if (!symbol || !side || !qty) {
    return res.status(400).json({ error: 'symbol, side, qty are required' });
  }
  try {
    const url = await getOpenDUrl();
    res.json({
      status: 'phase1_ok',
      message: 'OpenD URL resolved. Full order execution in Phase 2.',
      opend_url: url,
      order: { symbol, side, qty }
    });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

export default app;
