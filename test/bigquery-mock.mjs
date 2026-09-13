let callIndex = 0;

function getUrls() {
  const raw = process.env.TEST_BQ_URLS || 'http://localhost:9001';
  return raw.split(',').map((u) => u.trim()).filter(Boolean);
}

class BigQueryMock {
  constructor(opts) {
    this.opts = opts;
  }

  async query(config) {
    const sql = (config && config.query) || '';
    const params = (config && config.params) || {};

    // Order-gate queries (lib/order-gate.mjs)
    if (sql.includes('system_control')) {
      return [[{ trading_halted: false, reason: null, updated_by: 'test', updated_at: { value: new Date().toISOString() } }]];
    }
    if (sql.includes('order_approvals')) {
      if (sql.trimStart().toUpperCase().startsWith('INSERT')) return [[]];
      if (sql.includes("event = 'USED'")) return [[]];
      // ISSUED lookup: a valid single-use approval for TEST-APPROVAL (AAPL BUY 1)
      if (params.token === 'TEST-APPROVAL') {
        return [[{
          symbol: 'AAPL', side: 'BUY', qty: 1, created_by: 'test',
          expires_at: { value: new Date(Date.now() + 60_000).toISOString() }
        }]];
      }
      return [[]];
    }

    // service_endpoints: round-robin over TEST_BQ_URLS
    const urls = getUrls();
    const index = callIndex++;
    const url = urls[index % urls.length];
    const updatedAt = new Date().toISOString();
    console.log(`[BQ MOCK] query #${index} returning ${url}`);
    return [[{ url, updated_at_ts: { value: updatedAt } }]];
  }
}

export class BigQuery {
  constructor(opts) {
    return new BigQueryMock(opts);
  }
}
