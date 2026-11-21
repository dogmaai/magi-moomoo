#!/usr/bin/env python3
"""Unit test for /bars returning the NEWEST bars (bridge/moomoo_bridge.py).

OpenD's request_history_kline pages oldest-first from `start`. The old
handler passed max_count=limit, so limit=20 over a 60-day window returned the
oldest 20 bars (~1 month stale). These tests pin the fixed behaviour:

  - the last returned bar is the latest bar in the window
  - exactly `limit` bars come back when enough exist
  - multi-page windows are walked and only the tail is kept
  - fewer rows than `limit` returns everything available
  - an OpenD error is surfaced as HTTP 500
  - the lookback window grows with `limit`

Run:  python3 test/bars_latest_window_test.py
Requires the bridge dependencies (flask, moomoo SDK, pandas). No OpenD needed:
the quote context is replaced with a fake.
"""

import os
import sys
from datetime import date, timedelta

os.environ["BRIDGE_AUTH_TOKEN"] = "t"
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge"))

import pandas as pd  # noqa: E402
import moomoo_bridge as bridge  # noqa: E402

RET_OK = bridge.RET_OK
AUTH = {"Authorization": "Bearer t"}
failures = []


def check(name, cond, detail=""):
    print(f"[{'PASS' if cond else 'FAIL'}] {name} {detail}")
    if not cond:
        failures.append(name)


def make_rows(n, start=date(2026, 9, 22)):
    """n daily rows, oldest first; close == index so freshness is checkable."""
    rows = []
    d = start
    for i in range(n):
        while d.weekday() >= 5:
            d += timedelta(days=1)
        rows.append({"time_key": f"{d} 00:00:00", "open": i, "high": i + 1,
                     "low": i - 1, "close": float(i), "volume": 100 + i})
        d += timedelta(days=1)
    return pd.DataFrame(rows)


class FakeQuote:
    """Emulates OpenD paging: oldest-first, max_count rows per page."""

    def __init__(self, df, fail=False):
        self.df = df
        self.fail = fail
        self.calls = []

    def request_history_kline(self, code, start=None, end=None, ktype=None,
                              max_count=1000, page_req_key=None, **kw):
        self.calls.append({"code": code, "start": start, "end": end,
                           "max_count": max_count, "page_req_key": page_req_key})
        if self.fail:
            return -1, "quota exceeded", None
        offset = page_req_key or 0
        page = self.df.iloc[offset:offset + max_count].reset_index(drop=True)
        nxt = offset + max_count
        return RET_OK, page, (nxt if nxt < len(self.df) else None)


def call_bars(fake, limit):
    bridge._get_quote_ctx = lambda: fake
    bridge._reset_quote_ctx = lambda: None
    client = bridge.app.test_client()
    return client.get(f"/bars?symbol=LLY&limit={limit}", headers=AUTH)


# 1. 41 bars in window, limit=20 → newest 20, last close is the latest (40)
fake = FakeQuote(make_rows(41))
resp = call_bars(fake, 20)
bars = resp.get_json().get("bars", [])
check("status 200", resp.status_code == 200, str(resp.status_code))
check("returns limit bars", len(bars) == 20, str(len(bars)))
check("last bar is latest", bars and bars[-1]["c"] == 40.0, str(bars[-1]["c"] if bars else None))
check("first bar is 20th from end", bars and bars[0]["c"] == 21.0, str(bars[0]["c"] if bars else None))
check("ascending order", all(bars[i]["t"] < bars[i + 1]["t"] for i in range(len(bars) - 1)))
check("does not cap page at limit", fake.calls[0]["max_count"] == bridge._BARS_PAGE_SIZE,
      str(fake.calls[0]["max_count"]))

# 2. Multi-page: shrink the page size so the window spans 3 pages
orig_page = bridge._BARS_PAGE_SIZE
bridge._BARS_PAGE_SIZE = 16
fake = FakeQuote(make_rows(41))
bars = call_bars(fake, 20).get_json()["bars"]
check("walks all pages", len(fake.calls) == 3, str(len(fake.calls)))
check("multi-page keeps newest", bars[-1]["c"] == 40.0 and len(bars) == 20)
bridge._BARS_PAGE_SIZE = orig_page

# 3. Fewer rows than limit → everything available
fake = FakeQuote(make_rows(5))
bars = call_bars(fake, 20).get_json()["bars"]
check("short window returns all rows", len(bars) == 5 and bars[-1]["c"] == 4.0, str(len(bars)))

# 4. limit=2 (lib/feedback.js) → the two latest bars, not the two oldest
fake = FakeQuote(make_rows(41))
bars = call_bars(fake, 2).get_json()["bars"]
check("limit=2 returns latest pair", [b["c"] for b in bars] == [39.0, 40.0], str([b["c"] for b in bars]))

# 5. OpenD error → 500
resp = call_bars(FakeQuote(make_rows(41), fail=True), 20)
check("OpenD error → 500", resp.status_code == 500, str(resp.status_code))

# 6. Lookback window
K = bridge.KLType
check("daily keeps 60-day floor", bridge._bars_window_days(21, K.K_DAY) == 60)
check("daily grows with limit", bridge._bars_window_days(200, K.K_DAY) >= 200 * 7 / 5)
check("intraday window is short", bridge._bars_window_days(60, K.K_1M) == 5)

if failures:
    print(f"\n{len(failures)} failure(s): {failures}")
    sys.exit(1)
print("\nall bars tests passed")
