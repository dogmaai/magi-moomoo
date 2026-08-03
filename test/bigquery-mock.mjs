let callIndex = 0;

function getUrls() {
  const raw = process.env.TEST_BQ_URLS || 'http://localhost:9001';
  return raw.split(',').map((u) => u.trim()).filter(Boolean);
}

class BigQueryMock {
  constructor(opts) {
    this.opts = opts;
  }

  async query(_config) {
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
