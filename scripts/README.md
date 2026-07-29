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
| `register-service.py` | Register magi-moomoo Cloud Run URL in BigQuery |
| `setup-openclaw-named-tunnel.sh` | Create a Cloudflare Named Tunnel for the OpenClaw Gateway |
| `start-openclaw-named-tunnel.sh` | Start the OpenClaw named tunnel |
| `install-openclaw-launchagent.sh` | Install a LaunchAgent for the OpenClaw named tunnel |
| `com.magi.openclaw.cloudflared.plist` | macOS LaunchAgent template for OpenClaw tunnel |

## Quick Start (TIALA)

```bash
# 1. Install tools
bash scripts/setup-tools.sh

# 2. Start OpenD (MooMoo app or command-line)

# 3. Start bridge + tunnel (auto-registers opend-proxy URL in BigQuery)
bash scripts/start-bridge.sh

# 4. Run diagnostics
python3 scripts/moomoo-diag.py

# 5. Check bridge remotely
bash scripts/moomoo-check-bridge.sh https://xxx.trycloudflare.com
```

## Cloud Run Deployment

The magi-moomoo proxy is deployed to Cloud Run automatically on push to `main`
via `.github/workflows/deploy.yml`. The workflow also registers the Cloud Run
URL in BigQuery `service_endpoints` as `magi-moomoo`.

To register manually after a first-time deployment:
```bash
# Auto-detect URL from gcloud:
python3 scripts/register-service.py

# Or provide the URL explicitly:
python3 scripts/register-service.py https://magi-moomoo-xxxx.asia-northeast1.run.app
```

## Connectivity Check

Verify the full chain (proxy -> bridge -> OpenD):
```bash
# Via Cloud Run (requires OIDC token):
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  https://magi-moomoo-xxxx.asia-northeast1.run.app/connectivity

# Response when healthy:
# { "status": "ok", "checks": { "proxy": "ok", "bridge_url": "https://...", "bridge_health": {...} } }
```

## Common Operations

### Check bridge health
```bash
bash scripts/moomoo-check-bridge.sh
```

### Run full diagnostics (local OpenD)
```bash
python3 scripts/moomoo-diag.py --acc-id 1302593
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
| `MOOMOO_ACC_ID` | *(auto-discover)* | Account ID. SIMULATE: if unset, bridge auto-selects via `sim_acc_type`. **REAL: must be set explicitly** (no auto-discovery in REAL) |
| `OPEND_HOST` | `127.0.0.1` | OpenD TCP host |
| `OPEND_PORT` | `11111` | OpenD TCP port |
| `BRIDGE_PORT` | `11436` | Bridge HTTP port |
| `SECURITY_FIRM` | `FUTUINC` | SecurityFirm enum value. Use `FUTUJP` for the moomoo Japan production (REAL) account |
| `TRD_MARKET` | `US` | Trading market filter |
| `TRD_ENV` | `SIMULATE` | `SIMULATE` (paper) or `REAL` (live). Defaults to SIMULATE for safety |
| `MOOMOO_TRADE_PASSWORD` | *(unset)* | Trade unlock password — **REAL only**. Supply via Secret Manager, never hardcode |
| `MOOMOO_TRADE_PASSWORD_MD5` | *(unset)* | Pre-computed MD5 of the unlock password — alternative to plaintext |
| `MOOMOO_ALLOW_REAL_ORDERS` | `false` | When `TRD_ENV=REAL`, order placement stays blocked (read-only) unless this is `true` |

### REAL (production) trading notes

- REAL is **opt-in**: the bridge defaults to `SIMULATE`. Setting `TRD_ENV=REAL` alone enables
  read-only account/position queries against the live account but **does not** allow order
  placement — `/place_order` returns HTTP 403 until `MOOMOO_ALLOW_REAL_ORDERS=true` is also set.
- The moomoo Japan production comprehensive account is under `SECURITY_FIRM=FUTUJP` and exposes
  separate sub-accounts (MARGIN / CASH / DERIVATIVES) each with its own `acc_id`; pin the intended
  one via `MOOMOO_ACC_ID`.
- In REAL, the bridge calls `unlock_trade()` using `MOOMOO_TRADE_PASSWORD` (or `_MD5`). Unlock is
  required for order placement; query endpoints work without it.
- `moomoo-diag.py` lists **all** accounts (SIMULATE + REAL). For REAL balances/positions pass
  `--security-firm FUTUJP --trd-env REAL --acc-id <id>`.

## Architecture

```
Cloud Scheduler → magi-core (Cloud Run) → magi-moomoo (Cloud Run)
                                              ↓ cloudflared tunnel
                                         moomoo_bridge.py (TIALA)
                                              ↓ TCP
                                         OpenD (TIALA) → MooMoo Server
```

## Ollama Named Tunnel (ADAM / PLM)

ADAM uses a self-hosted Ollama instance on TIALA. The Cloud Run Job reads
`OLLAMA_BASE_URL` from Secret Manager. By default the URL is a temporary
`*.trycloudflare.com` quick tunnel that changes on restart, causing failures
when it goes stale.

Use these scripts to create a permanent Cloudflare Named Tunnel pointing to
`localhost:11434` and write the fixed URL to `OLLAMA_BASE_URL`:

```bash
# One-time setup (requires cloudflared login and a Cloudflare-managed domain)
bash scripts/setup-ollama-named-tunnel.sh ollama.khaos.company

# Start the tunnel in the foreground
bash scripts/start-ollama-named-tunnel.sh

# Or install as a persistent macOS LaunchAgent (one command)
# This fetches OLLAMA_TUNNEL_TOKEN from Secret Manager, writes the credentials
# file, and registers the LaunchAgent.
bash scripts/install-ollama-launchagent.sh ollama.khaos.company

# Or install the LaunchAgent manually
cp scripts/com.magi.ollama.cloudflared.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.magi.ollama.cloudflared.plist
```

The setup/install script:
- creates the tunnel (setup only) or fetches an existing token (install only)
- routes the chosen hostname to the tunnel
- writes `~/.cloudflared/config-magi-ollama.yml`
- sets `httpHostHeader` to `localhost:${OLLAMA_PORT}` by default to satisfy Ollama's CORS/Host validation
- updates Secret Manager `OLLAMA_BASE_URL` to `https://<hostname>` (setup only)

Use `OLLAMA_HOST_HEADER` to override the Host header sent to Ollama (e.g. if a local proxy at `11435` rewrites the header).

After setup, ADAM's Cloud Run Job will pick up the new secret value on the
next scheduled run.

## BigQuery Service Discovery

| service | registered by | description |
|---|---|---|
| `magi-moomoo` | `deploy.yml` / `register-service.py` | Cloud Run proxy URL |
| `opend-proxy` | `start-bridge.sh` / `register-tunnel.py` | Bridge tunnel URL (cloudflared/ngrok) |
| `openclaw` | `setup-openclaw-named-tunnel.sh` / `install-openclaw-launchagent.sh` | OpenClaw Gateway URL for Devin/AKA-1 TIALA ops |

magi-core looks up `magi-moomoo`, and the proxy looks up `opend-proxy`.
`magi-moni` / Devin looks up `openclaw` to reach TIALA.

## OpenClaw Named Tunnel (Devin / AKA-1 TIALA operations)

`magi-moni` uses the OpenClaw Gateway on TIALA for remote service checks, shell
commands, screenshots, and GUI actions. By default it discovers the gateway URL
from BigQuery `service_endpoints` (service=`openclaw`). The old quick tunnel
(`*.trycloudflare.com`) expired whenever cloudflared restarted, blocking Devin
from operating TIALA.

Use these scripts to create a permanent Cloudflare Named Tunnel pointing to
`localhost:18789` and register the fixed URL in BigQuery:

```bash
# One-time setup (requires cloudflared login and a Cloudflare-managed domain)
bash scripts/setup-openclaw-named-tunnel.sh openclaw.khaos.company

# Start the tunnel in the foreground
bash scripts/start-openclaw-named-tunnel.sh

# Or install as a persistent macOS LaunchAgent (one command)
# This fetches OPENCLAW_TUNNEL_TOKEN from Secret Manager, writes the credentials
# file, and registers the LaunchAgent.
bash scripts/install-openclaw-launchagent.sh openclaw.khaos.company

# Or install the LaunchAgent manually
cp scripts/com.magi.openclaw.cloudflared.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.magi.openclaw.cloudflared.plist
```

The setup/install script:
- creates the tunnel (setup only) or fetches an existing token (install only)
- routes the chosen hostname to the tunnel
- writes `~/.cloudflared/config-magi-openclaw.yml`
- registers `openclaw` in BigQuery `service_endpoints` so `magi-moni` and Devin can discover it
- prints the base64 `OPENCLAW_TUNNEL_TOKEN` to store in Secret Manager (setup only)

Use `OPENCLAW_PORT` / `OPENCLAW_HOST_HEADER` env vars to override the local
OpenClaw Gateway port or Host header.
