/**
 * Unit tests for lib/order-gate.mjs — the server-side order boundary.
 * Run: node --test test/order-gate.test.mjs
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createOrderGate, isReducingOrder, ORDER_QTY_MAX } from '../lib/order-gate.mjs';

const HALTED_ROW = [{ trading_halted: true, reason: 'manual halt', updated_by: 'jun', updated_at: { value: '2026-09-13T00:00:00Z' } }];
const RUNNING_ROW = [{ trading_halted: false, reason: null, updated_by: 'jun', updated_at: { value: '2026-09-13T00:00:00Z' } }];

const VALID_TOKEN = 'tok-1';
const VALID_APPROVAL_ROW = [{
  symbol: 'AAPL', side: 'BUY', qty: 10, created_by: 'jun',
  expires_at: { value: new Date(Date.now() + 60_000).toISOString() }
}];

const TRUSTED_SA = 'magi-core-runner@screen-share-459802.iam.gserviceaccount.com';

/** Fake verifyIdToken: map token → claims; 'bad-token' throws (invalid signature etc.) */
function fakeVerifyIdToken(claimsByToken = {}) {
  return async (token) => {
    if (token === 'bad-token') throw new Error('invalid signature');
    const claims = claimsByToken[token];
    if (!claims) throw new Error('unknown token');
    return claims;
  };
}

function makeGate({ controlRows = RUNNING_ROW, controlError = null, positions = [], positionsError = null, approvals = {}, usedRows = [], queries = null, trustedCallerEmails = [], verifyIdToken = null, allowLegacySourceLabel = false, killSwitchTtlMs = 30_000, txInterleave = null, issuedReadbackRows = null } = {}) {
  const calls = { bq: [], used: usedRows, txAborts: 0 };
  let txVersion = 0;
  // Mutable per-test ISSUED rows so the claim UPDATE can stamp order_id.
  const issuedStore = Object.fromEntries(
    Object.entries(approvals).map(([k, rows]) => [k, rows.map(r => ({ ...r }))])
  );
  const gate = createOrderGate({
    now: () => Date.now(),
    trustedCallerEmails,
    verifyIdToken,
    allowLegacySourceLabel,
    killSwitchTtlMs,
    bqQuery: async (query, params = {}) => {
      calls.bq.push(query);
      if (query.includes('system_control')) {
        if (controlError) throw controlError;
        return typeof controlRows === 'function' ? controlRows() : controlRows;
      }
      if (query.includes('order_approvals')) {
        // Simulate BigQuery multi-statement transactions: the conditional
        // UPDATE stamps the claim on the token's ISSUED row, and concurrent
        // transactions writing the same row conflict — a stale-snapshot
        // commit aborts like a real concurrent update would.
        if (query.includes('BEGIN TRANSACTION')) {
          const snapshot = txVersion;
          const target = (issuedStore[params.token] ?? [])[0];
          const usedExists = calls.used.some(r => r.token === params.token);
          const canClaim = target && target.order_id == null && !usedExists;
          if (txInterleave) await txInterleave();
          if (snapshot !== txVersion) {
            calls.txAborts++;
            throw new Error('Transaction aborted due to a concurrent update to `screen-share-459802.magi_core.order_approvals`');
          }
          if (canClaim) {
            target.order_id = params.claim;
            calls.used.push({ token: params.token, order_id: params.claim });
            txVersion++;
          }
          return [];
        }
        if (query.includes('SELECT order_id')) {
          // Claim read-back on the ISSUED row.
          if (issuedReadbackRows) return issuedReadbackRows;
          return (issuedStore[params.token] ?? []).map(r => ({ order_id: r.order_id ?? null }));
        }
        if (query.includes("event = 'USED'")) {
          return calls.used.filter(r => r.token === params.token);
        }
        return issuedStore[params.token] ?? [];
      }
      throw new Error('unexpected query: ' + query);
    },
    getPositions: async () => {
      if (positionsError) throw positionsError;
      return positions;
    }
  });
  if (queries) queries.push = calls.bq;
  return { gate, calls };
}

const order = (over = {}) => ({ symbol: 'AAPL', side: 'BUY', qty: 10, ...over });

// --- isReducingOrder (R06 semantics) ---

test('isReducingOrder: counter-direction without crossing zero reduces', () => {
  assert.equal(isReducingOrder('SELL', 10, 5), true);
  assert.equal(isReducingOrder('SELL', 10, 10), true);   // exact flat
  assert.equal(isReducingOrder('SELL', 10, 15), false);  // overshoot → flip
  assert.equal(isReducingOrder('BUY', -10, 5), true);
  assert.equal(isReducingOrder('BUY', -10, 20), false);
  assert.equal(isReducingOrder('BUY', 10, 5), false);    // same direction = add
  assert.equal(isReducingOrder('SELL', 0, 5), false);    // no position
  assert.equal(isReducingOrder('BUY', -10, NaN), false); // fail closed
});

// --- parameter validation ---

test('bad params rejected', async () => {
  const { gate } = makeGate();
  for (const o of [
    order({ side: 'HOLD' }),
    order({ side: '' }),
    order({ symbol: '' }),
    order({ qty: 0 }),
    order({ qty: -5 }),
    order({ qty: 1.5 }),
    order({ qty: ORDER_QTY_MAX + 1 }),
    order({ qty: 'abc' })
  ]) {
    const v = await gate.checkOrder(o);
    assert.equal(v.allow, false, JSON.stringify(o));
    assert.equal(v.status, 400);
  }
  const ok = await gate.checkOrder(order({ qty: ORDER_QTY_MAX, approvalToken: VALID_TOKEN }));
  assert.equal(ok.status, 403); // reaches approval stage → token lookup (not found) = 403, not 400
});

// --- kill switch ---

test('HALTED blocks even reducing orders', async () => {
  const { gate } = makeGate({ controlRows: HALTED_ROW, positions: [{ symbol: 'AAPL', qty: '10' }] });
  const v = await gate.checkOrder(order({ side: 'SELL', qty: 5 }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'kill_switch');
});

test('RUNNING: reducing order passes without token; non-reducing requires token', async () => {
  const { gate } = makeGate({ controlRows: RUNNING_ROW, positions: [{ symbol: 'AAPL', qty: '10' }] });
  assert.equal((await gate.checkOrder(order({ side: 'SELL', qty: 5 }))).allow, true);
  const v = await gate.checkOrder(order({ side: 'BUY', qty: 5 }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_required');
});

test('UNKNOWN (control read fails): reduce-only, non-reducing blocked even with token', async () => {
  const { gate } = makeGate({
    controlError: new Error('BQ down'),
    positions: [{ symbol: 'AAPL', qty: '10' }],
    approvals: { [VALID_TOKEN]: VALID_APPROVAL_ROW }
  });
  assert.equal((await gate.checkOrder(order({ side: 'SELL', qty: 5 }))).allow, true);
  const v = await gate.checkOrder(order({ side: 'BUY', qty: 5, approvalToken: VALID_TOKEN }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'reduce_only');
});

test('UNKNOWN with positions lookup failure → everything non-reducing → blocked', async () => {
  const { gate } = makeGate({ controlError: new Error('BQ down'), positionsError: new Error('bridge down') });
  const v = await gate.checkOrder(order({ side: 'SELL', qty: 5 }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'reduce_only');
});

test('HALTED latches across a subsequent read failure', async () => {
  let fail = false;
  const gate = createOrderGate({
    killSwitchTtlMs: 0, // force a fresh read on every check so the latch (not the cache) is exercised
    bqQuery: async (q, p = {}) => {
      if (q.includes('system_control')) {
        if (fail) throw new Error('BQ down');
        return HALTED_ROW;
      }
      return [];
    },
    getPositions: async () => []
  });
  await gate.checkOrder(order()); // confirms HALTED
  fail = true;
  const v = await gate.checkOrder(order());
  assert.equal(v.code, 'kill_switch'); // still latched
});

test('empty control table → UNKNOWN (reduce-only), not RUNNING', async () => {
  const { gate } = makeGate({ controlRows: [], positions: [{ symbol: 'AAPL', qty: '10' }] });
  assert.equal((await gate.checkOrder(order({ side: 'SELL', qty: 5 }))).allow, true); // reducing still allowed
  const v = await gate.checkOrder(order({ side: 'BUY', qty: 5 }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'reduce_only');
});

test('NULL or non-boolean trading_halted → UNKNOWN', async () => {
  for (const bad of [null, 'true', 1, 'false', 0]) {
    const { gate } = makeGate({ controlRows: [{ trading_halted: bad, reason: null, updated_by: 'x', updated_at: { value: '2026-09-13T00:00:00Z' } }], positions: [] });
    const v = await gate.checkOrder(order());
    assert.equal(v.allow, false, `trading_halted=${String(bad)} should be UNKNOWN`);
    assert.equal(v.code, 'reduce_only');
  }
});

test('confirmed HALTED stays latched when the table later returns 0 rows', async () => {
  let calls = 0;
  const { gate } = makeGate({
    killSwitchTtlMs: 0,
    controlRows: () => (calls++ === 0 ? HALTED_ROW : [])
  });
  assert.equal((await gate.checkOrder(order())).code, 'kill_switch');
  const v = await gate.checkOrder(order());
  assert.equal(v.code, 'kill_switch'); // empty result does NOT clear a confirmed halt
});

test('RUNNING → empty result degrades to UNKNOWN, then recovers to RUNNING', async () => {
  const states = [RUNNING_ROW, [], RUNNING_ROW];
  let i = 0;
  const { gate } = makeGate({
    killSwitchTtlMs: 0,
    controlRows: () => states[Math.min(i++, states.length - 1)],
    allowLegacySourceLabel: true,
    positions: []
  });
  assert.equal((await gate.checkOrder(order({ source: 'magi-core' }))).allow, true);   // RUNNING
  assert.equal((await gate.checkOrder(order({ source: 'magi-core' }))).code, 'reduce_only'); // UNKNOWN
  assert.equal((await gate.checkOrder(order({ source: 'magi-core' }))).allow, true);   // recovered
});

// --- approval tokens ---

test('non-reducing order with valid token passes and consumes it', async () => {
  const { gate, calls } = makeGate({ approvals: { [VALID_TOKEN]: VALID_APPROVAL_ROW }, positions: [] });
  const v = await gate.checkOrder(order({ approvalToken: VALID_TOKEN }));
  assert.equal(v.allow, true);
  assert.equal(calls.used.length, 1);
  assert.equal(calls.used[0].token, VALID_TOKEN);
  assert.match(calls.used[0].order_id, /^claim:/);
});

test('used token rejected (single-use)', async () => {
  const { gate } = makeGate({ approvals: { [VALID_TOKEN]: VALID_APPROVAL_ROW }, positions: [] });
  assert.equal((await gate.checkOrder(order({ approvalToken: VALID_TOKEN }))).allow, true);
  const v = await gate.checkOrder(order({ approvalToken: VALID_TOKEN }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_invalid');
});

test('expired / mismatched / unknown tokens rejected', async () => {
  const expired = [{ ...VALID_APPROVAL_ROW[0], expires_at: { value: new Date(Date.now() - 1000).toISOString() } }];
  const mismatch = [{ ...VALID_APPROVAL_ROW[0], qty: 99 }];
  const { gate } = makeGate({
    approvals: { expired: expired, mismatch: mismatch },
    positions: []
  });
  for (const [token, o] of [
    ['expired', order({ approvalToken: 'expired' })],
    ['mismatch', order({ approvalToken: 'mismatch' })],
    ['nope', order({ approvalToken: 'nope' })]
  ]) {
    const v = await gate.checkOrder(o);
    assert.equal(v.allow, false, token);
    assert.equal(v.code, 'approval_invalid');
  }
});

test('approval table failure fails closed', async () => {
  const gate = createOrderGate({
    bqQuery: async (q) => {
      if (q.includes('system_control')) return RUNNING_ROW;
      throw new Error('order_approvals missing');
    },
    getPositions: async () => []
  });
  const v = await gate.checkOrder(order({ approvalToken: 'x' }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_unverifiable');
});

test('legacy source label: honored only with explicit allowLegacySourceLabel opt-in', async () => {
  const { gate: legacy } = makeGate({ positions: [], allowLegacySourceLabel: true });
  assert.equal((await legacy.checkOrder(order({ source: 'magi-core' }))).allow, true);
  const v = await legacy.checkOrder(order({ source: 'magi-moni' }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_required');
});

test('legacy source label: default-off — no allowlist means approval tokens are required', async () => {
  const { gate } = makeGate({ positions: [] });
  const v = await gate.checkOrder(order({ source: 'magi-core' }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_required');
});

test('source=magi-core still blocked when HALTED or qty exceeds ceiling', async () => {
  const { gate: halted } = makeGate({ controlRows: HALTED_ROW, allowLegacySourceLabel: true });
  assert.equal((await halted.checkOrder(order({ source: 'magi-core' }))).code, 'kill_switch');
  const { gate: running } = makeGate({ allowLegacySourceLabel: true });
  assert.equal((await running.checkOrder(order({ source: 'magi-core', qty: ORDER_QTY_MAX + 1 }))).status, 400);
});

test('source=magi-core still reduce-only during UNKNOWN', async () => {
  const { gate } = makeGate({ controlError: new Error('BQ down'), positions: [], allowLegacySourceLabel: true });
  assert.equal((await gate.checkOrder(order({ source: 'magi-core' }))).code, 'reduce_only');
});

// --- OIDC trusted-caller verification ---

test('OIDC: verified trusted SA email allows non-reducing order (no approval token, no source label)', async () => {
  const { gate } = makeGate({
    positions: [],
    trustedCallerEmails: [TRUSTED_SA],
    verifyIdToken: fakeVerifyIdToken({ 'core-tok': { email: TRUSTED_SA, sub: '12345' } })
  });
  const v = await gate.checkOrder(order({ idToken: 'core-tok' }));
  assert.equal(v.allow, true);
});

test('OIDC: source=magi-core body label no longer authorizes once the allowlist is set', async () => {
  const { gate } = makeGate({
    positions: [],
    trustedCallerEmails: [TRUSTED_SA],
    verifyIdToken: fakeVerifyIdToken({ 'core-tok': { email: TRUSTED_SA } })
  });
  const v = await gate.checkOrder(order({ source: 'magi-core' }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_required');
});

test('OIDC: verified non-trusted email falls through to approval requirement', async () => {
  const { gate } = makeGate({
    positions: [],
    trustedCallerEmails: [TRUSTED_SA],
    verifyIdToken: fakeVerifyIdToken({ 'other-tok': { email: 'other@screen-share-459802.iam.gserviceaccount.com' } })
  });
  const v = await gate.checkOrder(order({ idToken: 'other-tok' }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_required');
});

test('OIDC: invalid/missing token is not trusted; valid approval token still authorizes', async () => {
  const { gate } = makeGate({
    positions: [],
    trustedCallerEmails: [TRUSTED_SA],
    verifyIdToken: fakeVerifyIdToken(),
    approvals: { [VALID_TOKEN]: VALID_APPROVAL_ROW }
  });
  assert.equal((await gate.checkOrder(order({ idToken: 'bad-token' }))).code, 'approval_required');
  assert.equal((await gate.checkOrder(order({}))).code, 'approval_required');
  const ok = await gate.checkOrder(order({ idToken: 'bad-token', approvalToken: VALID_TOKEN }));
  assert.equal(ok.allow, true);
});

test('OIDC: idTokenPlatformVerified flag is forwarded to the verifier', async () => {
  const seen = [];
  const verifyIdToken = async (token, platformVerified) => {
    seen.push(platformVerified);
    return { email: TRUSTED_SA };
  };
  const { gate } = makeGate({ positions: [], trustedCallerEmails: [TRUSTED_SA], verifyIdToken });
  await gate.checkOrder(order({ idToken: 'tok', idTokenPlatformVerified: true }));
  await gate.checkOrder(order({ idToken: 'tok' }));
  assert.deepEqual(seen, [true, false]);
});

test('OIDC: trusted caller still blocked by HALTED and by UNKNOWN reduce-only', async () => {
  const deps = {
    trustedCallerEmails: [TRUSTED_SA],
    verifyIdToken: fakeVerifyIdToken({ 'core-tok': { email: TRUSTED_SA } })
  };
  const { gate: halted } = makeGate({ ...deps, controlRows: HALTED_ROW });
  assert.equal((await halted.checkOrder(order({ idToken: 'core-tok' }))).code, 'kill_switch');
  const { gate: unknown } = makeGate({ ...deps, controlError: new Error('BQ down'), positions: [] });
  assert.equal((await unknown.checkOrder(order({ idToken: 'core-tok' }))).code, 'reduce_only');
});

test('OIDC: allowlist match is case-insensitive', async () => {
  const { gate } = makeGate({
    positions: [],
    trustedCallerEmails: ['Magi-Core-Runner@SCREEN-SHARE-459802.iam.gserviceaccount.com'],
    verifyIdToken: fakeVerifyIdToken({ 'core-tok': { email: TRUSTED_SA } })
  });
  assert.equal((await gate.checkOrder(order({ idToken: 'core-tok' }))).allow, true);
});

test('reducing order does not touch the approvals table', async () => {
  const { gate, calls } = makeGate({ positions: [{ symbol: 'AAPL', qty: '-10' }] });
  assert.equal((await gate.checkOrder(order({ side: 'BUY', qty: 5 }))).allow, true);
  assert.equal(calls.bq.filter(q => q.includes('order_approvals')).length, 0);
});

// --- concurrent approval-token consumption ---

test('concurrent requests with the same token: at most one reaches the broker', async () => {
  const { gate, calls } = makeGate({
    approvals: { [VALID_TOKEN]: VALID_APPROVAL_ROW },
    positions: [],
    // Force every transaction to yield mid-commit so the two consumers
    // genuinely interleave (both evaluate NOT EXISTS on the same snapshot).
    txInterleave: () => new Promise(r => setImmediate(r))
  });
  const results = await Promise.all([
    gate.checkOrder(order({ approvalToken: VALID_TOKEN })),
    gate.checkOrder(order({ approvalToken: VALID_TOKEN }))
  ]);
  const allowed = results.filter(r => r.allow);
  const denied = results.filter(r => !r.allow);
  assert.equal(allowed.length, 1, `expected exactly one winner, got ${JSON.stringify(results)}`);
  assert.equal(denied.length, 1);
  assert.equal(denied[0].code, 'approval_invalid');
  assert.match(denied[0].reason, /already used|unconfirmed/);
  assert.equal(calls.used.length, 1); // a single USED event, claimed by the winner
  assert.ok(calls.txAborts >= 1, 'expected the loser to abort on concurrent update');
});

test('legacy pre-claimed USED row (order_id NULL) still blocks reuse', async () => {
  const { gate } = makeGate({
    approvals: { [VALID_TOKEN]: VALID_APPROVAL_ROW },
    usedRows: [{ token: VALID_TOKEN, order_id: null }],
    positions: []
  });
  const v = await gate.checkOrder(order({ approvalToken: VALID_TOKEN }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_invalid');
  assert.match(v.reason, /already used/);
});

test('claim committed but read-back unreadable → fail closed, no order sent', async () => {
  const { gate } = makeGate({
    approvals: { [VALID_TOKEN]: VALID_APPROVAL_ROW },
    positions: [],
    issuedReadbackRows: [] // consumption unconfirmed → treat as a loss
  });
  const v = await gate.checkOrder(order({ approvalToken: VALID_TOKEN }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_invalid');
  assert.match(v.reason, /unconfirmed/);
});

test('concurrent aborts exhaust retries → fail closed', async () => {
  const gate = createOrderGate({
    killSwitchTtlMs: 0,
    bqQuery: async (q) => {
      if (q.includes('system_control')) return RUNNING_ROW;
      if (q.includes('order_approvals')) {
        if (q.includes('BEGIN TRANSACTION')) {
          throw new Error('Transaction aborted due to a concurrent update');
        }
        if (q.includes("event = 'ISSUED'")) return VALID_APPROVAL_ROW;
        return [];
      }
      throw new Error('unexpected query');
    },
    getPositions: async () => []
  });
  const v = await gate.checkOrder(order({ approvalToken: VALID_TOKEN }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_unverifiable');
});
