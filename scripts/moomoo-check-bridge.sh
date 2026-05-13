#!/bin/bash
# moomoo-check-bridge.sh — Quick health check for the moomoo-bridge.
#
# Usage:
#   bash scripts/moomoo-check-bridge.sh                          # auto-detect from BigQuery
#   bash scripts/moomoo-check-bridge.sh https://xxx.trycloudflare.com  # explicit URL
#   bash scripts/moomoo-check-bridge.sh http://localhost:11436   # local bridge

set -euo pipefail

if [ -n "${1:-}" ]; then
  BRIDGE_URL="${1%/}"
else
  # Try local bridge first
  if curl -sf http://localhost:11436/health >/dev/null 2>&1; then
    BRIDGE_URL="http://localhost:11436"
  else
    echo "[check] Local bridge not running, querying BigQuery for tunnel URL..."
    BRIDGE_URL=$(python3 -c "
from google.cloud import bigquery
c = bigquery.Client(project='screen-share-459802')
rows = list(c.query('''SELECT url FROM \`screen-share-459802.magi_core.service_endpoints\`
  WHERE service = \"opend-proxy\" ORDER BY updated_at DESC LIMIT 1''', location='US').result())
print(rows[0].url if rows else '')
" 2>/dev/null)
    if [ -z "${BRIDGE_URL}" ]; then
      echo "[FAIL] No bridge URL found in BigQuery"
      exit 1
    fi
  fi
fi

echo "Bridge URL: ${BRIDGE_URL}"
echo ""

# Health
echo "--- Health ---"
curl -sf "${BRIDGE_URL}/health" | python3 -m json.tool 2>/dev/null || echo "  FAIL: bridge unreachable"
echo ""

# Accounts
echo "--- Accounts ---"
curl -sf "${BRIDGE_URL}/accounts" | python3 -m json.tool 2>/dev/null || echo "  FAIL: accounts endpoint error"
echo ""

# Account Info
echo "--- Account Info ---"
curl -sf "${BRIDGE_URL}/account_info" | python3 -m json.tool 2>/dev/null || echo "  FAIL: account_info endpoint error"
echo ""

# Positions
echo "--- Positions ---"
curl -sf "${BRIDGE_URL}/positions" | python3 -m json.tool 2>/dev/null || echo "  FAIL: positions endpoint error"
echo ""

echo "Done."
