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

function makeGate({ controlRows = RUNNING_ROW, controlError = null, positions = [], positionsError = null, approvals = {}, usedTokens = new Set(), queries = null, trustedCallerEmails = [], verifyIdToken = null } = {}) {
  const calls = { bq: [], consumed: [] };
  const gate = createOrderGate({
    now: () => Date.now(),
    trustedCallerEmails,
    verifyIdToken,
    bqQuery: async (query, params = {}) => {
      calls.bq.push(query);
      if (query.includes('system_control')) {
        if (controlError) throw controlError;
        return controlRows;
      }
      if (query.includes('order_approvals')) {
        if (query.trimStart().toUpperCase().startsWith('INSERT')) {
          calls.consumed.push(params.token);
          usedTokens.add(params.token);
          return [];
        }
        if (query.includes("event = 'USED'")) {
          return usedTokens.has(params.token) ? [{ '?column?': 1 }] : [];
        }
        return approvals[params.token] ?? [];
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
  gate._reset === undefined; // cache not reset — TTL still valid
  const v = await gate.checkOrder(order());
  assert.equal(v.code, 'kill_switch'); // still latched
});

// --- approval tokens ---

test('non-reducing order with valid token passes and consumes it', async () => {
  const { gate, calls } = makeGate({ approvals: { [VALID_TOKEN]: VALID_APPROVAL_ROW }, positions: [] });
  const v = await gate.checkOrder(order({ approvalToken: VALID_TOKEN }));
  assert.equal(v.allow, true);
  assert.deepEqual(calls.consumed, [VALID_TOKEN]);
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

test('source=magi-core skips approval for non-reducing orders', async () => {
  const { gate } = makeGate({ positions: [] });
  assert.equal((await gate.checkOrder(order({ source: 'magi-core' }))).allow, true);
  const v = await gate.checkOrder(order({ source: 'magi-moni' }));
  assert.equal(v.allow, false);
  assert.equal(v.code, 'approval_required');
});

test('source=magi-core still blocked when HALTED or qty exceeds ceiling', async () => {
  const { gate: halted } = makeGate({ controlRows: HALTED_ROW });
  assert.equal((await halted.checkOrder(order({ source: 'magi-core' }))).code, 'kill_switch');
  const { gate: running } = makeGate();
  assert.equal((await running.checkOrder(order({ source: 'magi-core', qty: ORDER_QTY_MAX + 1 }))).status, 400);
});

test('source=magi-core still reduce-only during UNKNOWN', async () => {
  const { gate } = makeGate({ controlError: new Error('BQ down'), positions: [] });
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
