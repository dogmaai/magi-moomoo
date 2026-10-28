#!/usr/bin/env python3
"""Unit test for the REAL cash-only guard (現物のみ) in bridge/moomoo_bridge.py.

Covers:
  - SIMULATE is never affected (guard not consulted)
  - REAL + guard on: non-CASH / unknown acc_type blocks every order
  - SELL within can_sell_qty passes; SELL beyond it (new short) is blocked
  - SELL with no position / short position only is blocked
  - BUY within cash passes; BUY over cash (margin buy) is blocked
  - MARKET BUY uses snapshot price + buffer
  - lookup failures fail closed (403), guard exceptions fail closed
  - MOOMOO_REAL_ALLOW_MARGIN=true disables the guard; anything else keeps it on
  - /health reports real_cash_only

Run:  python3 test/real_cash_only_test.py
Requires the bridge dependencies (flask, moomoo SDK, pandas). No OpenD needed:
the trade/quote contexts are replaced with fakes.
"""

import os
import sys

os.environ["BRIDGE_AUTH_TOKEN"] = "t"
os.environ.pop("MOOMOO_REAL_ALLOW_MARGIN", None)

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge"))

import pandas as pd  # noqa: E402
import moomoo_bridge as bridge  # noqa: E402

RET_OK = bridge.RET_OK
AUTH = {"Authorization": "Bearer t"}
ACC = 4242

failures = []


def check(name, cond, detail=""):
    print(f"[{'PASS' if cond else 'FAIL'}] {name} {detail}")
    if not cond:
        failures.append(name)


class FakeTrd:
    def __init__(self, acc_type="CASH", positions=None, cash=10_000.0,
                 acc_ret=RET_OK, pos_ret=RET_OK, info_ret=RET_OK):
        self.acc_type = acc_type
        self.positions = positions or []
        self.cash = cash
        self.acc_ret, self.pos_ret, self.info_ret = acc_ret, pos_ret, info_ret
        self.placed = []

    def get_acc_list(self):
        if self.acc_ret != RET_OK:
            return self.acc_ret, "acc list down"
        return RET_OK, pd.DataFrame([
            {"acc_id": ACC, "trd_env": "REAL", "acc_type": self.acc_type},
            {"acc_id": 9999, "trd_env": "REAL", "acc_type": "MARGIN"},
        ])

    def position_list_query(self, code="", trd_env=None, acc_id=0, refresh_cache=False):
        if self.pos_ret != RET_OK:
            return self.pos_ret, "positions down"
        rows = [p for p in self.positions if not code or p["code"] == code]
        return RET_OK, pd.DataFrame(rows, columns=["code", "qty", "can_sell_qty", "position_side"])

    def accinfo_query(self, trd_env=None, acc_id=0, refresh_cache=False):
        if self.info_ret != RET_OK:
            return self.info_ret, "accinfo down"
        return RET_OK, pd.DataFrame([{"us_cash": self.cash, "cash": self.cash}])

    def place_order(self, **kw):
        self.placed.append(kw)
        return RET_OK, pd.DataFrame([{"order_id": "1", "dealt_avg_price": 100.0,
                                      "dealt_qty": kw["qty"], "order_status": "FILLED_ALL"}])


class FakeQuote:
    def __init__(self, last=100.0, ok=True):
        self.last, self.ok = last, ok

    def get_market_snapshot(self, codes):
        if not self.ok:
            return -1, "quote down"
        return RET_OK, pd.DataFrame([{"code": codes[0], "last_price": self.last}])


def setup(trd, quote=None, real=True, cash_only=True):
    bridge.IS_REAL = real
    bridge.TRD_ENV = bridge.TrdEnv.REAL if real else bridge.TrdEnv.SIMULATE
    bridge.ALLOW_REAL_ORDERS = True
    bridge.REAL_CASH_ONLY = cash_only
    bridge.MOOMOO_ACC_ID = ACC
    bridge._get_trd_ctx = lambda: trd
    bridge._get_quote_ctx = lambda: quote or FakeQuote()
    bridge._reset_trd_ctx = lambda: None
    bridge._poll_order_fill = lambda *a, **k: (None, None, "UNKNOWN")


client = bridge.app.test_client()


def order(side, qty, price=100.0, order_type="LIMIT", symbol="AAPL"):
    return client.post("/place_order", headers=AUTH, json={
        "symbol": symbol, "side": side, "qty": qty, "price": price, "order_type": order_type,
    })


LONG = [{"code": "US.AAPL", "qty": 50.0, "can_sell_qty": 40.0, "position_side": "LONG"}]

# 1. SIMULATE unaffected: naked SELL goes through (guard not consulted).
trd = FakeTrd(acc_type="MARGIN", positions=[])
setup(trd, real=False)
r = order("SELL", 10)
check("SIMULATE naked SELL not blocked", r.status_code == 200 and len(trd.placed) == 1,
      f"status={r.status_code}")

# 2. REAL, MARGIN sub-account pinned -> everything blocked.
trd = FakeTrd(acc_type="MARGIN", positions=LONG)
setup(trd)
r = order("BUY", 1)
check("REAL MARGIN acc BUY blocked", r.status_code == 403 and not trd.placed, f"status={r.status_code}")
check("blocked_by label", r.get_json().get("blocked_by") == "real_cash_only_guard")

# 3. REAL, acc_id not found in acc list -> blocked.
trd = FakeTrd(positions=LONG)
setup(trd)
bridge.MOOMOO_ACC_ID = 1234
r = order("BUY", 1)
check("REAL unknown acc_id blocked", r.status_code == 403 and not trd.placed)

# 4. acc list lookup failure -> blocked.
trd = FakeTrd(acc_ret=-1, positions=LONG)
setup(trd)
r = order("BUY", 1)
check("REAL acc list failure blocked", r.status_code == 403 and not trd.placed)

# 5. SELL within can_sell_qty passes.
trd = FakeTrd(positions=LONG)
setup(trd)
r = order("SELL", 40)
check("REAL SELL <= can_sell_qty passes", r.status_code == 200 and len(trd.placed) == 1,
      f"status={r.status_code} body={r.get_json()}")

# 6. SELL beyond can_sell_qty (would cross into short) blocked.
trd = FakeTrd(positions=LONG)
setup(trd)
r = order("SELL", 41)
check("REAL SELL > can_sell_qty blocked", r.status_code == 403 and not trd.placed)

# 7. SELL with no position blocked.
trd = FakeTrd(positions=[])
setup(trd)
r = order("SELL", 1)
check("REAL naked SELL blocked", r.status_code == 403 and not trd.placed)

# 8. SELL against a short position only blocked.
trd = FakeTrd(positions=[{"code": "US.AAPL", "qty": 10.0, "can_sell_qty": 10.0,
                          "position_side": "SHORT"}])
setup(trd)
r = order("SELL", 1)
check("REAL SELL vs short-only blocked", r.status_code == 403 and not trd.placed)

# 9. can_sell_qty missing (NaN) falls back to long qty.
trd = FakeTrd(positions=[{"code": "US.AAPL", "qty": 5.0, "can_sell_qty": float("nan"),
                          "position_side": "LONG"}])
setup(trd)
check("REAL SELL fallback qty passes", order("SELL", 5).status_code == 200)
trd = FakeTrd(positions=[{"code": "US.AAPL", "qty": 5.0, "can_sell_qty": float("nan"),
                          "position_side": "LONG"}])
setup(trd)
check("REAL SELL fallback qty exceeded blocked", order("SELL", 6).status_code == 403)

# 10. Position lookup failure -> blocked.
trd = FakeTrd(pos_ret=-1, positions=LONG)
setup(trd)
check("REAL position failure blocked", order("SELL", 1).status_code == 403 and not trd.placed)

# 11. LIMIT BUY within cash passes; over cash blocked.
trd = FakeTrd(cash=1_000.0)
setup(trd)
check("REAL LIMIT BUY within cash passes", order("BUY", 10, price=100.0).status_code == 200)
trd = FakeTrd(cash=1_000.0)
setup(trd)
check("REAL LIMIT BUY over cash blocked", order("BUY", 11, price=100.0).status_code == 403 and not trd.placed)

# 12. MARKET BUY uses snapshot + buffer: 10 x 100 x 1.02 = 1020 > 1000 -> blocked.
trd = FakeTrd(cash=1_000.0)
setup(trd, quote=FakeQuote(last=100.0))
check("REAL MARKET BUY buffer blocks", order("BUY", 10, price=0, order_type="MARKET").status_code == 403)
trd = FakeTrd(cash=1_100.0)
setup(trd, quote=FakeQuote(last=100.0))
check("REAL MARKET BUY buffer passes", order("BUY", 10, price=0, order_type="MARKET").status_code == 200)

# 13. MARKET BUY with quote failure -> blocked.
trd = FakeTrd(cash=1e9)
setup(trd, quote=FakeQuote(ok=False))
check("REAL MARKET BUY quote failure blocked", order("BUY", 1, price=0, order_type="MARKET").status_code == 403)

# 14. accinfo failure / zero cash -> blocked.
trd = FakeTrd(info_ret=-1)
setup(trd)
check("REAL accinfo failure blocked", order("BUY", 1).status_code == 403)
trd = FakeTrd(cash=0.0)
setup(trd)
check("REAL zero cash blocked", order("BUY", 1).status_code == 403)

# 15. Guard exception -> blocked (fail-closed), not 500.
trd = FakeTrd()
setup(trd)
def boom():
    raise RuntimeError("opend gone")
bridge._get_trd_ctx = boom
r = order("BUY", 1)
check("guard exception fails closed", r.status_code == 403, f"status={r.status_code}")

# 16. Explicit opt-out disables guard in REAL.
trd = FakeTrd(acc_type="MARGIN", positions=[])
setup(trd, cash_only=False)
check("REAL_CASH_ONLY=False allows naked SELL", order("SELL", 1).status_code == 200)

# 17. Env parsing: only exact "true" disables.
import subprocess  # noqa: E402
bridge_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bridge")
for v, expected in [(None, True), ("", True), ("false", True), ("TRUE ", False), ("yes", True), ("1", True)]:
    env = {k: val for k, val in os.environ.items() if k != "MOOMOO_REAL_ALLOW_MARGIN"}
    if v is not None:
        env["MOOMOO_REAL_ALLOW_MARGIN"] = v
    out = subprocess.run(
        [sys.executable, "-c", "import moomoo_bridge as b; print(b.REAL_CASH_ONLY)"],
        cwd=bridge_dir, env=env, capture_output=True, text=True,
    ).stdout.strip().splitlines()
    got = out[-1] if out else ""
    check(f"env MOOMOO_REAL_ALLOW_MARGIN={v!r} -> cash_only={expected}", got == str(expected), f"got={got!r}")

# 18. /health reports the flag.
setup(FakeTrd())
check("health real_cash_only true", client.get("/health").get_json().get("real_cash_only") is True)
setup(FakeTrd(), real=False)
check("health real_cash_only false in SIMULATE", client.get("/health").get_json().get("real_cash_only") is False)

print()
if failures:
    print(f"{len(failures)} FAILED: {failures}")
    sys.exit(1)
print("ALL PASS")
