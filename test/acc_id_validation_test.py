#!/usr/bin/env python3
"""Unit test for MOOMOO_ACC_ID startup validation in bridge/moomoo_bridge.py.

Regression test for the 2026-10-14 incident: a hand-edited launchd plist set
MOOMOO_ACC_ID="string 1302593", the bare int() at module load raised
ValueError, and the bridge crash-looped for ~3.5 days before manual repair.

Covers:
  - unset MOOMOO_ACC_ID -> module imports, acc_id defaults to 0 (auto-discover)
  - numeric MOOMOO_ACC_ID -> module imports, value parsed
  - non-numeric MOOMOO_ACC_ID -> process exits non-zero with a clear stderr
    message instead of a bare ValueError traceback

Run:  python3 test/acc_id_validation_test.py
Requires the bridge dependencies (flask, moomoo SDK) — i.e. run on TIALA,
because importing the module needs them.
"""

import os
import subprocess
import sys

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..")
BRIDGE_DIR = os.path.join(REPO_ROOT, "bridge")

failures = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"[{status}] {name} {detail}")
    if not cond:
        failures.append(name)


def import_bridge(env_overrides):
    """Import moomoo_bridge in a subprocess with the given env; return the CompletedProcess."""
    env = dict(os.environ)
    env.pop("MOOMOO_ACC_ID", None)
    env.update(env_overrides)
    env["PYTHONPATH"] = BRIDGE_DIR
    return subprocess.run(
        [sys.executable, "-c", "import moomoo_bridge; print('acc_id=%s' % moomoo_bridge.MOOMOO_ACC_ID)"],
        capture_output=True,
        text=True,
        env=env,
        cwd=REPO_ROOT,
    )


# 1. Unset -> imports fine, auto-discover default.
r = import_bridge({})
check("unset MOOMOO_ACC_ID imports", r.returncode == 0, f"rc={r.returncode} stderr={r.stderr.strip()[:200]}")
check("unset defaults to 0", "acc_id=0" in r.stdout, r.stdout.strip())

# 2. Numeric -> imports fine, parsed value.
r = import_bridge({"MOOMOO_ACC_ID": "1302593"})
check("numeric MOOMOO_ACC_ID imports", r.returncode == 0, f"rc={r.returncode} stderr={r.stderr.strip()[:200]}")
check("numeric value parsed", "acc_id=1302593" in r.stdout, r.stdout.strip())

# 3. Non-numeric -> exits 78 (EX_CONFIG) with an explicit message, no
#    ValueError traceback. 78 signals the watchdog daemon to stop retrying.
r = import_bridge({"MOOMOO_ACC_ID": "string 1302593"})
check("non-numeric exits 78 (EX_CONFIG)", r.returncode == 78, f"rc={r.returncode}")
check(
    "non-numeric names the value",
    "MOOMOO_ACC_ID" in r.stderr and "string 1302593" in r.stderr,
    r.stderr.strip()[:200],
)
check(
    "no bare ValueError traceback",
    "Traceback" not in r.stderr,
    r.stderr.strip()[:200],
)

# 4. start-bridge.sh fails fast with exit 78 on a bad value — before any
#    network/secret side effects, so this is safe to run anywhere with bash.
def run_wrapper(acc_id):
    return subprocess.run(
        ["bash", "scripts/start-bridge.sh"],
        capture_output=True,
        text=True,
        env={**os.environ, "MOOMOO_ACC_ID": acc_id},
        cwd=REPO_ROOT,
    )


r = run_wrapper("string 1302593")
check("wrapper exits 78 on bad MOOMOO_ACC_ID", r.returncode == 78, f"rc={r.returncode} stderr={r.stderr.strip()[:200]}")
check(
    "wrapper names the value",
    "MOOMOO_ACC_ID" in r.stderr and "string 1302593" in r.stderr,
    r.stderr.strip()[:200],
)

# 5. Overlong all-digit values are also config errors in the shell: a plain
#    ^[0-9]+$ would let them through to Python's int() digit limit (~4300
#    digits), where the 78 exit code is lost inside the startup health check
#    and the watchdog would retry forever.
r = run_wrapper("9" * 4301)
check("wrapper exits 78 on >19-digit MOOMOO_ACC_ID", r.returncode == 78, f"rc={r.returncode}")
r = run_wrapper("9" * 20)
check("wrapper exits 78 on 20-digit MOOMOO_ACC_ID", r.returncode == 78, f"rc={r.returncode}")

print()
if failures:
    print(f"{len(failures)} check(s) failed: {failures}")
    sys.exit(1)
print("All checks passed.")
