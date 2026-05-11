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
GET  /health           Liveness check

Environment
-----------
OPEND_HOST      OpenD TCP host        (default 127.0.0.1)
OPEND_PORT      OpenD TCP port        (default 11111)
SECURITY_FIRM   SecurityFirm enum     (default FUTUINC)
TRD_MARKET      Filter market         (default US)
"""

import os
import time
import logging
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
SECURITY_FIRM_MAP = {
    "FUTUINC": SecurityFirm.FUTUINC,
    "FUTUSECURITIES": SecurityFirm.FUTUSECURITIES,
}
SECURITY_FIRM = SECURITY_FIRM_MAP.get(
    os.environ.get("SECURITY_FIRM", "FUTUINC"), SecurityFirm.FUTUINC
)
TRD_MARKET_MAP = {
    "US": TrdMarket.US,
    "HK": TrdMarket.HK,
}
TRD_MARKET = TRD_MARKET_MAP.get(os.environ.get("TRD_MARKET", "US"), TrdMarket.US)

# Paper trading only — hardcoded for safety
TRD_ENV = TrdEnv.SIMULATE

# Optional: pin a specific SIMULATE account by ID.
# Without this the SDK uses acc_index=0 which may pick the wrong
# paper-trading account (e.g. $1M default instead of user's $50K reset).
# Set MOOMOO_ACC_ID in the environment to the desired acc_id integer.
MOOMOO_ACC_ID = int(os.environ.get("MOOMOO_ACC_ID", "0"))

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


def _get_trd_ctx():
    """Return (or create) a persistent trade context."""
    global _trd_ctx
    if _trd_ctx is None:
        log.info(
            "Connecting trade context → %s:%s (market=%s, firm=%s, env=SIMULATE)",
            OPEND_HOST, OPEND_PORT, TRD_MARKET, SECURITY_FIRM,
        )
        _trd_ctx = OpenSecTradeContext(
            filter_trdmarket=TRD_MARKET,
            host=OPEND_HOST,
            port=OPEND_PORT,
            security_firm=SECURITY_FIRM,
        )
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
    global _trd_ctx
    if _trd_ctx is not None:
        try:
            _trd_ctx.close()
        except Exception:
            pass
        _trd_ctx = None


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
        "trd_env": "SIMULATE",
        "trd_market": os.environ.get("TRD_MARKET", "US"),
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

    trd_side = TRD_SIDE_MAP.get(side_str)
    if trd_side is None:
        return jsonify({"success": False, "error": f"Invalid side: {side_str}"}), 400

    order_type = ORDER_TYPE_MAP.get(order_type_str, OrderType.MARKET)
    code = _to_moomoo_code(symbol)

    # For MARKET orders, price is ignored but the SDK still requires a value
    if order_type == OrderType.MARKET and price == 0:
        price = 0.01  # placeholder — OpenD ignores it for market orders

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
        ret, data = trd_ctx.position_list_query(trd_env=TRD_ENV, acc_id=MOOMOO_ACC_ID)

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
            unrealized_pnl = market_val - (cost_price * abs(qty)) if cost_price else 0

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
        ret, data = trd_ctx.accinfo_query(trd_env=TRD_ENV, acc_id=MOOMOO_ACC_ID)

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
            "trd_env": "SIMULATE",
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
    from datetime import datetime, timedelta
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
    List all available SIMULATE trading accounts.
    Use this to find the correct acc_id to set in MOOMOO_ACC_ID.
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
            trd_env = str(row.get("trd_env", ""))
            if trd_env != "SIMULATE":
                continue
            accounts.append({
                "acc_id": int(row.get("acc_id", 0)),
                "trd_env": trd_env,
                "acc_type": str(row.get("acc_type", "")),
                "sim_acc_type": str(row.get("sim_acc_type", "")),
                "trdmarket_auth": str(row.get("trdmarket_auth", "")),
            })

        log.info("[ACCOUNTS] Found %d SIMULATE accounts", len(accounts))
        return jsonify({
            "accounts": accounts,
            "current_acc_id": MOOMOO_ACC_ID,
            "note": "Set MOOMOO_ACC_ID env var to pin a specific account",
        })

    except Exception as e:
        log.exception("[ACCOUNTS] Exception")
        _reset_trd_ctx()
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    port = int(os.environ.get("BRIDGE_PORT", "11436"))
    log.info("Starting moomoo-bridge on port %d", port)
    log.info("OpenD: %s:%s  Market: %s  Env: SIMULATE  acc_id: %s", OPEND_HOST, OPEND_PORT, TRD_MARKET, MOOMOO_ACC_ID or 'auto')
    app.run(host="0.0.0.0", port=port, debug=False)
