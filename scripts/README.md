# MooMoo Integration Scripts

Tools for managing the MooMoo paper trading bridge (OpenD ↔ magi-core).

## Prerequisites

- Python 3.10+ with `moomoo-api`, `flask`, `google-cloud-bigquery`
- `cloudflared` (Cloudflare tunnel)
- MooMoo OpenD running on localhost:11111
- GCP credentials (ADC or `GOOGLE_APPLICATION_CREDENTIALS`)

Run `bash scripts/setup-tools.sh` to install everything.

## Scripts

| Script | Description |
|---|---|
| `start-bridge.sh` | Start bridge + cloudflared tunnel + register URL in BigQuery |
| `setup-tools.sh` | Install all Python/Node.js/system dependencies |
| `moomoo-diag.py` | Full diagnostic — checks OpenD, accounts, balance, positions, quotes |
| `moomoo-check-bridge.sh` | Quick bridge health check (curl-based) |
| `moomoo-test-order.py` | Place a test paper trading order |
| `moomoo-liquidate.py` | Sell all open positions (account reset helper) |
| `register-tunnel.py` | Register tunnel URL in BigQuery `service_endpoints` |

## Quick Start (TIALA)

```bash
# 1. Install tools
bash scripts/setup-tools.sh

# 2. Start OpenD (MooMoo app or command-line)

# 3. Start bridge + tunnel
bash scripts/start-bridge.sh

# 4. Run diagnostics
python3 scripts/moomoo-diag.py

# 5. Check bridge remotely
bash scripts/moomoo-check-bridge.sh https://xxx.trycloudflare.com
```

## Common Operations

### Check bridge health
```bash
bash scripts/moomoo-check-bridge.sh
```

### Run full diagnostics (local OpenD)
```bash
python3 scripts/moomoo-diag.py --acc-id 97585
```

### Run diagnostics via tunnel
```bash
python3 scripts/moomoo-diag.py --bridge https://xxx.trycloudflare.com
```

### Place a test order
```bash
# Dry run first
python3 scripts/moomoo-test-order.py --symbol AAPL --side BUY --qty 1 --dry-run

# Actually place the order
python3 scripts/moomoo-test-order.py --symbol AAPL --side BUY --qty 1
```

### Liquidate all positions
```bash
# See what would be sold
python3 scripts/moomoo-liquidate.py --dry-run

# Actually sell everything
python3 scripts/moomoo-liquidate.py
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `MOOMOO_ACC_ID` | `97585` | SIMULATE account ID (STOCK account) |
| `OPEND_HOST` | `127.0.0.1` | OpenD TCP host |
| `OPEND_PORT` | `11111` | OpenD TCP port |
| `BRIDGE_PORT` | `11436` | Bridge HTTP port |
| `SECURITY_FIRM` | `FUTUINC` | SecurityFirm enum value |
| `TRD_MARKET` | `US` | Trading market filter |

## Architecture

```
Cloud Scheduler → magi-core (Cloud Run) → magi-moomoo (Cloud Run)
                                              ↓ cloudflared tunnel
                                         moomoo_bridge.py (TIALA)
                                              ↓ TCP
                                         OpenD (TIALA) → MooMoo Server
```
