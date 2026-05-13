#!/usr/bin/env python3
"""
moomoo-test-order.py — Test paper trading order placement via the bridge.

Places a small test order (1 share) and verifies the response.
Supports both local bridge and remote tunnel URLs.

Usage:
    # Via local bridge:
    python3 scripts/moomoo-test-order.py --symbol AAPL --side BUY --qty 1

    # Via remote bridge:
    python3 scripts/moomoo-test-order.py --bridge https://xxx.trycloudflare.com --symbol AAPL --side BUY --qty 1

    # Dry run (show what would be sent):
    python3 scripts/moomoo-test-order.py --symbol AAPL --side BUY --qty 1 --dry-run
"""

import argparse
import json
import os
import sys
import urllib.request


def main():
    parser = argparse.ArgumentParser(description="Test MooMoo paper trading order")
    parser.add_argument("--bridge", type=str, default="http://localhost:11436",
                        help="Bridge URL (default: http://localhost:11436)")
    parser.add_argument("--symbol", type=str, required=True, help="Stock symbol (e.g. AAPL)")
    parser.add_argument("--side", type=str, required=True, choices=["BUY", "SELL"],
                        help="Order side: BUY or SELL")
    parser.add_argument("--qty", type=int, default=1, help="Quantity (default: 1)")
    parser.add_argument("--order-type", type=str, default="MARKET",
                        choices=["MARKET", "LIMIT"], help="Order type (default: MARKET)")
    parser.add_argument("--price", type=float, default=0, help="Price for LIMIT orders")
    parser.add_argument("--remark", type=str, default="test-order", help="Order remark")
    parser.add_argument("--dry-run", action="store_true", help="Show request without sending")
    args = parser.parse_args()

    bridge_url = args.bridge.rstrip("/")
    payload = {
        "symbol": args.symbol.upper(),
        "side": args.side.upper(),
        "qty": args.qty,
        "order_type": args.order_type,
        "price": args.price,
        "remark": args.remark[:64],
    }

    print(f"Bridge:  {bridge_url}")
    print(f"Request: POST /place_order")
    print(f"Payload: {json.dumps(payload, indent=2)}")

    if args.dry_run:
        print("\n[DRY RUN] Order not sent.")
        return

    # Confirm before sending
    confirm = input("\nSend order? [y/N]: ").strip().lower()
    if confirm != "y":
        print("Cancelled.")
        return

    try:
        req = urllib.request.Request(
            f"{bridge_url}/place_order",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
            print(f"\nResponse ({resp.status}):")
            print(json.dumps(result, indent=2))

            if result.get("success"):
                print(f"\nOrder placed successfully!")
                print(f"  Order ID:     {result.get('order_id')}")
                print(f"  Status:       {result.get('status')}")
                print(f"  Filled Price: {result.get('filled_price')}")
                print(f"  Filled Qty:   {result.get('filled_qty')}")
            else:
                print(f"\nOrder FAILED: {result.get('error')}")

    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"\nHTTP Error {e.code}: {body}")
    except Exception as e:
        print(f"\nError: {e}")


if __name__ == "__main__":
    main()
