---
name: moomoo-api-reference
description: MooMoo OpenAPI Python SDK reference for the magi-moomoo bridge. Covers trading objects, account management, demo trading, order placement, position/fund queries, market data APIs, and key enum definitions. Use when modifying bridge endpoints, adding new trading features, or debugging MooMoo SDK behavior.
---

# MooMoo OpenAPI Python SDK Reference

Official docs: https://openapi.moomoo.com/moomoo-api-doc/jp/intro/intro.html

## Architecture

- **OpenD**: Local TCP gateway program that relays protocol requests to MooMoo backend
- **moomoo Python SDK**: `pip install moomoo-api` — wraps OpenD TCP protocol
- OpenD runs on TIALA at `127.0.0.1:11111`
- The bridge (`bridge/moomoo_bridge.py`) connects to OpenD and exposes a REST API

## Context Objects

### Quote Context (market data)
```python
from moomoo import *
quote_ctx = OpenQuoteContext(host='127.0.0.1', port=11111)
# ... use quote APIs ...
quote_ctx.close()  # Always close to prevent connection exhaustion
```

### Trade Context (securities: stocks, ETFs, options)
```python
from moomoo import *
trd_ctx = OpenSecTradeContext(
    filter_trdmarket=TrdMarket.US,  # Filter accounts by market (HK, US, etc.)
    host='127.0.0.1',
    port=11111,
    security_firm=SecurityFirm.FUTUINC  # FUTUINC for moomoo Inc (US)
)
trd_ctx.close()
```

### Trade Context (futures)
```python
trd_ctx = OpenFutureTradeContext(
    host='127.0.0.1',
    port=11111,
    security_firm=SecurityFirm.FUTUINC
)
```

**Key differences:**
- `OpenSecTradeContext` has `filter_trdmarket` param → filters accounts by market
- `OpenFutureTradeContext` does NOT have `filter_trdmarket` → only `security_firm`
- `security_firm` filters by broker; demo accounts have no broker concept so ALL demo accounts are returned regardless of `security_firm`

## Account Management

### get_acc_list() — List Trading Accounts

Returns a DataFrame with all accounts matching the context's filters.

```python
ret, data = trd_ctx.get_acc_list()
# data columns: acc_id, trd_env, acc_type, uni_card_num, card_num,
#               security_firm, sim_acc_type, trdmarket_auth, acc_status, acc_role
```

**Key fields:**
| Field | Type | Description |
|---|---|---|
| `acc_id` | int | Trading account ID |
| `trd_env` | str | `REAL` or `SIMULATE` |
| `acc_type` | str | `CASH` or `MARGIN` |
| `sim_acc_type` | str | Demo account type (only for SIMULATE accounts) |
| `trdmarket_auth` | list | Market permissions (e.g. `[HK]`, `[US]`) |
| `acc_status` | str | `ACTIVE`, `DISABLED`, etc. |

### Demo Account Types (sim_acc_type)

**US market** (`filter_trdmarket=TrdMarket.US`):
| sim_acc_type | Description |
|---|---|
| `STOCK_AND_OPTION` | US stocks & options demo (margin account) |
| `FUTURES` | US futures demo |

**HK market** (`filter_trdmarket=TrdMarket.HK`):
| sim_acc_type | Description |
|---|---|
| `STOCK` | HK stocks demo (cash account) |
| `OPTION` | HK options demo (margin account) |
| `FUTURES` | HK futures demo |

**Example output (filter_trdmarket=TrdMarket.US):**
```
               acc_id   trd_env acc_type  sim_acc_type  trdmarket_auth
0  281756420273981734      REAL   MARGIN           N/A  [HK, US, HKCC]
1             3450310  SIMULATE     CASH         STOCK            [US]
2             3548732  SIMULATE   MARGIN        OPTION            [US]
```

**Example output (filter_trdmarket=TrdMarket.NONE — all accounts):**
```
                acc_id   trd_env acc_type  sim_acc_type       trdmarket_auth
0   281756478396547854      REAL   MARGIN           N/A  [HK, US, HKCC, ...]
1              3450309  SIMULATE     CASH         STOCK                 [HK]
2              3450310  SIMULATE   MARGIN         STOCK                 [US]
3              3450311  SIMULATE     CASH         STOCK                 [CN]
4              3548732  SIMULATE   MARGIN        OPTION                 [US]
5              3548731  SIMULATE   MARGIN        OPTION                 [HK]
```

### Auto-Discovery in the Bridge

The bridge (`moomoo_bridge.py`) auto-discovers the correct SIMULATE account:
1. Calls `trd_ctx.get_acc_list()`
2. Filters rows where `trd_env == "SIMULATE"`
3. Selects the row matching target `sim_acc_type` (US → `STOCK_AND_OPTION`, HK → `STOCK`)
4. Falls back to first SIMULATE account if no exact match
5. Override with `MOOMOO_ACC_ID` env var to skip auto-discovery

## Account Selection in Trade APIs

All trade APIs accept `acc_id` and `acc_index` parameters:
- `acc_id=0` (default): uses `acc_index` to select from filtered account list
- `acc_id=<specific_id>`: uses that account directly (recommended)
- `acc_index=0` (default): first account in the filtered list

**Selection flow:**
1. `trd_env` filters REAL vs SIMULATE accounts
2. `acc_id` (if non-zero) selects the specific account
3. Otherwise `acc_index` selects by position in the filtered list

## Trade Unlock

Required for REAL trading only. **Demo trading does NOT require unlock.**

```python
ret, data = trd_ctx.unlock_trade(password='123456')  # or password_md5='...'
```

## Account Fund Query

```python
accinfo_query(trd_env=TrdEnv.REAL, acc_id=0, acc_index=0,
              refresh_cache=False, currency=Currency.HKD)
```

**Key return fields:**
| Field | Description |
|---|---|
| `power` | Max buying power (approximate, based on 50% margin) |
| `total_assets` | Net total assets |
| `cash` | Cash (deprecated — use `us_cash`, `hk_cash` etc.) |
| `market_val` | Securities market value |
| `frozen_cash` | Frozen cash |
| `avl_withdrawal_cash` | Available for withdrawal |
| `us_cash` | USD cash |
| `hk_cash` | HKD cash |
| `risk_status` | Risk level (LEVEL1=safest to LEVEL9=most dangerous) |

## Position Query

```python
position_list_query(code='', pl_ratio_sort=None, trd_env=TrdEnv.REAL,
                    acc_id=0, acc_index=0, refresh_cache=False)
```

**Key return fields:**
| Field | Description |
|---|---|
| `code` | Stock code (e.g. `US.AAPL`) |
| `stock_name` | Stock name |
| `qty` | Holding quantity |
| `can_sell_qty` | Sellable quantity |
| `cost_price` | Average cost |
| `market_val` | Market value |
| `nominal_price` | Current price |
| `pl_ratio` | P&L ratio (%) |
| `pl_val` | P&L value |
| `position_side` | `LONG` or `SHORT` |

## Place Order

```python
place_order(price, qty, code, trd_side,
            order_type=OrderType.NORMAL,  # NORMAL=limit, MARKET=market
            trd_env=TrdEnv.REAL,
            acc_id=0, acc_index=0,
            remark=None,                  # Up to 64 bytes UTF-8
            time_in_force=TimeInForce.DAY,
            fill_outside_rth=False,       # Allow pre/after market
            session=Session.NONE)         # US stocks: RTH, ETH, OVERNIGHT, ALL
```

**Demo trading example:**
```python
trd_ctx = OpenSecTradeContext(filter_trdmarket=TrdMarket.US, host='127.0.0.1', port=11111,
                              security_firm=SecurityFirm.FUTUINC)
ret, data = trd_ctx.place_order(
    price=510.0, qty=100, code="US.AAPL",
    trd_side=TrdSide.BUY,
    trd_env=TrdEnv.SIMULATE,
    session=Session.NONE
)
```

**Demo trading limitations:**
- Order types: only `NORMAL` (limit) and `MARKET` (market) supported
- Modify operations: only CANCEL and NORMAL (modify) — no ENABLE/DISABLE/DELETE
- No deal query support (get_order_fill_list, history_order_fill_list, deal push callback)
- Time in force: DAY only
- Short selling: options and futures supported; stocks only for US
- No order fee query support
- No cashflow query support

**Return fields:** `trd_side`, `order_type`, `order_status`, `order_id`, `code`, `stock_name`, `qty`, `price`, `create_time`, `updated_time`, `dealt_qty`, `dealt_avg_price`, `last_err_msg`, `remark`, `time_in_force`, `fill_outside_rth`, `session`

## Modify / Cancel Order

```python
modify_order(modify_order_op, order_id, qty, price,
             trd_env=TrdEnv.REAL, acc_id=0, acc_index=0)
```

- `ModifyOrderOp.NORMAL` — modify price/qty
- `ModifyOrderOp.CANCEL` — cancel order
- `ModifyOrderOp.DISABLE` — disable (not supported in demo)
- `ModifyOrderOp.ENABLE` — re-enable (not supported in demo)
- `ModifyOrderOp.DELETE` — delete cancelled/failed orders (not supported in demo)

## Order Query

```python
# Pending orders
order_list_query(trd_env=TrdEnv.REAL, acc_id=0, acc_index=0,
                 order_id='', code='', status_filter_list=[])

# Historical orders
history_order_list_query(trd_env=TrdEnv.REAL, acc_id=0, acc_index=0,
                         code='', status_filter_list=[], start='', end='')
```

## Order Push Callback

```python
class TradeOrderHandlerBase:
    def on_recv_rsp(self, rsp_pb):
        # ret, data = super().on_recv_rsp(rsp_pb)
        pass

trd_ctx.set_handler(TradeOrderHandlerBase())
trd_ctx.start()  # Start receiving push notifications
```

## Max Tradable Quantity

```python
acctradinginfo_query(order_type, code, price,
                     trd_env=TrdEnv.REAL, acc_id=0, acc_index=0)
```

Returns: `max_cash_buy`, `max_cash_and_margin_buy`, `max_position_sell`, `max_sell_short`, `max_buy_back`

## Market Data APIs

### Snapshot
```python
quote_ctx.get_market_snapshot(code_list)  # Up to 400 codes per call
```
Rate limit: 60 requests per 30 seconds.

### Historical K-line (Candlestick)
```python
quote_ctx.request_history_kline(code, start='2024-01-01', end='2024-12-31',
                                 ktype=KLType.K_DAY, max_count=1000,
                                 page_req_key=None, extended_time=False)
```
Returns: `code`, `time_key`, `open`, `close`, `high`, `low`, `volume`, `turnover`, `change_rate`, `last_close`

### Subscribe to Real-time Data
```python
quote_ctx.subscribe(code_list=['US.AAPL'],
                    subtype_list=[SubType.QUOTE, SubType.ORDER_BOOK],
                    is_first_push=True, subscribe_push=True)
```

Subscription types: `QUOTE`, `ORDER_BOOK`, `TICKER`, `K_1M`, `K_5M`, `K_15M`, `K_30M`, `K_60M`, `K_DAY`, `K_WEEK`, `K_MON`, `RT_DATA`, `BROKER`

Subscription quotas based on account tier (100 to 2000 slots).

## Key Enums

### TrdEnv — Trading Environment
- `TrdEnv.REAL` — Real trading
- `TrdEnv.SIMULATE` — Demo/paper trading

### TrdMarket — Trading Market
- `TrdMarket.NONE` — No filter (return all)
- `TrdMarket.HK` — Hong Kong
- `TrdMarket.US` — United States
- `TrdMarket.CN` — China A-shares
- `TrdMarket.HKCC` — HK A-share connect
- `TrdMarket.FUTURES_HK` — HK futures
- `TrdMarket.FUTURES_US` — US futures

### TrdSide — Trade Direction
- `TrdSide.BUY`
- `TrdSide.SELL`
- `TrdSide.SELL_SHORT`
- `TrdSide.BUY_BACK`

### OrderType — Order Type
- `OrderType.NORMAL` — Limit order
- `OrderType.MARKET` — Market order
- `OrderType.ABSOLUTE_LIMIT` — Absolute limit (exact price only)
- `OrderType.AUCTION` — Auction market order (HK pre/closing)
- `OrderType.AUCTION_LIMIT` — Auction limit order
- `OrderType.STOP` — Stop loss market
- `OrderType.STOP_LIMIT` — Stop loss limit
- `OrderType.MARKET_IF_TOUCHED` — Take profit market
- `OrderType.LIMIT_IF_TOUCHED` — Take profit limit
- `OrderType.TRAILING_STOP` — Trailing stop market
- `OrderType.TRAILING_STOP_LIMIT` — Trailing stop limit

### OrderStatus — Order Status
- `WAITING_SUBMIT` — Waiting to submit to exchange
- `SUBMITTING` — Being submitted
- `SUBMITTED` — Submitted, awaiting fill
- `FILLED_PART` — Partially filled
- `FILLED_ALL` — Fully filled
- `CANCELLED_PART` — Partially filled, rest cancelled
- `CANCELLED_ALL` — Fully cancelled
- `FAILED` — Rejected by server
- `DISABLED` — Disabled (not submitted to exchange)
- `DELETED` — Deleted (unfilled orders only)

### SecurityFirm — Broker
- `SecurityFirm.FUTUSECURITIES` — Futu Securities (HK)
- `SecurityFirm.FUTUINC` — Moomoo Inc (US) ← **used by MAGI bridge**
- `SecurityFirm.FUTUSG` — Moomoo SG
- `SecurityFirm.FUTUAU` — Moomoo AU
- `SecurityFirm.FUTUCA` — Moomoo CA
- `SecurityFirm.FUTUJP` — Moomoo JP

### SimAccType — Demo Account Type
- `SimAccType.STOCK` — Stock demo (HK)
- `SimAccType.OPTION` — Option demo (HK)
- `SimAccType.STOCK_AND_OPTION` — Stock & option demo (US) ← **MAGI target**
- `SimAccType.FUTURES` — Futures demo

### Currency
- `Currency.HKD`, `Currency.USD`, `Currency.CNH`, `Currency.JPY`, `Currency.SGD`, `Currency.AUD`, `Currency.CAD`, `Currency.MYR`

### TimeInForce
- `TimeInForce.DAY` — Day order (only option for demo trading)
- `TimeInForce.GTC` — Good till cancelled

### Session (US stocks)
- `Session.NONE` — Default
- `Session.RTH` — Regular trading hours
- `Session.ETH` — Extended trading hours (pre + after)
- `Session.OVERNIGHT` — Overnight session
- `Session.ALL` — All sessions

## Stock Code Format

MooMoo uses `{MARKET}.{TICKER}` format:
- US stocks: `US.AAPL`, `US.TSLA`, `US.MSFT`
- HK stocks: `HK.00700` (Tencent), `HK.09988` (Alibaba)
- CN stocks: `SH.600519`, `SZ.000001`
- US options: `US.AAPL250618P550000` (AAPL put, June 18 2025, strike $550)
- Futures: `HK.HSImain`, `US.NQmain`, `JP.NK225main`

The bridge converts MAGI-style tickers (e.g. `AAPL`) to MooMoo format (e.g. `US.AAPL`).

## API Rate Limits

- Rate limits vary per API endpoint
- Example: Snapshot API = max 60 requests per 30 seconds
- Exceeding limits returns an error
- Use `refresh_cache=False` (default) to use OpenD cache and avoid rate limits
- Subscription quotas: 100-2000 based on account assets/trading volume

## Demo Trading Notes

- Demo and real trading use the **same APIs** — just set `trd_env=TrdEnv.SIMULATE`
- Demo accounts are shared across mobile app, desktop app, web, and API
- Trading hours: regular session only (US: regular + pre + after)
- No overnight, no auction for A-shares/HK
- Demo account reset: only via mobile app resurrection card
- API does NOT support demo account reset

## Connection Management

- Always call `ctx.close()` when done to prevent connection exhaustion
- Or use `SysConfig.set_all_thread_daemon(True)` to auto-cleanup on process exit
- The bridge uses persistent contexts (`_trd_ctx`, `_quote_ctx`) — created once, reused
- Max connections per OpenD: limited (close unused connections promptly)

## OpenD Configuration (Command-line)

Key parameters for OpenD:
- `--login_account`: MooMoo account ID
- `--login_pwd_md5`: MD5 of login password
- `--login_region`: `sh` (Shanghai), `hk`, `us`, `jp`
- `--lang`: `en`, `chs`, `cht`, `jp`
- `--port`: TCP listening port (default 11111)
- `--log_level`: `no`, `debug`, `info`, `warning`, `error`, `fatal`
- `--api_ip`: Allowed API connection IPs (default 127.0.0.1)
- `--no_monitor`: Disable monitoring output

## FAQ Quick Reference

**Q: How to select correct demo account?**
A: Use `get_acc_list()`, filter by `trd_env=SIMULATE`, match `sim_acc_type` to your needs (US stocks → `STOCK_AND_OPTION`, HK stocks → `STOCK`).

**Q: Do I need to unlock for demo trading?**
A: No. `unlock_trade()` is only required for REAL trading.

**Q: Can I use market orders in demo?**
A: Yes. Demo supports `NORMAL` (limit) and `MARKET` (market) order types only.

**Q: Why does my order fail with tick size error?**
A: Different markets have different tick sizes. Use `adjust_limit` parameter to auto-adjust price, or check the tick size rules for the specific market/price range.

**Q: Pattern Day Trader (PDT) rule?**
A: US accounts with <$25,000 equity are limited to 3 day trades per 5 business days. Check `DTBP` (Day Trade Buying Power) via `accinfo_query()`.