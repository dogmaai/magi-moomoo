#!/usr/bin/env python3
"""
register-service.py — Register the magi-moomoo Cloud Run service URL
in BigQuery service_endpoints table.

Usage:
    # Auto-detect from gcloud:
    python3 scripts/register-service.py

    # With explicit URL:
    python3 scripts/register-service.py https://magi-moomoo-xxxx.asia-northeast1.run.app

Requirements:
    pip install google-cloud-bigquery
    gcloud CLI (for auto-detect mode)
"""

import subprocess
import sys

PROJECT_ID = "screen-share-459802"
REGION = "asia-northeast1"
DATASET = "magi_core"
TABLE = "service_endpoints"
SERVICE_NAME = "magi-moomoo"
CLOUD_RUN_SERVICE = "magi-moomoo"


def get_cloud_run_url():
    """Auto-detect the magi-moomoo Cloud Run service URL via gcloud."""
    try:
        result = subprocess.run(
            [
                "gcloud", "run", "services", "describe", CLOUD_RUN_SERVICE,
                "--region", REGION,
                "--project", PROJECT_ID,
                "--format", "value(status.url)",
            ],
            capture_output=True, text=True, check=True,
        )
        url = result.stdout.strip()
        if not url:
            print("[ERROR] gcloud returned empty URL. Is magi-moomoo deployed?")
            sys.exit(1)
        return url
    except FileNotFoundError:
        print("[ERROR] gcloud CLI not found. Provide URL as argument instead.")
        sys.exit(1)
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] gcloud failed: {e.stderr.strip()}")
        sys.exit(1)


def update_bigquery(url):
    """Insert magi-moomoo Cloud Run URL into BigQuery service_endpoints."""
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
    if len(sys.argv) >= 2 and sys.argv[1].startswith("http"):
        url = sys.argv[1].rstrip("/")
        print(f"[service] Using URL: {url}")
    else:
        url = get_cloud_run_url()
        print(f"[service] Auto-detected URL: {url}")

    update_bigquery(url)
    print(f"[BigQuery] Registered {SERVICE_NAME} = {url}")


if __name__ == "__main__":
    main()
