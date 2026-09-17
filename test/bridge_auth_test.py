#!/usr/bin/env python3
"""Unit test for the optional bearer-token guard in bridge/moomoo_bridge.py.

Covers:
  - /health stays public whether or not a token is configured
  - protected endpoints return 401 + WWW-Authenticate without/with a bad token
  - a correct token reaches the handler
  - legacy unauthenticated behavior when BRIDGE_AUTH_TOKEN is unset
  - REAL /place_order fails closed when BRIDGE_AUTH_TOKEN is unset, while
    read-only endpoints keep the legacy unauthenticated behavior

Run:  python3 test/bridge_auth_test.py
Requires the bridge dependencies (flask, moomoo SDK) — i.e. run on TIALA.
"""

import os
import sys

os.environ["BRIDGE_AUTH_TOKEN"] = "test-secret-token"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "bridge"))

import moomoo_bridge as bridge  # noqa: E402

app = bridge.app
app.testing = True


@app.route("/_auth_probe", methods=["GET"])
def _auth_probe():
    return {"ok": True}


client = app.test_client()
failures = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name} {detail}")
    if not cond:
        failures.append(name)


# 1. /health is public even with a token configured.
r = client.get("/health")
check("health public (token set)", r.status_code == 200, f"status={r.status_code}")
check("health reports auth_required", r.get_json().get("auth_required") is True)

# 2. Protected endpoint without token -> 401 + challenge.
r = client.get("/_auth_probe")
check("missing token -> 401", r.status_code == 401, f"status={r.status_code}")
check("401 body", r.get_json() == {"success": False, "error": "unauthorized"})
check(
    "401 challenge",
    r.headers.get("WWW-Authenticate") == 'Bearer realm="moomoo-bridge"',
    r.headers.get("WWW-Authenticate"),
)

# 3. Wrong token -> 401.
r = client.get("/_auth_probe", headers={"Authorization": "Bearer wrong-token"})
check("wrong token -> 401", r.status_code == 401, f"status={r.status_code}")

# 4. Correct token reaches the handler.
r = client.get(
    "/_auth_probe", headers={"Authorization": "Bearer test-secret-token"}
)
check("correct token -> handler", r.status_code == 200 and r.get_json() == {"ok": True},
      f"status={r.status_code} body={r.get_json()}")

# 5. Non-bearer scheme -> 401.
r = client.get("/_auth_probe", headers={"Authorization": "Basic dGVzdDp0ZXN0"})
check("non-bearer scheme -> 401", r.status_code == 401)

# 6. Legacy mode: token unset -> no auth required.
bridge.BRIDGE_AUTH_TOKEN = ""
r = client.get("/_auth_probe")
check("legacy mode (token unset)", r.status_code == 200, f"status={r.status_code}")
r = client.get("/health")
check("health legacy auth_required=false", r.get_json().get("auth_required") is False)

# 7. Fail closed: REAL + token unset -> /place_order refused without a token.
bridge.IS_REAL = True
r = client.post("/place_order", json={"symbol": "AAPL", "side": "BUY", "qty": 1})
check(
    "REAL + no token -> place_order 403",
    r.status_code == 403 and "authentication" in r.get_json().get("error", ""),
    f"status={r.status_code} body={r.get_json()}",
)
r = client.post(
    "/place_order",
    json={"symbol": "AAPL", "side": "BUY", "qty": 1},
    headers={"Authorization": "Bearer any-token"},
)
check(
    "REAL + no token configured -> even a bearer guess is 403",
    r.status_code == 403,
    f"status={r.status_code}",
)
# Read-only paths keep legacy unauthenticated behavior in REAL mode.
r = client.get("/_auth_probe")
check("REAL + no token -> read-only probe still open", r.status_code == 200)
bridge.IS_REAL = False

# 8. REAL + token configured -> missing/wrong bearer is 401 before the handler.
bridge.BRIDGE_AUTH_TOKEN = "test-secret-token"
bridge.IS_REAL = True
r = client.post("/place_order", json={"symbol": "AAPL", "side": "BUY", "qty": 1})
check("REAL + token set, no auth -> 401", r.status_code == 401, f"status={r.status_code}")
r = client.post(
    "/place_order",
    json={"symbol": "AAPL", "side": "BUY", "qty": 1},
    headers={"Authorization": "Bearer wrong"},
)
check("REAL + wrong token -> 401", r.status_code == 401)
bridge.IS_REAL = False

if failures:
    print(f"\n{len(failures)} FAILED: {failures}")
    sys.exit(1)
print("\nAll bridge auth checks passed")
