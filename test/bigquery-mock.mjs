let callIndex = 0;
// token -> order_id claim stamped on the ISSUED row by the gate's
// conditional UPDATE (the consumption mutex)
const issuedClaims = new Map();

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
      // Atomic consume: BEGIN; UPDATE ISSUED SET order_id=claim WHERE
      // order_id IS NULL; INSERT USED audit row; COMMIT. Record the claim
      // so the follow-up ISSUED read-back returns it.
      if (sql.includes('BEGIN TRANSACTION')) {
        if (!issuedClaims.has(params.token)) issuedClaims.set(params.token, params.claim);
        return [[]];
      }
      if (sql.includes('SELECT order_id')) {
        return [issuedClaims.has(params.token) ? [{ order_id: issuedClaims.get(params.token) }] : []];
      }
      if (sql.includes("event = 'USED'")) {
        return [[]];
      }
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
