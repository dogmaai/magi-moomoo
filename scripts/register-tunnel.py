#!/usr/bin/env python3
"""
register-tunnel.py — Register a tunnel URL (cloudflared or ngrok) in BigQuery
service_endpoints table.

Usage:
    # With explicit URL argument:
    python3 scripts/register-tunnel.py https://xxx.trycloudflare.com

    # Auto-detect from ngrok API (legacy fallback):
    python3 scripts/register-tunnel.py --ngrok

Requirements:
    pip install google-cloud-bigquery
"""

import json
import os
import sys
import urllib.request

PROJECT_ID = "screen-share-459802"

# Default service-account key on TIALA. gcloud ADC user tokens expire and
# cannot be refreshed non-interactively, so prefer an explicit SA key.
DEFAULT_SA_KEY = os.path.expanduser("~/.config/gcloud/service-account-key.json")
DATASET = "magi_core"
TABLE = "service_endpoints"
SERVICE_NAME = "opend-proxy"

NGROK_API = "http://localhost:4040/api/tunnels"


def get_ngrok_url():
    """Query ngrok local API for the active tunnel URL."""
    try:
        with urllib.request.urlopen(NGROK_API, timeout=5) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"[ERROR] ngrok API unreachable ({NGROK_API}): {e}")
        sys.exit(1)

    tunnels = data.get("tunnels", [])
    for t in tunnels:
        if t.get("proto") == "https" or t.get("public_url", "").startswith("https://"):
            return t["public_url"]

    if tunnels:
        return tunnels[0]["public_url"]

    print("[ERROR] No active ngrok tunnels found.")
    sys.exit(1)


def _bq_client():
    """Build a BigQuery client, preferring the local service-account key.

    Priority: GOOGLE_APPLICATION_CREDENTIALS env var > DEFAULT_SA_KEY file >
    ambient ADC (gcloud user credentials, which may be expired).
    """
    from google.cloud import bigquery

    if not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS") and os.path.isfile(DEFAULT_SA_KEY):
        from google.oauth2 import service_account

        creds = service_account.Credentials.from_service_account_file(DEFAULT_SA_KEY)
        print(f"[auth] Using service-account key: {DEFAULT_SA_KEY}")
        return bigquery.Client(project=PROJECT_ID, credentials=creds)
    return bigquery.Client(project=PROJECT_ID)


def get_current_url():
    """Check the latest registered URL in BigQuery."""
    from google.cloud import bigquery

    client = _bq_client()
    fqn = f"`{PROJECT_ID}.{DATASET}.{TABLE}`"

    query = f"""
        SELECT url FROM {fqn}
        WHERE service = @service
        ORDER BY updated_at DESC
        LIMIT 1
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("service", "STRING", SERVICE_NAME),
        ]
    )
    rows = list(client.query(query, job_config=job_config, location="US").result())
    return rows[0]["url"] if rows else None


def update_bigquery(url):
    """Insert tunnel URL into BigQuery service_endpoints (idempotent)."""
    from google.cloud import bigquery

    # Skip if already registered with same URL
    current = get_current_url()
    if current == url:
        print(f"[BigQuery] URL already current: {url} — skipping insert")
        return

    client = _bq_client()
    fqn = f"`{PROJECT_ID}.{DATASET}.{TABLE}`"

    query = f"""
        INSERT INTO {fqn} (service, url, updated_at)
        VALUES (@service, @url, CAST(CURRENT_TIMESTAMP() AS STRING))
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("service", "STRING", SERVICE_NAME),
            bigquery.ScalarQueryParameter("url", "STRING", url),
        ]
    )
    client.query(query, job_config=job_config, location="US").result()


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 register-tunnel.py <URL>")
        print("       python3 register-tunnel.py --ngrok")
        sys.exit(1)

    arg = sys.argv[1]

    if arg == "--ngrok":
        url = get_ngrok_url()
        print(f"[ngrok] Detected URL: {url}")
    elif arg.startswith("http"):
        url = arg.rstrip("/")
        print(f"[tunnel] Using URL: {url}")
    else:
        print(f"[ERROR] Invalid argument: {arg}")
        print("Provide a URL (https://...) or --ngrok")
        sys.exit(1)

    update_bigquery(url)
    print(f"[BigQuery] Registered {SERVICE_NAME} = {url}")


if __name__ == "__main__":
    main()
