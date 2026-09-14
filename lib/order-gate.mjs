/**
 * @module lib/order-gate
 * @description Server-side order boundary for POST /trade/place_order — the last
 * trusted checkpoint before the broker. Every order path (magi-core automated,
 * AKA-1 Telegram/manual, or any future caller) funnels through this proxy, so
 * the invariants that must hold for ALL callers live here rather than in any
 * single client.
 *
 * Enforced here:
 *   - parameter sanity (side, integer qty, hard qty ceiling — never trusted
 *     from the caller),
 *   - L0 kill switch, three states mirroring magi-core lib/kill-switch.js:
 *       HALTED  — confirmed trading_halted=true: reject everything.
 *       RUNNING — confirmed not halted: normal flow.
 *       UNKNOWN — system_control unreadable: reduce-only. During a BigQuery
 *         outage a fill cannot be journaled and approvals cannot be verified,
 *         so new exposure must not be opened; positions must stay closable.
 *         A confirmed HALTED stays latched across read failures (/resume
 *         writes through the same table, so an outage cannot have cleared it).
 *   - approval tokens: non-reducing orders require a single-use token from
 *     magi_core.order_approvals (event-sourced, append-only). Tokens are
 *     issued by magi-moni only after an actual operator confirmation, so the
 *     model's `confirmed=true` flag is no longer self-certifying.
 *     Position-reducing orders are exempt — unwinding risk is always allowed.
 *   - caller identity: when `trustedCallerEmails` is configured (env
 *     GATE_TRUSTED_CALLER_EMAILS), the trusted-pipeline exemption requires a
 *     Google-signed OIDC ID token whose `email` claim is in the allowlist —
 *     cryptographic proof of the caller's service account, not a
 *     caller-supplied label. Any other verified or unverifiable caller falls
 *     through to the approval-token requirement.
 *     When `trustedCallerEmails` is empty (pre-IAM rollout), the legacy
 *     `source='magi-core'` request-body label still grants the exemption —
 *     accepted-but-spoofable, so a warning is logged once per process.
 *
 * "Reducing" uses the R06 rule: a counter-direction order reduces only if it
 * moves the position toward zero WITHOUT crossing it. Missing/invalid order
 * qty or an unreadable position fails closed (treated as non-reducing).
 *
 * All dependencies are injected for testability.
 */

export const ORDER_QTY_MAX = 1000;
const KILL_SWITCH_TTL_MS = 30_000;

/**
 * R06 semantics: an order is risk-reducing only if it is counter-direction to
 * the existing position and does not cross zero.
 * @param {string} side - 'BUY' | 'SELL'
 * @param {number} existingQty - signed position qty (negative = short)
 * @param {number} orderQty - requested order qty
 */
export function isReducingOrder(side, existingQty, orderQty) {
  const s = String(side || '').toUpperCase();
  const eq = Number(existingQty);
  const oq = Number(orderQty);
  if (!Number.isFinite(oq) || oq <= 0) return false;
  if (!Number.isFinite(eq) || eq === 0) return false;
  if (s === 'SELL' && eq > 0) return oq <= eq;
  if (s === 'BUY' && eq < 0) return oq <= -eq;
  return false;
}

function reject(status, code, reason) {
  return { allow: false, status, code, reason };
}
const ALLOW = { allow: true, status: 200 };

/**
 * @param {object} deps
 * @param {(query: string, params?: object) => Promise<object[]>} deps.bqQuery
 * @param {() => Promise<object[]>} deps.getPositions - returns [{symbol, qty}] with signed qty
 * @param {string[]} [deps.trustedCallerEmails] - service-account emails allowed
 *   to skip the approval token (verified via OIDC ID token, not the body label)
 * @param {(idToken: string, platformVerified?: boolean) => Promise<object>} [deps.verifyIdToken] - verifies
 *   a caller ID token and returns its claims (throws on invalid token).
 *   `platformVerified=true` means the token arrived via
 *   X-Serverless-Authorization: Cloud Run IAM already validated and stripped
 *   its signature, so the verifier must validate claims only.
 * @param {() => number} [deps.now] - ms epoch
 */
export function createOrderGate({ bqQuery, getPositions, trustedCallerEmails = [], verifyIdToken = null, now = () => Date.now() }) {
  let _cache = null;
  let _cacheAt = 0;
  /** Last state confirmed by a successful BQ read. */
  let _lastConfirmed = null;
  const _trustedEmails = new Set(
    trustedCallerEmails.map(e => String(e).trim().toLowerCase()).filter(Boolean)
  );
  let _legacySourceWarned = false;

  async function killSwitchState() {
    const t = now();
    if (_cache && t - _cacheAt < KILL_SWITCH_TTL_MS) return _cache;
    try {
      const rows = await bqQuery(
        `SELECT trading_halted, reason, updated_by, updated_at
         FROM \`screen-share-459802.magi_core.system_control\`
         ORDER BY updated_at DESC
         LIMIT 1`
      );
      const row = rows && rows[0];
      _cache = {
        state: row?.trading_halted ? 'HALTED' : 'RUNNING',
        reason: row?.reason ?? null,
        updatedBy: row?.updated_by ?? null,
        updatedAt: row?.updated_at?.value ?? null
      };
      _lastConfirmed = _cache;
    } catch (e) {
      if (_lastConfirmed?.state === 'HALTED') {
        console.warn('[GATE] Kill-switch lookup failed; confirmed HALTED stays latched:', e.message);
        _cache = _lastConfirmed;
      } else {
        console.warn('[GATE] Kill-switch lookup failed — UNKNOWN (reduce-only):', e.message);
        _cache = { state: 'UNKNOWN', reason: null, updatedBy: null, updatedAt: null };
      }
    }
    _cacheAt = t;
    return _cache;
  }

  /** @returns {Promise<{reducing: boolean}>} fails closed: lookup failure → non-reducing */
  async function reducingCheck(symbol, side, qty) {
    try {
      const positions = await getPositions();
      const pos = (positions || []).find(p => p.symbol === symbol);
      const existingQty = pos ? parseFloat(pos.qty || 0) : 0;
      return { reducing: isReducingOrder(side, existingQty, qty) };
    } catch (e) {
      console.warn('[GATE] Position lookup failed — treating order as non-reducing:', e.message);
      return { reducing: false };
    }
  }

  /**
   * Verify and consume a single-use approval token. Consumption is an
   * append-only 'USED' event so it never touches the streaming buffer with
   * UPDATE/DELETE.
   * @returns {Promise<{ok: boolean, reason?: string}>}
   */
  async function verifyApproval({ token, symbol, side, qty }) {
    const issued = await bqQuery(
      `SELECT symbol, side, qty, created_by, expires_at
       FROM \`screen-share-459802.magi_core.order_approvals\`
       WHERE token = @token AND event = 'ISSUED'
       ORDER BY created_at DESC
       LIMIT 1`,
      { token }
    );
    const row = issued && issued[0];
    if (!row) return { ok: false, reason: 'approval token not found' };

    const expiresAt = row.expires_at?.value ? new Date(row.expires_at.value).getTime() : NaN;
    if (!Number.isFinite(expiresAt) || expiresAt <= now()) {
      return { ok: false, reason: 'approval token expired' };
    }
    if (String(row.symbol).toUpperCase() !== String(symbol).toUpperCase()
        || String(row.side).toUpperCase() !== String(side).toUpperCase()
        || Number(row.qty) !== Number(qty)) {
      return { ok: false, reason: 'approval token does not match order parameters' };
    }

    const used = await bqQuery(
      `SELECT 1 FROM \`screen-share-459802.magi_core.order_approvals\`
       WHERE token = @token AND event = 'USED'
       LIMIT 1`,
      { token }
    );
    if (used && used.length) return { ok: false, reason: 'approval token already used' };

    // Consume the token before forwarding so a broker retry/timeout cannot
    // let the same approval be replayed.
    await bqQuery(
      `INSERT INTO \`screen-share-459802.magi_core.order_approvals\`
       (token, event, symbol, side, qty, created_by, order_id, expires_at, created_at)
       VALUES (@token, 'USED', @symbol, @side, @qty, @created_by, NULL, NULL, CURRENT_TIMESTAMP())`,
      { token, symbol: String(symbol).toUpperCase(), side: String(side).toUpperCase(), qty: Number(qty), created_by: row.created_by ?? null }
    );
    return { ok: true };
  }

  /**
   * Verified trusted-caller check: returns claims when the caller presented a
   * valid ID token whose SA email is allowlisted, else null. Verification
   * failures never throw — an untrusted caller simply falls through to the
   * approval-token requirement (fail closed for the exemption only).
   */
  async function trustedCaller(idToken, platformVerified) {
    if (!_trustedEmails.size || !verifyIdToken || !idToken) return null;
    try {
      const claims = await verifyIdToken(idToken, platformVerified);
      const email = String(claims?.email || '').toLowerCase();
      if (email && _trustedEmails.has(email)) {
        console.log(`[GATE] trusted caller verified: ${email} (sub=${claims.sub || 'n/a'})`);
        return claims;
      }
      console.warn('[GATE] caller authenticated but not a trusted pipeline SA:', email || '(no email claim)');
    } catch (e) {
      console.warn('[GATE] caller ID token verification failed:', e.message);
    }
    return null;
  }

  /**
   * @param {{symbol: string, side: string, qty: number, approvalToken?: string, source?: string, idToken?: string, idTokenPlatformVerified?: boolean}} order
   * @returns {Promise<{allow: boolean, status: number, code?: string, reason?: string}>}
   */
  async function checkOrder({ symbol, side, qty, approvalToken, source, idToken, idTokenPlatformVerified = false }) {
    const s = String(side || '').toUpperCase();
    const q = Number(qty);
    if (!symbol || (s !== 'BUY' && s !== 'SELL')) {
      return reject(400, 'bad_params', 'symbol and side (BUY|SELL) are required');
    }
    if (!Number.isInteger(q) || q <= 0 || q > ORDER_QTY_MAX) {
      return reject(400, 'bad_qty', `qty must be a positive integer <= ${ORDER_QTY_MAX}`);
    }

    const ks = await killSwitchState();
    if (ks.state === 'HALTED') {
      return reject(403, 'kill_switch', `trading halted${ks.reason ? ': ' + ks.reason : ''}`);
    }

    const { reducing } = await reducingCheck(symbol, s, q);
    if (reducing) return ALLOW;

    if (ks.state === 'UNKNOWN') {
      return reject(403, 'reduce_only', 'system_control unreadable — only position-reducing orders allowed');
    }

    // RUNNING + non-reducing: the trusted magi-core pipeline already ran its
    // full guard chain; every other caller must present an operator approval.
    // Trust requires a verified OIDC identity — the `source` body label is
    // caller-supplied and spoofable, so it only counts while no allowlist is
    // configured (transition mode).
    if (_trustedEmails.size) {
      if (await trustedCaller(idToken, idTokenPlatformVerified)) return ALLOW;
    } else if (source === 'magi-core') {
      if (!_legacySourceWarned) {
        _legacySourceWarned = true;
        console.warn('[GATE] LEGACY MODE: unauthenticated source=magi-core label accepted — set GATE_TRUSTED_CALLER_EMAILS to require OIDC subject verification');
      }
      return ALLOW;
    }
    if (!approvalToken) {
      return reject(403, 'approval_required', 'non-reducing orders require an approval token');
    }
    let approval;
    try {
      approval = await verifyApproval({ token: approvalToken, symbol, side: s, qty: q });
    } catch (e) {
      console.error('[GATE] Approval verification failed:', e.message);
      return reject(403, 'approval_unverifiable', 'approval check failed — order blocked (fail closed)');
    }
    if (!approval.ok) return reject(403, 'approval_invalid', approval.reason);
    return ALLOW;
  }

  return { checkOrder, _reset: () => { _cache = null; _cacheAt = 0; _lastConfirmed = null; } };
}
