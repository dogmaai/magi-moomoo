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
import sys
import urllib.request

PROJECT_ID = "screen-share-459802"
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


def update_bigquery(url):
    """Insert tunnel URL into BigQuery service_endpoints."""
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT_ID)
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
