#!/usr/bin/env python3
"""
moomoo-diag.py — Comprehensive diagnostic tool for MooMoo integration.

Checks OpenD connectivity, account status, positions, and bridge health.
Designed to run on TIALA (where OpenD is running) for local diagnostics,
or remotely via the bridge URL.

Usage:
    # Local mode (direct OpenD connection):
    python3 scripts/moomoo-diag.py

    # Remote mode (via bridge URL):
    python3 scripts/moomoo-diag.py --bridge https://xxx.trycloudflare.com

    # Specify OpenD host/port:
    python3 scripts/moomoo-diag.py --host 127.0.0.1 --port 11111

    # Specify account ID:
    python3 scripts/moomoo-diag.py --acc-id 97585
"""

import argparse
import json
import os
import sys
import time
import urllib.request


def section(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


def ok(msg):
    print(f"  [OK]   {msg}")


def warn(msg):
    print(f"  [WARN] {msg}")


def fail(msg):
    print(f"  [FAIL] {msg}")


def info(msg):
    print(f"  [INFO] {msg}")


# ---------------------------------------------------------------------------
# Remote diagnostics (via bridge HTTP)
# ---------------------------------------------------------------------------
def diagnose_remote(bridge_url):
    """Run diagnostics against the moomoo-bridge HTTP endpoints."""
    bridge_url = bridge_url.rstrip("/")
    section("Remote Bridge Diagnostics")
    info(f"Bridge URL: {bridge_url}")

    # 1. Health check
    section("1. Bridge Health")
    try:
        with urllib.request.urlopen(f"{bridge_url}/health", timeout=10) as resp:
            data = json.loads(resp.read())
            ok(f"Bridge alive: {data.get('service', '?')} @ {data.get('opend', '?')}")
            info(f"  trd_env={data.get('trd_env')} trd_market={data.get('trd_market')}")
            info(f"  timestamp={data.get('timestamp')}")
    except Exception as e:
        fail(f"Bridge unreachable: {e}")
        return

    # 2. Accounts
    section("2. SIMULATE Accounts")
    try:
        with urllib.request.urlopen(f"{bridge_url}/accounts", timeout=10) as resp:
            data = json.loads(resp.read())
            accounts = data.get("accounts", [])
            current = data.get("current_acc_id", 0)
            info(f"Current acc_id: {current}")
            for acc in accounts:
                marker = " <<<" if acc["acc_id"] == current else ""
                print(f"    acc_id={acc['acc_id']}  type={acc.get('sim_acc_type','?')}  "
                      f"market={acc.get('trdmarket_auth','?')}{marker}")
            if not accounts:
                warn("No SIMULATE accounts found")
    except Exception as e:
        fail(f"Accounts query failed: {e}")

    # 3. Account info
    section("3. Account Balance")
    try:
        with urllib.request.urlopen(f"{bridge_url}/account_info", timeout=10) as resp:
            data = json.loads(resp.read())
            info(f"Total Assets:  ${data.get('total_assets', 0):,.2f}")
            info(f"Cash (USD):    ${data.get('cash', 0):,.2f}")
            info(f"Market Value:  ${data.get('market_value', 0):,.2f}")
            info(f"Buying Power:  ${data.get('buying_power', 0):,.2f}")
            info(f"Unrealized PL: ${data.get('unrealized_pl', 0):,.2f}")
            info(f"Risk Status:   {data.get('risk_status', 'N/A')}")
    except Exception as e:
        fail(f"Account info query failed: {e}")

    # 4. Positions
    section("4. Open Positions")
    try:
        with urllib.request.urlopen(f"{bridge_url}/positions", timeout=10) as resp:
            data = json.loads(resp.read())
            positions = data.get("positions", [])
            if positions:
                for p in positions:
                    print(f"    {p['symbol']:>6}  qty={p['qty']:>6}  "
                          f"cost=${p.get('avg_cost',0):>10.2f}  "
                          f"price=${p.get('current_price',0):>10.2f}  "
                          f"pnl=${p.get('unrealized_pnl',0):>+10.2f}  "
                          f"mv=${p.get('market_value',0):>10.2f}")
            else:
                info("No open positions")
    except Exception as e:
        fail(f"Positions query failed: {e}")

    # 5. Quote test
    section("5. Quote Test (AAPL)")
    try:
        with urllib.request.urlopen(f"{bridge_url}/quote?symbol=AAPL", timeout=10) as resp:
            data = json.loads(resp.read())
            info(f"AAPL last=${data.get('last_price',0):.2f}  "
                 f"bid=${data.get('bid',0):.2f}  ask=${data.get('ask',0):.2f}  "
                 f"vol={data.get('volume',0):,}")
            ok("Quote endpoint working")
    except Exception as e:
        warn(f"Quote test failed (may be outside market hours): {e}")

    section("Diagnostic Complete")


# ---------------------------------------------------------------------------
# Local diagnostics (direct OpenD via Python SDK)
# ---------------------------------------------------------------------------
def diagnose_local(host, port, acc_id, security_firm):
    """Run diagnostics using direct OpenD TCP connection."""
    section("Local OpenD Diagnostics")
    info(f"OpenD: {host}:{port}")
    info(f"acc_id: {acc_id or 'auto (0)'}")
    info(f"security_firm: {security_firm}")

    try:
        from moomoo import (
            OpenSecTradeContext, OpenQuoteContext,
            TrdEnv, TrdMarket, RET_OK, SecurityFirm,
        )
    except ImportError:
        fail("moomoo-api not installed. Run: pip install moomoo-api")
        return

    firm_map = {
        "FUTUINC": SecurityFirm.FUTUINC,
        "FUTUSECURITIES": SecurityFirm.FUTUSECURITIES,
    }
    firm = firm_map.get(security_firm, SecurityFirm.FUTUINC)

    # 1. Trade context connection
    section("1. OpenD Trade Connection")
    trd_ctx = None
    try:
        trd_ctx = OpenSecTradeContext(
            filter_trdmarket=TrdMarket.US,
            host=host, port=port,
            security_firm=firm,
        )
        ok(f"Trade context connected to {host}:{port}")
    except Exception as e:
        fail(f"Cannot connect to OpenD: {e}")
        print("\n  Troubleshooting:")
        print("    1. Is OpenD running? Check Activity Monitor / ps aux | grep OpenD")
        print("    2. Is the port correct? Default is 11111")
        print("    3. Is the host reachable?")
        return

    # 2. Account list
    section("2. SIMULATE Accounts")
    try:
        ret, data = trd_ctx.get_acc_list()
        if ret == RET_OK:
            sim_accounts = []
            for _, row in data.iterrows():
                if str(row.get("trd_env", "")) == "SIMULATE":
                    acc = {
                        "acc_id": int(row.get("acc_id", 0)),
                        "sim_acc_type": str(row.get("sim_acc_type", "")),
                        "acc_type": str(row.get("acc_type", "")),
                        "trdmarket_auth": str(row.get("trdmarket_auth", "")),
                    }
                    sim_accounts.append(acc)
                    marker = " <<<" if acc["acc_id"] == acc_id else ""
                    print(f"    acc_id={acc['acc_id']}  sim_type={acc['sim_acc_type']}  "
                          f"acc_type={acc['acc_type']}  market={acc['trdmarket_auth']}{marker}")
            if not sim_accounts:
                warn("No SIMULATE accounts found")
            elif acc_id:
                found = any(a["acc_id"] == acc_id for a in sim_accounts)
                if found:
                    ok(f"Target acc_id {acc_id} found in SIMULATE accounts")
                else:
                    fail(f"Target acc_id {acc_id} NOT found in SIMULATE accounts!")
        else:
            fail(f"get_acc_list failed: {data}")
    except Exception as e:
        fail(f"Account list error: {e}")

    # 3. Account info (with refresh)
    section("3. Account Balance (refresh_cache=True)")
    try:
        ret, data = trd_ctx.accinfo_query(
            trd_env=TrdEnv.SIMULATE,
            acc_id=acc_id,
            refresh_cache=True,
        )
        if ret == RET_OK:
            row = data.iloc[0]
            total = float(row.get("total_assets", 0) or 0)
            cash = float(row.get("us_cash", 0) or 0) or float(row.get("cash", 0) or 0)
            mv = float(row.get("market_val", 0) or 0)
            power = float(row.get("power", 0) or 0)
            info(f"Total Assets:  ${total:,.2f}")
            info(f"Cash (USD):    ${cash:,.2f}")
            info(f"Market Value:  ${mv:,.2f}")
            info(f"Buying Power:  ${power:,.2f}")
            ok("accinfo_query OK")
        else:
            fail(f"accinfo_query failed: {data}")
    except Exception as e:
        fail(f"Account info error: {e}")

    # 4. Positions
    section("4. Open Positions (refresh_cache=True)")
    try:
        ret, data = trd_ctx.position_list_query(
            trd_env=TrdEnv.SIMULATE,
            acc_id=acc_id,
            refresh_cache=True,
        )
        if ret == RET_OK:
            count = 0
            for _, row in data.iterrows():
                qty = float(row.get("qty", 0) or 0)
                if qty == 0:
                    continue
                count += 1
                code = str(row.get("code", ""))
                cost = float(row.get("cost_price", 0) or 0)
                price = float(row.get("nominal_price", 0) or 0)
                mv = float(row.get("market_val", 0) or 0)
                print(f"    {code:>10}  qty={qty:>6.0f}  cost=${cost:>10.2f}  "
                      f"price=${price:>10.2f}  mv=${mv:>10.2f}")
            if count == 0:
                info("No open positions")
            else:
                info(f"Total: {count} position(s)")
            ok("position_list_query OK")
        else:
            fail(f"position_list_query failed: {data}")
    except Exception as e:
        fail(f"Positions error: {e}")

    # 5. Quote context
    section("5. OpenD Quote Connection")
    quote_ctx = None
    try:
        quote_ctx = OpenQuoteContext(host=host, port=port)
        ok(f"Quote context connected to {host}:{port}")

        ret, data = quote_ctx.get_market_snapshot(["US.AAPL"])
        if ret == RET_OK and len(data) > 0:
            row = data.iloc[0]
            last = float(row.get("last_price", 0) or 0)
            info(f"AAPL last_price=${last:.2f}")
            ok("Quote endpoint working")
        else:
            warn(f"Quote snapshot returned: {data}")
    except Exception as e:
        warn(f"Quote test failed (may be outside market hours): {e}")
    finally:
        if quote_ctx:
            try:
                quote_ctx.close()
            except Exception:
                pass

    # Cleanup
    if trd_ctx:
        try:
            trd_ctx.close()
        except Exception:
            pass

    section("Diagnostic Complete")


def main():
    parser = argparse.ArgumentParser(description="MooMoo integration diagnostic tool")
    parser.add_argument("--bridge", type=str, default=None,
                        help="Bridge URL for remote diagnostics (e.g. https://xxx.trycloudflare.com)")
    parser.add_argument("--host", type=str, default="127.0.0.1",
                        help="OpenD host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=11111,
                        help="OpenD port (default: 11111)")
    parser.add_argument("--acc-id", type=int, default=int(os.environ.get("MOOMOO_ACC_ID", "0")),
                        help="SIMULATE account ID (default: from MOOMOO_ACC_ID env or 0=auto)")
    parser.add_argument("--security-firm", type=str, default="FUTUINC",
                        help="Security firm (default: FUTUINC)")
    args = parser.parse_args()

    print("MooMoo Integration Diagnostic Tool")
    print(f"Time: {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")

    if args.bridge:
        diagnose_remote(args.bridge)
    else:
        diagnose_local(args.host, args.port, args.acc_id, args.security_firm)


if __name__ == "__main__":
    main()
