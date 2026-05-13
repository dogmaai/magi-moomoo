#!/bin/bash
# setup-tools.sh — Install all dependencies needed for MooMoo integration tools.
#
# Usage (on TIALA or dev machine):
#   bash scripts/setup-tools.sh
#
# This installs:
#   - Python: moomoo-api, flask, google-cloud-bigquery
#   - System: cloudflared (Cloudflare tunnel)
#   - Node.js: project dependencies (for magi-moomoo proxy)

set -e

echo "=== MooMoo Integration Tools Setup ==="
echo ""

# --- 1. Python dependencies ---
echo "[1/3] Installing Python dependencies..."
pip3 install --upgrade moomoo-api flask google-cloud-bigquery 2>&1 | tail -5
echo "  moomoo-api: $(python3 -c 'import moomoo; print(moomoo.__version__)' 2>/dev/null || echo 'FAIL')"
echo ""

# --- 2. cloudflared ---
echo "[2/3] Installing cloudflared..."
if command -v cloudflared >/dev/null 2>&1; then
  echo "  Already installed: $(cloudflared --version)"
else
  OS=$(uname -s)
  ARCH=$(uname -m)
  if [ "$OS" = "Darwin" ]; then
    if command -v brew >/dev/null 2>&1; then
      brew install cloudflared
    else
      echo "  [WARN] Homebrew not found. Install manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    fi
  elif [ "$OS" = "Linux" ]; then
    if [ "$ARCH" = "x86_64" ]; then
      curl -L --output /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
      sudo dpkg -i /tmp/cloudflared.deb
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
      curl -L --output /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
      sudo dpkg -i /tmp/cloudflared.deb
    else
      echo "  [WARN] Unsupported architecture: $ARCH. Install manually."
    fi
  fi
  echo "  Installed: $(cloudflared --version 2>/dev/null || echo 'FAIL')"
fi
echo ""

# --- 3. Node.js dependencies (if package.json exists) ---
echo "[3/3] Installing Node.js dependencies..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
if [ -f "$REPO_ROOT/package.json" ]; then
  cd "$REPO_ROOT" && npm install --production 2>&1 | tail -3
  echo "  Node modules installed"
else
  echo "  [SKIP] No package.json found"
fi
echo ""

# --- Summary ---
echo "=== Setup Complete ==="
echo ""
echo "Installed tools:"
echo "  Python SDK:   moomoo-api $(python3 -c 'import moomoo; print(moomoo.__version__)' 2>/dev/null || echo 'N/A')"
echo "  Flask:        $(python3 -c 'import flask; print(flask.__version__)' 2>/dev/null || echo 'N/A')"
echo "  BigQuery:     $(python3 -c 'from google.cloud import bigquery; print(bigquery.__version__)' 2>/dev/null || echo 'N/A')"
echo "  cloudflared:  $(cloudflared --version 2>/dev/null || echo 'N/A')"
echo "  Node.js:      $(node --version 2>/dev/null || echo 'N/A')"
echo ""
echo "Available scripts:"
echo "  scripts/start-bridge.sh       — Start bridge + tunnel + register URL"
echo "  scripts/moomoo-diag.py        — Full diagnostic (local or remote)"
echo "  scripts/moomoo-check-bridge.sh — Quick bridge health check"
echo "  scripts/moomoo-test-order.py  — Test paper trading order"
echo "  scripts/moomoo-liquidate.py   — Liquidate all positions"
echo "  scripts/register-tunnel.py    — Register tunnel URL in BigQuery"
echo ""
echo "Quick start:"
echo "  1. Start OpenD (MooMoo app or command-line)"
echo "  2. bash scripts/start-bridge.sh"
echo "  3. python3 scripts/moomoo-diag.py"
