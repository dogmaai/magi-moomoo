#!/usr/bin/env python3
"""
moomoo_bridge.py — Flask REST bridge between magi-moomoo Cloud Run proxy and
MooMoo OpenD.  Runs on TIALA alongside OpenD; exposed via ngrok.

Endpoints
---------
POST /place_order      Place a market/limit order (paper trading)
GET  /positions        List open positions
GET  /account_info     Account balance & buying power
GET  /order/<order_id> Get order status / fill details
GET  /snapshot         Batch market snapshot for multiple symbols
GET  /orderbook        Order book (bid/ask depth) for a symbol
GET  /order_history    Historical order list
GET  /health           Liveness check

Environment
-----------
OPEND_HOST                OpenD TCP host         (default 127.0.0.1)
OPEND_PORT                OpenD TCP port         (default 11111)
SECURITY_FIRM             SecurityFirm enum      (default FUTUINC; FUTUJP for JP REAL account)
TRD_MARKET                Filter market          (default US)
TRD_ENV                   SIMULATE | REAL        (default SIMULATE)
MOOMOO_ACC_ID             Pin account id         (REAL: required; SIMULATE: 0=auto-discover)
MOOMOO_TRADE_PASSWORD     Trade unlock password  (REAL only; or use _MD5 variant)
MOOMOO_TRADE_PASSWORD_MD5 Pre-computed MD5        (REAL only; alternative to plaintext)
MOOMOO_ALLOW_REAL_ORDERS  true to allow REAL order placement (default false = read-only)
"""

import os
import time
import logging
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from flask import Flask, request, jsonify
from moomoo import (
    OpenSecTradeContext,
    OpenQuoteContext,
    TrdEnv,
    TrdSide,
    TrdMarket,
    OrderType,
    RET_OK,
    SecurityFirm,
    SubType,
    KLType,
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
OPEND_HOST = os.environ.get("OPEND_HOST", "127.0.0.1")
OPEND_PORT = int(os.environ.get("OPEND_PORT", "11111"))
# SecurityFirm enum. FUTUJP (moomoo Japan) holds the JP production (REAL)
# comprehensive account; older SDKs may not define every value, so the map is
# built defensively from whatever the installed SDK exposes.
SECURITY_FIRM_MAP = {
    name: getattr(SecurityFirm, name)
    for name in ("FUTUINC", "FUTUSECURITIES", "FUTUJP", "FUTUSG", "FUTUAU")
    if hasattr(SecurityFirm, name)
}
SECURITY_FIRM = SECURITY_FIRM_MAP.get(
    os.environ.get("SECURITY_FIRM", "FUTUINC").upper(), SecurityFirm.FUTUINC
)
TRD_MARKET_MAP = {
    "US": TrdMarket.US,
    "HK": TrdMarket.HK,
}
TRD_MARKET = TRD_MARKET_MAP.get(os.environ.get("TRD_MARKET", "US"), TrdMarket.US)

# Trading environment. Defaults to SIMULATE (paper trading) for safety; REAL is
# strictly opt-in via TRD_ENV=REAL and order placement is additionally gated.
_TRD_ENV_NAME = os.environ.get("TRD_ENV", "SIMULATE").upper()
IS_REAL = _TRD_ENV_NAME == "REAL"
TRD_ENV = TrdEnv.REAL if IS_REAL else TrdEnv.SIMULATE
TRD_ENV_STR = "REAL" if IS_REAL else "SIMULATE"

# Real-money order placement is blocked unless explicitly enabled. Reading
# account info / positions in REAL is allowed; placing REAL orders requires
# BOTH TRD_ENV=REAL and MOOMOO_ALLOW_REAL_ORDERS=true.
ALLOW_REAL_ORDERS = os.environ.get("MOOMOO_ALLOW_REAL_ORDERS", "false").lower() == "true"

# Trade unlock credentials for REAL trading (unused in SIMULATE). Never hardcode
# — supply via env / Secret Manager. Provide plaintext OR a pre-computed MD5.
TRADE_PASSWORD = os.environ.get("MOOMOO_TRADE_PASSWORD") or None
TRADE_PASSWORD_MD5 = os.environ.get("MOOMOO_TRADE_PASSWORD_MD5") or None

# Pin a specific account by ID.
# SIMULATE: if MOOMOO_ACC_ID is 0 (default), auto-discover the US
# STOCK_AND_OPTION account on first trade context use.
# REAL: MOOMOO_ACC_ID MUST be set explicitly (no auto-discovery in REAL, to
# avoid selecting the wrong sub-account, e.g. CASH/DERIVATIVES).
MOOMOO_ACC_ID = int(os.environ.get("MOOMOO_ACC_ID", "0"))

# Target sim_acc_type for auto-discovery (per MooMoo support guidance).
# US market → STOCK_AND_OPTION, HK market → STOCK
_TARGET_SIM_TYPE = {
    "US": "STOCK_AND_OPTION",
    "HK": "STOCK",
}
_SIM_ACC_TYPE_TARGET = _TARGET_SIM_TYPE.get(
    os.environ.get("TRD_MARKET", "US"), "STOCK_AND_OPTION"
)

ORDER_TYPE_MAP = {
    "MARKET": OrderType.MARKET,
    "NORMAL": OrderType.NORMAL,
    "LIMIT": OrderType.NORMAL,
}
TRD_SIDE_MAP = {
    "BUY": TrdSide.BUY,
    "SELL": TrdSide.SELL,
}
KTYPE_MAP = {
    "1Day": KLType.K_DAY,
    "1Min": KLType.K_1M,
    "5Min": KLType.K_5M,
    "15Min": KLType.K_15M,
    "60Min": KLType.K_60M,
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("moomoo-bridge")


def _safe_float(val, default=0.0):
    """Convert a value to float, returning *default* for 'N/A' or invalid."""
    if val is None or val == "N/A" or val == "":
        return default
    try:
        return float(val)
    except (ValueError, TypeError):
        return default

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Context helpers  — lazy-init, reconnect on failure
# ---------------------------------------------------------------------------
_trd_ctx = None
_quote_ctx = None
_trade_unlocked = False


def _unlock_trade_if_real(trd_ctx):
    """Unlock trading for REAL env. No-op for SIMULATE.

    Query APIs (account info / positions) work without unlocking, but order
    placement requires a successful unlock. Failure is logged, not fatal, so
    read-only endpoints keep working.
    """
    global _trade_unlocked
    if not IS_REAL or _trade_unlocked:
        return
    if not TRADE_PASSWORD and not TRADE_PASSWORD_MD5:
        log.warning(
            "[UNLOCK] REAL env but no MOOMOO_TRADE_PASSWORD/_MD5 set; trading "
            "APIs remain locked (read-only queries still work)"
        )
        return
    try:
        ret, data = trd_ctx.unlock_trade(
            password=TRADE_PASSWORD, password_md5=TRADE_PASSWORD_MD5,
        )
        if ret == RET_OK:
            _trade_unlocked = True
            log.info("[UNLOCK] REAL trade unlock succeeded")
        else:
            log.error("[UNLOCK] REAL trade unlock failed: %s", data)
    except Exception:
        log.exception("[UNLOCK] Exception during unlock_trade")


def _discover_simulate_acc_id(trd_ctx):
    """Auto-discover the correct SIMULATE account for the configured market.

    Queries get_acc_list() and selects the SIMULATE account whose
    sim_acc_type matches the target (e.g. STOCK_AND_OPTION for US).
    Returns the acc_id (int) or 0 if discovery fails.
    """
    global MOOMOO_ACC_ID
    try:
        ret, data = trd_ctx.get_acc_list()
        if ret != RET_OK:
            log.warning("[ACC_DISCOVERY] get_acc_list failed: %s", data)
            return 0

        candidates = []
        for _, row in data.iterrows():
            trd_env = str(row.get("trd_env", ""))
            if trd_env != "SIMULATE":
                continue
            sim_type = str(row.get("sim_acc_type", ""))
            acc_id = int(row.get("acc_id", 0))
            candidates.append({"acc_id": acc_id, "sim_acc_type": sim_type})
            log.info("[ACC_DISCOVERY] Found SIMULATE account: acc_id=%d sim_acc_type=%s", acc_id, sim_type)

        # Prefer exact match on target sim_acc_type
        for c in candidates:
            if c["sim_acc_type"] == _SIM_ACC_TYPE_TARGET:
                MOOMOO_ACC_ID = c["acc_id"]
                log.info(
                    "[ACC_DISCOVERY] Auto-selected acc_id=%d (sim_acc_type=%s)",
                    MOOMOO_ACC_ID, _SIM_ACC_TYPE_TARGET,
                )
                return MOOMOO_ACC_ID

        # Fallback: use first SIMULATE account
        if candidates:
            MOOMOO_ACC_ID = candidates[0]["acc_id"]
            log.warning(
                "[ACC_DISCOVERY] No %s account found, falling back to acc_id=%d (sim_acc_type=%s)",
                _SIM_ACC_TYPE_TARGET, MOOMOO_ACC_ID, candidates[0]["sim_acc_type"],
            )
            return MOOMOO_ACC_ID

        log.error("[ACC_DISCOVERY] No SIMULATE accounts found")
        return 0

    except Exception as e:
        log.exception("[ACC_DISCOVERY] Exception during account discovery")
        return 0


def _get_trd_ctx():
    """Return (or create) a persistent trade context.

    On first connection, if MOOMOO_ACC_ID is 0 (not manually set),
    auto-discovers the correct SIMULATE account.
    """
    global _trd_ctx
    if _trd_ctx is None:
        log.info(
            "Connecting trade context → %s:%s (market=%s, firm=%s, env=%s)",
            OPEND_HOST, OPEND_PORT, TRD_MARKET, SECURITY_FIRM, TRD_ENV_STR,
        )
        _trd_ctx = OpenSecTradeContext(
            filter_trdmarket=TRD_MARKET,
            host=OPEND_HOST,
            port=OPEND_PORT,
            security_firm=SECURITY_FIRM,
        )
        if IS_REAL:
            if MOOMOO_ACC_ID == 0:
                log.error(
                    "[ACC] REAL env requires MOOMOO_ACC_ID to be set "
                    "explicitly; none provided (acc_id=0)"
                )
            _unlock_trade_if_real(_trd_ctx)
        elif MOOMOO_ACC_ID == 0:
            _discover_simulate_acc_id(_trd_ctx)
    return _trd_ctx


def _get_quote_ctx():
    """Return (or create) a persistent quote context."""
    global _quote_ctx
    if _quote_ctx is None:
        log.info("Connecting quote context → %s:%s", OPEND_HOST, OPEND_PORT)
        _quote_ctx = OpenQuoteContext(host=OPEND_HOST, port=OPEND_PORT)
    return _quote_ctx


def _reset_trd_ctx():
    """Close and discard the trade context so next call reconnects."""
    global _trd_ctx, _trade_unlocked
    if _trd_ctx is not None:
        try:
            _trd_ctx.close()
        except Exception:
            pass
        _trd_ctx = None
    _trade_unlocked = False


def _reset_quote_ctx():
    """Close and discard the quote context so next call reconnects."""
    global _quote_ctx
    if _quote_ctx is not None:
        try:
            _quote_ctx.close()
        except Exception:
            pass
        _quote_ctx = None


# ---------------------------------------------------------------------------
# Symbol conversion helpers
# ---------------------------------------------------------------------------
def _to_moomoo_code(symbol: str) -> str:
    """Convert MAGI symbol (e.g. 'AAPL') → MooMoo code ('US.AAPL')."""
    if "." in symbol:
        return symbol
    return f"US.{symbol}"


def _to_magi_symbol(code: str) -> str:
    """Convert MooMoo code ('US.AAPL') → MAGI symbol ('AAPL')."""
    if "." in code:
        return code.split(".", 1)[1]
    return code


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.route("/health", methods=["GET"])
def health():
    return jsonify({
        "status": "ok",
        "service": "moomoo-bridge",
        "opend": f"{OPEND_HOST}:{OPEND_PORT}",
        "trd_env": TRD_ENV_STR,
        "security_firm": os.environ.get("SECURITY_FIRM", "FUTUINC").upper(),
        "trd_market": os.environ.get("TRD_MARKET", "US"),
        "acc_id": MOOMOO_ACC_ID,
        "acc_id_source": "env" if os.environ.get("MOOMOO_ACC_ID") else "auto-discovered",
        "target_sim_acc_type": _SIM_ACC_TYPE_TARGET,
        "real_orders_enabled": (IS_REAL and ALLOW_REAL_ORDERS),
        "trade_unlocked": _trade_unlocked,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    })


@app.route("/place_order", methods=["POST"])
def place_order():
    """
    Place a paper-trading order.

    Request JSON:
        symbol      str   e.g. "AAPL"
        side        str   "BUY" or "SELL"
        qty         int   number of shares
        price       float (required for NORMAL/LIMIT; ignored for MARKET)
        order_type  str   "MARKET" (default) or "NORMAL"/"LIMIT"
        remark      str   optional (max 64 bytes utf-8)

    Response JSON:
        success     bool
        order_id    str
        filled_price float|null
        filled_qty  float|null
        status      str   e.g. "FILLED_ALL", "SUBMITTING"
    """
    body = request.get_json(force=True, silent=True) or {}
    symbol = body.get("symbol")
    side_str = (body.get("side") or "").upper()
    qty = body.get("qty")
    price = float(body.get("price", 0))
    order_type_str = (body.get("order_type") or "MARKET").upper()
    remark = (body.get("remark") or "")[:64]

    if not symbol or not side_str or not qty:
        return jsonify({"success": False, "error": "symbol, side, qty required"}), 400

    # Safety gate: real-money orders are blocked unless explicitly enabled.
    if IS_REAL and not ALLOW_REAL_ORDERS:
        log.warning(
            "[ORDER] Blocked: REAL order placement is disabled "
            "(set MOOMOO_ALLOW_REAL_ORDERS=true to enable)"
        )
        return jsonify({
            "success": False,
            "error": "REAL order placement is disabled on this bridge (read-only mode)",
        }), 403

    trd_side = TRD_SIDE_MAP.get(side_str)
    if trd_side is None:
        return jsonify({"success": False, "error": f"Invalid side: {side_str}"}), 400

    order_type = ORDER_TYPE_MAP.get(order_type_str, OrderType.MARKET)
    code = _to_moomoo_code(symbol)

    # Always convert MARKET → LIMIT for paper trading (SIMULATE).
    # MooMoo SDK rejects MARKET orders with "Can only place RTH market
    # orders" — even during apparent RTH on holidays and sometimes on
    # normal trading days.  Using LIMIT at last-traded price is reliable
    # in all conditions and behaves identically for paper trading.
    request_price = price  # caller-supplied hint (e.g. currentPrice from AUTO_CLOSE)
    auto_limit = False
    if order_type == OrderType.MARKET and TRD_ENV == TrdEnv.SIMULATE:
        snapshot_price = 0.0
        try:
            quote_ctx = _get_quote_ctx()
            qret, qdata = quote_ctx.get_market_snapshot([code])
            if qret == RET_OK and len(qdata) > 0:
                snapshot_price = _safe_float(qdata.iloc[0].get("last_price"))
        except Exception as qe:
            log.warning("[ORDER] Quote fetch for auto-limit failed: %s", qe)

        limit_price = snapshot_price if snapshot_price > 0 else request_price
        if limit_price > 0:
            price = limit_price
            order_type = OrderType.NORMAL  # LIMIT
            auto_limit = True
            source = "snapshot" if snapshot_price > 0 else "request_hint"
            log.info("[ORDER] Auto-converted MARKET→LIMIT@%.2f (%s)", price, source)
        else:
            log.error("[ORDER] Cannot auto-convert MARKET→LIMIT: no price available (snapshot=%.2f, request=%.2f)", snapshot_price, request_price)
            return jsonify({"success": False, "error": "No price available for LIMIT conversion; MARKET orders not supported in SIMULATE"}), 400

    log.info(
        "[ORDER] %s %s x%s type=%s price=%.2f remark=%s",
        side_str, code, qty, order_type_str, price, remark,
    )

    try:
        trd_ctx = _get_trd_ctx()
        ret, data = trd_ctx.place_order(
            price=price,
            qty=float(qty),
            code=code,
            trd_side=trd_side,
            order_type=order_type,
            trd_env=TRD_ENV,
            acc_id=MOOMOO_ACC_ID,
            fill_outside_rth=True,
            remark=remark or None,
        )

        if ret != RET_OK:
            log.error("[ORDER] place_order failed: %s", data)
            _reset_trd_ctx()
            return jsonify({"success": False, "error": str(data)}), 500

        # data is a DataFrame with order details
        row = data.iloc[0]
        order_id = str(row.get("order_id", ""))
        dealt_avg_price = _safe_float(row.get("dealt_avg_price")) or None
        dealt_qty = _safe_float(row.get("dealt_qty")) or None
        order_status = str(row.get("order_status", ""))

        log.info(
            "[ORDER] Success: order_id=%s status=%s dealt_price=%s dealt_qty=%s",
            order_id, order_status, dealt_avg_price, dealt_qty,
        )

        # For market orders in paper trading, fill may happen instantly
        # If not filled yet, poll briefly
        if not dealt_avg_price and order_id:
            dealt_avg_price, dealt_qty, order_status = _poll_order_fill(
                trd_ctx, order_id, max_wait=3
            )

        return jsonify({
            "success": True,
            "order_id": order_id,
            "filled_price": dealt_avg_price,
            "filled_qty": dealt_qty,
            "status": order_status,
            "symbol": symbol,
            "side": side_str,
            "qty": float(qty),
        })

    except Exception as e:
        log.exception("[ORDER] Exception during place_order")
        _reset_trd_ctx()
        return jsonify({"success": False, "error": str(e)}), 500


def _poll_order_fill(trd_ctx, order_id: str, max_wait: int = 3):
    """Poll order status for up to max_wait seconds waiting for fill."""
    for _ in range(max_wait):
        time.sleep(1)
        try:
            ret, data = trd_ctx.order_list_query(
                order_id=order_id,
                trd_env=TRD_ENV,
                acc_id=MOOMOO_ACC_ID,
            )
            if ret == RET_OK and len(data) > 0:
                row = data.iloc[0]
                price = _safe_float(row.get("dealt_avg_price")) or None
                qty = _safe_float(row.get("dealt_qty")) or None
                status = str(row.get("order_status", ""))
                if price:
                    return price, qty, status
        except Exception as e:
            log.warning("[POLL] order_list_query error: %s", e)
    return None, None, "UNKNOWN"


@app.route("/positions", methods=["GET"])
def get_positions():
    """
    Return current paper-trading positions.

    Response JSON:
        positions  list of {symbol, qty, avg_cost, current_price,
                            unrealized_pnl, market_value, side}
    """
    try:
        trd_ctx = _get_trd_ctx()
        ret, data = trd_ctx.position_list_query(
            trd_env=TRD_ENV, acc_id=MOOMOO_ACC_ID, refresh_cache=True,
        )

        if ret != RET_OK:
            log.error("[POSITIONS] position_list_query failed: %s", data)
            _reset_trd_ctx()
            return jsonify({"error": str(data)}), 500

        positions = []
        for _, row in data.iterrows():
            qty = _safe_float(row.get("qty"))
            if qty == 0:
                continue  # skip closed positions
            nominal_price = _safe_float(row.get("nominal_price"))
            cost_price = _safe_float(row.get("cost_price"))
            market_val = _safe_float(row.get("market_val"))
            unrealized_pnl = _safe_float(row.get("pl_val"))

            positions.append({
                "symbol": _to_magi_symbol(str(row.get("code", ""))),
                "code": str(row.get("code", "")),
                "qty": qty,
                "avg_cost": cost_price,
                "current_price": nominal_price,
                "unrealized_pnl": round(unrealized_pnl, 2),
                "market_value": market_val,
                "side": str(row.get("position_side", "")),
                "can_sell_qty": _safe_float(row.get("can_sell_qty")),
            })

        log.info("[POSITIONS] Returned %d positions", len(positions))
        return jsonify({"positions": positions})

    except Exception as e:
        log.exception("[POSITIONS] Exception")
        _reset_trd_ctx()
        return jsonify({"error": str(e)}), 500


@app.route("/account_info", methods=["GET"])
def get_account_info():
    """
    Return paper-trading account info (balance, buying power, etc.).

    Response JSON:
        total_assets    float
        cash            float   (USD cash)
        market_value    float   (securities market value)
        buying_power    float
        unrealized_pl   float
        risk_status     str
        currency        str
    """
    try:
        trd_ctx = _get_trd_ctx()
        ret, data = trd_ctx.accinfo_query(
            trd_env=TRD_ENV, acc_id=MOOMOO_ACC_ID, refresh_cache=True,
        )

        if ret != RET_OK:
            log.error("[ACCOUNT] accinfo_query failed: %s", data)
            _reset_trd_ctx()
            return jsonify({"error": str(data)}), 500

        row = data.iloc[0]
        total_assets = _safe_float(row.get("total_assets"))
        cash = _safe_float(row.get("us_cash")) or _safe_float(row.get("cash"))
        market_val = _safe_float(row.get("market_val"))
        buying_power = _safe_float(row.get("power"))
        unrealized_pl = _safe_float(row.get("unrealized_pl"))
        risk_status = str(row.get("risk_status", ""))

        result = {
            "total_assets": total_assets,
            "cash": cash,
            "market_value": market_val,
            "buying_power": buying_power,
            "unrealized_pl": unrealized_pl,
            "risk_status": risk_status,
            "currency": "USD",
            "trd_env": TRD_ENV_STR,
        }
        log.info("[ACCOUNT] total=%.2f cash=%.2f mv=%.2f", total_assets, cash, market_val)
        return jsonify(result)

    except Exception as e:
        log.exception("[ACCOUNT] Exception")
        _reset_trd_ctx()
        return jsonify({"error": str(e)}), 500


@app.route("/order/<order_id>", methods=["GET"])
def get_order_status(order_id):
    """
    Get status of a specific order by ID.

    Response JSON:
        order_id        str
        status          str
        filled_price    float|null
        filled_qty      float|null
        symbol          str
        side            str
        qty             float
        create_time     str
    """
    try:
        trd_ctx = _get_trd_ctx()
        ret, data = trd_ctx.order_list_query(
            order_id=order_id,
            trd_env=TRD_ENV,
            acc_id=MOOMOO_ACC_ID,
        )

        if ret != RET_OK:
            log.error("[ORDER_STATUS] order_list_query failed: %s", data)
            _reset_trd_ctx()
            return jsonify({"error": str(data)}), 500

        if len(data) == 0:
            return jsonify({"error": f"Order {order_id} not found"}), 404

        row = data.iloc[0]
        return jsonify({
            "order_id": str(row.get("order_id", "")),
            "status": str(row.get("order_status", "")),
            "filled_price": _safe_float(row.get("dealt_avg_price")) or None,
            "filled_qty": _safe_float(row.get("dealt_qty")) or None,
            "symbol": _to_magi_symbol(str(row.get("code", ""))),
            "side": str(row.get("trd_side", "")),
            "qty": _safe_float(row.get("qty")),
            "create_time": str(row.get("create_time", "")),
        })

    except Exception as e:
        log.exception("[ORDER_STATUS] Exception")
        _reset_trd_ctx()
        return jsonify({"error": str(e)}), 500


@app.route("/quote", methods=["GET"])
def get_quote():
    """
    Get latest quote for a symbol via OpenD.

    Query params:
        symbol  str  e.g. "AAPL"

    Response JSON:
        symbol      str
        last_price  float
        bid         float
        ask         float
        volume      int
        timestamp   str
    """
    symbol = request.args.get("symbol")
    if not symbol:
        return jsonify({"error": "symbol query param required"}), 400

    code = _to_moomoo_code(symbol)

    try:
        quote_ctx = _get_quote_ctx()
        ret, data = quote_ctx.get_market_snapshot([code])

        if ret != RET_OK:
            log.error("[QUOTE] get_market_snapshot failed: %s", data)
            _reset_quote_ctx()
            return jsonify({"error": str(data)}), 500

        if len(data) == 0:
            return jsonify({"error": f"No quote data for {symbol}"}), 404

        row = data.iloc[0]
        return jsonify({
            "symbol": symbol,
            "last_price": _safe_float(row.get("last_price")),
            "bid": _safe_float(row.get("bid_price")),
            "ask": _safe_float(row.get("ask_price")),
            "volume": int(_safe_float(row.get("volume"))),
            "open": _safe_float(row.get("open_price")),
            "high": _safe_float(row.get("high_price")),
            "low": _safe_float(row.get("low_price")),
            "prev_close": _safe_float(row.get("prev_close_price")),
            "timestamp": str(row.get("update_time", "")),
        })

    except Exception as e:
        log.exception("[QUOTE] Exception")
        _reset_quote_ctx()
        return jsonify({"error": str(e)}), 500


@app.route("/bars", methods=["GET"])
def get_bars():
    """
    Get historical K-line (candlestick) data for a symbol via OpenD.

    Query params:
        symbol      str   e.g. "AAPL"
        limit       int   number of bars (default 21, max 1000)
        timeframe   str   "1Day" (default), "1Min", "5Min", "15Min", "60Min"

    Response JSON:
        symbol  str
        bars    list of {t, o, h, l, c, v}
    """
    symbol = request.args.get("symbol")
    if not symbol:
        return jsonify({"error": "symbol query param required"}), 400

    limit = min(int(request.args.get("limit", 21)), 1000)
    timeframe = request.args.get("timeframe", "1Day")
    ktype = KTYPE_MAP.get(timeframe, KLType.K_DAY)
    code = _to_moomoo_code(symbol)

    # Calculate date range
    end_date = datetime.now().strftime("%Y-%m-%d")
    start_date = (datetime.now() - timedelta(days=60)).strftime("%Y-%m-%d")

    try:
        quote_ctx = _get_quote_ctx()
        ret, data, _ = quote_ctx.request_history_kline(
            code,
            start=start_date,
            end=end_date,
            ktype=ktype,
            max_count=limit,
        )

        if ret != RET_OK:
            log.error("[BARS] request_history_kline failed: %s", data)
            _reset_quote_ctx()
            return jsonify({"error": str(data)}), 500

        bars = []
        for _, row in data.iterrows():
            bars.append({
                "t": str(row.get("time_key", "")),
                "o": _safe_float(row.get("open")),
                "h": _safe_float(row.get("high")),
                "l": _safe_float(row.get("low")),
                "c": _safe_float(row.get("close")),
                "v": int(_safe_float(row.get("volume"))),
            })

        log.info("[BARS] %s: returned %d bars", symbol, len(bars))
        return jsonify({"symbol": symbol, "bars": bars})

    except Exception as e:
        log.exception("[BARS] Exception")
        _reset_quote_ctx()
        return jsonify({"error": str(e)}), 500


@app.route("/accounts", methods=["GET"])
def list_accounts():
    """
    List all available trading accounts (both SIMULATE and REAL).
    Shows which account is currently active and how it was selected.

    NOTE: previously this filtered to SIMULATE-only, which hid REAL accounts
    (e.g. the FUTUJP production account) from diagnostics. It now returns every
    account so REAL accounts are discoverable. This endpoint is read-only.
    """
    try:
        trd_ctx = _get_trd_ctx()
        ret, data = trd_ctx.get_acc_list()

        if ret != RET_OK:
            log.error("[ACCOUNTS] get_acc_list failed: %s", data)
            _reset_trd_ctx()
            return jsonify({"error": str(data)}), 500

        accounts = []
        for _, row in data.iterrows():
            acc_id = int(row.get("acc_id", 0))
            accounts.append({
                "acc_id": acc_id,
                "trd_env": str(row.get("trd_env", "")),
                "acc_type": str(row.get("acc_type", "")),
                "sim_acc_type": str(row.get("sim_acc_type", "")),
                "security_firm": str(row.get("security_firm", "")),
                "acc_status": str(row.get("acc_status", "")),
                "trdmarket_auth": str(row.get("trdmarket_auth", "")),
                "active": acc_id == MOOMOO_ACC_ID,
            })

        log.info("[ACCOUNTS] Found %d accounts", len(accounts))
        return jsonify({
            "accounts": accounts,
            "current_acc_id": MOOMOO_ACC_ID,
            "current_trd_env": TRD_ENV_STR,
            "acc_id_source": "env" if os.environ.get("MOOMOO_ACC_ID") else "auto-discovered",
            "target_sim_acc_type": _SIM_ACC_TYPE_TARGET,
        })

    except Exception as e:
        log.exception("[ACCOUNTS] Exception")
        _reset_trd_ctx()
        return jsonify({"error": str(e)}), 500


@app.route("/snapshot", methods=["GET"])
def get_snapshot():
    """
    Batch market snapshot for multiple symbols.

    Query params:
        symbols  str  comma-separated, e.g. "AAPL,TSLA,MSFT" (max 400)

    Response JSON:
        snapshots  list of {symbol, last_price, open, high, low, prev_close,
                            volume, turnover, bid, ask, spread, change, change_pct,
                            timestamp}
    """
    symbols_str = request.args.get("symbols")
    if not symbols_str:
        return jsonify({"error": "symbols query param required (comma-separated)"}), 400

    raw_symbols = [s.strip() for s in symbols_str.split(",") if s.strip()]
    if len(raw_symbols) > 400:
        return jsonify({"error": "max 400 symbols per request"}), 400

    codes = [_to_moomoo_code(s) for s in raw_symbols]

    try:
        quote_ctx = _get_quote_ctx()
        ret, data = quote_ctx.get_market_snapshot(codes)

        if ret != RET_OK:
            log.error("[SNAPSHOT] get_market_snapshot failed: %s", data)
            _reset_quote_ctx()
            return jsonify({"error": str(data)}), 500

        snapshots = []
        for _, row in data.iterrows():
            last = _safe_float(row.get("last_price"))
            prev = _safe_float(row.get("prev_close_price"))
            bid = _safe_float(row.get("bid_price"))
            ask = _safe_float(row.get("ask_price"))
            change = round(last - prev, 4) if last and prev else 0.0
            change_pct = round((change / prev) * 100, 2) if prev else 0.0
            spread = round(ask - bid, 4) if ask and bid else 0.0

            snapshots.append({
                "symbol": _to_magi_symbol(str(row.get("code", ""))),
                "last_price": last,
                "open": _safe_float(row.get("open_price")),
                "high": _safe_float(row.get("high_price")),
                "low": _safe_float(row.get("low_price")),
                "prev_close": prev,
                "volume": int(_safe_float(row.get("volume"))),
                "turnover": _safe_float(row.get("turnover")),
                "bid": bid,
                "ask": ask,
                "spread": spread,
                "change": change,
                "change_pct": change_pct,
                "timestamp": str(row.get("update_time", "")),
            })

        log.info("[SNAPSHOT] Returned %d snapshots for %d symbols", len(snapshots), len(raw_symbols))
        return jsonify({"snapshots": snapshots, "count": len(snapshots)})

    except Exception as e:
        log.exception("[SNAPSHOT] Exception")
        _reset_quote_ctx()
        return jsonify({"error": str(e)}), 500


@app.route("/orderbook", methods=["GET"])
def get_orderbook():
    """
    Get order book (bid/ask depth) for a symbol.

    Query params:
        symbol  str  e.g. "AAPL"

    Response JSON:
        symbol      str
        bids        list of {price, volume, order_count}
        asks        list of {price, volume, order_count}
        timestamp   str
    """
    symbol = request.args.get("symbol")
    if not symbol:
        return jsonify({"error": "symbol query param required"}), 400

    code = _to_moomoo_code(symbol)

    try:
        quote_ctx = _get_quote_ctx()

        ret_sub, err_sub = quote_ctx.subscribe([code], [SubType.ORDER_BOOK])
        if ret_sub != RET_OK:
            log.warning("[ORDERBOOK] subscribe failed (may already be subscribed): %s", err_sub)

        ret, data = quote_ctx.get_order_book(code)

        if ret != RET_OK:
            log.error("[ORDERBOOK] get_order_book failed: %s", data)
            _reset_quote_ctx()
            return jsonify({"error": str(data)}), 500

        bids = []
        asks = []

        for _, row in data.iterrows():
            entry = {
                "price": _safe_float(row.get("price")),
                "volume": int(_safe_float(row.get("volume"))),
                "order_count": int(_safe_float(row.get("order_num"))),
            }
            side = str(row.get("order_book_bid_ask", ""))
            if side == "Bid":
                bids.append(entry)
            elif side == "Ask":
                asks.append(entry)

        log.info("[ORDERBOOK] %s: %d bids, %d asks", symbol, len(bids), len(asks))
        return jsonify({
            "symbol": symbol,
            "bids": bids,
            "asks": asks,
            "bid_count": len(bids),
            "ask_count": len(asks),
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })

    except Exception as e:
        log.exception("[ORDERBOOK] Exception")
        _reset_quote_ctx()
        return jsonify({"error": str(e)}), 500


@app.route("/order_history", methods=["GET"])
def get_order_history():
    """
    Get historical order list.

    Query params:
        code    str  optional, filter by symbol (e.g. "AAPL")
        days    int  lookback days (default 7, max 90)

    Response JSON:
        orders  list of {order_id, symbol, side, qty, price, filled_price,
                         filled_qty, status, create_time, updated_time, remark}
    """
    code_filter = request.args.get("code", "")
    days = min(int(request.args.get("days", 7)), 90)

    if code_filter:
        code_filter = _to_moomoo_code(code_filter)

    start = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
    end = datetime.now().strftime("%Y-%m-%d")

    try:
        trd_ctx = _get_trd_ctx()
        ret, data = trd_ctx.history_order_list_query(
            trd_env=TRD_ENV,
            acc_id=MOOMOO_ACC_ID,
            code=code_filter,
            start=start,
            end=end,
        )

        if ret != RET_OK:
            log.error("[ORDER_HISTORY] history_order_list_query failed: %s", data)
            _reset_trd_ctx()
            return jsonify({"error": str(data)}), 500

        orders = []
        for _, row in data.iterrows():
            orders.append({
                "order_id": str(row.get("order_id", "")),
                "symbol": _to_magi_symbol(str(row.get("code", ""))),
                "side": str(row.get("trd_side", "")),
                "qty": _safe_float(row.get("qty")),
                "price": _safe_float(row.get("price")),
                "filled_price": _safe_float(row.get("dealt_avg_price")) or None,
                "filled_qty": _safe_float(row.get("dealt_qty")) or None,
                "status": str(row.get("order_status", "")),
                "create_time": str(row.get("create_time", "")),
                "updated_time": str(row.get("updated_time", "")),
                "remark": str(row.get("remark", "")),
            })

        log.info("[ORDER_HISTORY] Returned %d orders (last %d days)", len(orders), days)
        return jsonify({"orders": orders, "count": len(orders), "days": days})

    except Exception as e:
        log.exception("[ORDER_HISTORY] Exception")
        _reset_trd_ctx()
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    port = int(os.environ.get("BRIDGE_PORT", "11436"))
    log.info("Starting moomoo-bridge on port %d", port)
    if MOOMOO_ACC_ID:
        log.info("OpenD: %s:%s  Market: %s  Env: %s  acc_id: %d (from env)", OPEND_HOST, OPEND_PORT, TRD_MARKET, TRD_ENV_STR, MOOMOO_ACC_ID)
    else:
        log.info("OpenD: %s:%s  Market: %s  Env: %s  acc_id: auto-discover (target: %s)", OPEND_HOST, OPEND_PORT, TRD_MARKET, TRD_ENV_STR, _SIM_ACC_TYPE_TARGET)
    if IS_REAL:
        log.warning("REAL trading environment active. real_orders_enabled=%s", IS_REAL and ALLOW_REAL_ORDERS)
    app.run(host="0.0.0.0", port=port, debug=False, threaded=False)
