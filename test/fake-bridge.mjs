import express from 'express';
import { createWriteStream } from 'node:fs';
import { appendFile } from 'node:fs/promises';

const app = express();
app.use(express.json());

const PORT = process.env.FAKE_BRIDGE_PORT || 9001;
const LOG = process.env.FAKE_BRIDGE_LOG || '/tmp/fake-bridge.log';

const counts = {
  dead: { total: 0, get: 0, post: 0 },
  live: { total: 0, get: 0, post: 0 },
};

async function log(message) {
  const line = `[${new Date().toISOString()}] ${message}\n`;
  console.log(line.trim());
  await appendFile(LOG, line).catch(() => {});
}

// Dead routes: any request under /dead returns 503
app.all('/dead*', (req, res) => {
  counts.dead.total++;
  if (req.method === 'POST') counts.dead.post++;
  else counts.dead.get++;
  log(`[DEAD] ${req.method} ${req.path} (total dead=${counts.dead.total})`);
  res.status(503).json({ error: 'dead bridge', path: req.path, method: req.method });
});

// Health
app.get('/live/health', (req, res) => {
  counts.live.total++;
  counts.live.get++;
  log(`[LIVE] ${req.method} ${req.path} (total live=${counts.live.total})`);
  res.json({ status: 'ok', service: 'fake-bridge', trd_env: 'SIMULATE' });
});

app.get('/live/positions', (req, res) => {
  counts.live.total++;
  counts.live.get++;
  log(`[LIVE] ${req.method} ${req.path} (total live=${counts.live.total})`);
  res.json({ positions: [{ symbol: 'AAPL', qty: 1 }], cash: 10000 });
});

app.get('/live/quote', (req, res) => {
  counts.live.total++;
  counts.live.get++;
  log(`[LIVE] ${req.method} ${req.path} (total live=${counts.live.total})`);
  const symbol = req.query.symbol || 'AAPL';
  res.json({ symbol, last_price: 150.25, bid: 150.2, ask: 150.3 });
});

app.get('/live/bars', (req, res) => {
  counts.live.total++;
  counts.live.get++;
  log(`[LIVE] ${req.method} ${req.path} (total live=${counts.live.total})`);
  const symbol = req.query.symbol || 'AAPL';
  res.json({ symbol, bars: [{ close: 150.25 }] });
});

app.post('/live/place_order', (req, res) => {
  counts.live.total++;
  counts.live.post++;
  log(`[LIVE] ${req.method} ${req.path} body=${JSON.stringify(req.body)} (total live=${counts.live.total})`);
  res.json({ success: true, order_id: `fake-${Date.now()}` });
});

app.get('/counts/:side', (req, res) => {
  const side = req.params.side;
  res.json(counts[side] || { total: 0, get: 0, post: 0 });
});

app.post('/reset', (req, res) => {
  counts.dead = { total: 0, get: 0, post: 0 };
  counts.live = { total: 0, get: 0, post: 0 };
  res.json({ reset: true });
});

// Slow route to test timeout behavior (sends headers, then body after 15s)
app.get('/slow/positions', (req, res) => {
  counts.live.total++;
  counts.live.get++;
  log(`[SLOW] ${req.method} ${req.path} started, will hang 15s (timeout test)`);
  res.status(200);
  res.set({ 'Content-Type': 'application/json', 'Transfer-Encoding': 'chunked' });
  res.write('{"positions":[{"symbol":"SLOW","qty":1}]');
  setTimeout(() => {
    res.end(',"cash":10000}');
  }, 15000);
});

app.listen(PORT, () => {
  console.log(`Fake bridge listening on port ${PORT}`);
});
