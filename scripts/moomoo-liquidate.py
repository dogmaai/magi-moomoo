#!/usr/bin/env python3
"""
moomoo-liquidate.py — Liquidate all open positions in the paper trading account.

Useful for resetting the account to a clean state. Sells all open positions
via the bridge API.

Usage:
    # Via local bridge:
    python3 scripts/moomoo-liquidate.py

    # Via remote bridge:
    python3 scripts/moomoo-liquidate.py --bridge https://xxx.trycloudflare.com

    # Dry run (show positions without selling):
    python3 scripts/moomoo-liquidate.py --dry-run
"""

import argparse
import json
import sys
import time
import urllib.request


def get_positions(bridge_url):
    """Fetch current positions from the bridge."""
    with urllib.request.urlopen(f"{bridge_url}/positions", timeout=15) as resp:
        data = json.loads(resp.read())
        return data.get("positions", [])


def sell_position(bridge_url, symbol, qty):
    """Place a SELL order for the given position."""
    payload = {
        "symbol": symbol,
        "side": "SELL",
        "qty": int(qty),
        "order_type": "MARKET",
        "price": 0,
        "remark": "liquidate-all",
    }
    req = urllib.request.Request(
        f"{bridge_url}/place_order",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def main():
    parser = argparse.ArgumentParser(description="Liquidate all paper trading positions")
    parser.add_argument("--bridge", type=str, default="http://localhost:11436",
                        help="Bridge URL (default: http://localhost:11436)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show positions without selling")
    args = parser.parse_args()

    bridge_url = args.bridge.rstrip("/")
    print(f"Bridge: {bridge_url}")

    # Check bridge health
    try:
        with urllib.request.urlopen(f"{bridge_url}/health", timeout=10) as resp:
            json.loads(resp.read())
    except Exception as e:
        print(f"[FAIL] Bridge unreachable: {e}")
        sys.exit(1)

    # Get positions
    print("\nFetching positions...")
    try:
        positions = get_positions(bridge_url)
    except Exception as e:
        print(f"[FAIL] Cannot fetch positions: {e}")
        sys.exit(1)

    if not positions:
        print("No open positions. Account is clean.")
        return

    print(f"\nFound {len(positions)} position(s):")
    total_mv = 0
    for p in positions:
        qty = p.get("qty", 0)
        mv = p.get("market_value", 0)
        total_mv += mv
        print(f"  {p['symbol']:>6}  qty={qty:>6.0f}  "
              f"cost=${p.get('avg_cost',0):>10.2f}  "
              f"price=${p.get('current_price',0):>10.2f}  "
              f"mv=${mv:>10.2f}")
    print(f"\n  Total Market Value: ${total_mv:,.2f}")

    if args.dry_run:
        print("\n[DRY RUN] No orders placed.")
        return

    # Confirm
    confirm = input(f"\nSell ALL {len(positions)} positions? [y/N]: ").strip().lower()
    if confirm != "y":
        print("Cancelled.")
        return

    # Liquidate
    print("\nLiquidating...")
    success = 0
    failed = 0
    for p in positions:
        symbol = p["symbol"]
        qty = int(p.get("can_sell_qty", 0) or p.get("qty", 0))
        if qty <= 0:
            print(f"  {symbol}: SKIP (qty={qty})")
            continue
        try:
            result = sell_position(bridge_url, symbol, qty)
            if result.get("success"):
                print(f"  {symbol}: SOLD {qty} shares "
                      f"(order_id={result.get('order_id')}, "
                      f"status={result.get('status')})")
                success += 1
            else:
                print(f"  {symbol}: FAILED - {result.get('error')}")
                failed += 1
        except Exception as e:
            print(f"  {symbol}: ERROR - {e}")
            failed += 1
        time.sleep(0.5)  # brief pause between orders

    print(f"\nDone: {success} sold, {failed} failed")

    # Show updated account info
    print("\nUpdated account:")
    try:
        with urllib.request.urlopen(f"{bridge_url}/account_info", timeout=10) as resp:
            data = json.loads(resp.read())
            print(f"  Total Assets: ${data.get('total_assets', 0):,.2f}")
            print(f"  Cash:         ${data.get('cash', 0):,.2f}")
            print(f"  Market Value: ${data.get('market_value', 0):,.2f}")
    except Exception as e:
        print(f"  [WARN] Cannot fetch updated info: {e}")


if __name__ == "__main__":
    main()
