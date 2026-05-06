#!/usr/bin/env python3
"""
register-ngrok.py — Query ngrok local API and register the tunnel URL
in BigQuery service_endpoints table.

Run on TIALA after starting ngrok:
    python3 scripts/register-ngrok.py

Requirements:
    pip install google-cloud-bigquery
"""

import json
import sys
import urllib.request

NGROK_API = "http://localhost:4040/api/tunnels"
PROJECT_ID = "screen-share-459802"
DATASET = "magi_core"
TABLE = "service_endpoints"
SERVICE_NAME = "opend-proxy"


def get_ngrok_url():
    try:
        with urllib.request.urlopen(NGROK_API, timeout=5) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"[ERROR] ngrok API unreachable ({NGROK_API}): {e}")
        print("Is ngrok running? Start it with: ngrok http 11436")
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
    url = get_ngrok_url()
    print(f"[ngrok] Detected URL: {url}")

    update_bigquery(url)
    print(f"[BigQuery] Registered {SERVICE_NAME} = {url}")


if __name__ == "__main__":
    main()
