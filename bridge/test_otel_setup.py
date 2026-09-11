"""Unit tests for the Grafana Cloud OTLP/Pyroscope wiring in the bridge.

No real credentials are used anywhere in this file. Fake tokens are chosen so
their base64 encodings exercise the characters that historically broke the
pipeline ('+', '/', '=', and the literal 'n'/'r' bytes that a buggy
``tr -d '\\\\n\\\\r'`` invocation deleted).

Run on TIALA with the project venv so the OpenTelemetry-dependent tests execute:
    venv_bridge/bin/python -m unittest bridge/test_otel_setup.py -v
On hosts without the OTel SDK/flask, those tests are skipped.
"""

import base64
import os
import re
import subprocess
import sys
import types
import unittest
from pathlib import Path
from urllib.parse import unquote

REPO_ROOT = Path(__file__).resolve().parent.parent
START_SCRIPT = REPO_ROOT / "scripts" / "start-bridge.sh"
BRIDGE_SRC = REPO_ROOT / "bridge" / "moomoo_bridge.py"

FAKE_INSTANCE = "1557976"
# Chosen so base64("1557976:glc_fake...") contains '+', '/', '=' and the
# letters 'n'/'r' that the broken tr pipeline stripped.
FAKE_TOKEN = "glc_eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.fake+sig/nr=part"


def _script_header_for(instance: str, token: str) -> str:
    """Run the exact header pipeline used by start-bridge.sh."""
    script = (
        'OTLP_AUTH="$(printf \'%s:%s\' "$1" "$2" | base64 | tr -d \'\\n\\r\')"\n'
        'printf \'%s\' "Authorization=Basic%20${OTLP_AUTH}"\n'
    )
    out = subprocess.run(
        ["bash", "-c", script, "_", instance, token],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout


class HeaderConstructionTests(unittest.TestCase):
    """The header string the script exports must survive the SDK parser."""

    def test_pipeline_produces_url_encoded_basic(self):
        header = _script_header_for(FAKE_INSTANCE, FAKE_TOKEN)
        self.assertTrue(header.startswith("Authorization=Basic%20"))
        b64 = header.split("%20", 1)[1]
        # Raw base64 chars in the value are legal per the W3C baggage
        # subset the SDK accepts, but the value must contain no space.
        self.assertNotIn(" ", header)
        decoded = base64.b64decode(b64).decode()
        self.assertEqual(f"{FAKE_INSTANCE}:{FAKE_TOKEN}", decoded)

    def test_base64_special_chars_survive(self):
        # '+', '/', '=' and 'n'/'r' bytes must round-trip intact.
        header = _script_header_for(FAKE_INSTANCE, FAKE_TOKEN)
        b64 = unquote(header.split("=", 1)[1].split("%20", 1)[1])
        self.assertEqual(
            base64.b64encode(f"{FAKE_INSTANCE}:{FAKE_TOKEN}".encode()).decode(),
            b64,
        )

    def test_header_value_decodes_to_basic(self):
        header = _script_header_for(FAKE_INSTANCE, FAKE_TOKEN)
        name, _, value = header.partition("=")
        self.assertEqual("Authorization", name)
        self.assertTrue(unquote(value).startswith("Basic "))


class ScriptHygieneTests(unittest.TestCase):
    """Static checks that credentials can never reach logs/history."""

    @classmethod
    def setUpClass(cls):
        cls.script = START_SCRIPT.read_text()

    def test_no_xtrace(self):
        for bad in ("set -x", "set -ex", "set -xe", "bash -x"):
            self.assertNotIn(bad, self.script)

    def test_secrets_never_echoed(self):
        for line in self.script.splitlines():
            stripped = line.strip()
            if not stripped.startswith(("echo", "printf")):
                continue
            for var in (
                "GRAFANA_OTLP_TOKEN",
                "SIGIL_AUTH_TOKEN",
                "OTLP_AUTH",
                "OTEL_EXPORTER_OTLP_HEADERS",
                "PYROSCOPE_BASIC_AUTH_PASSWORD",
            ):
                self.assertNotIn(f"${{{var}", stripped, stripped)
                self.assertNotIn(f"${var}", stripped, stripped)

    def test_header_uses_encoded_space(self):
        self.assertIn("Authorization=Basic%20", self.script)

    def test_resource_attributes(self):
        self.assertIn("service.namespace=magi", self.script)
        self.assertIn("deployment.environment=production", self.script)

    def test_python_bin_prefers_venv(self):
        self.assertIn('PYTHON_BIN="${VIRTUAL_ENV}/bin/python"', self.script)
        self.assertIn('PYTHON_BIN="python3"', self.script)

    def test_pyroscope_defaults_present(self):
        self.assertIn("profiles-prod-019.grafana.net", self.script)
        self.assertIn("PYROSCOPE_BASIC_AUTH_PASSWORD", self.script)


class PlistTests(unittest.TestCase):
    def test_plist_parses(self):
        import plistlib

        plist = REPO_ROOT / "scripts" / "com.magi.bridge.plist"
        data = plistlib.loads(plist.read_bytes())
        self.assertEqual("com.magi.bridge", data["Label"])
        self.assertTrue(data["RunAtLoad"])


try:
    from opentelemetry.util.re import parse_env_headers

    _HAS_OTEL = True
except ImportError:
    _HAS_OTEL = False


@unittest.skipUnless(_HAS_OTEL, "opentelemetry-sdk not installed")
class SDKParseTests(unittest.TestCase):
    """Exercise the real SDK parser (venvs on TIALA ship otel 1.27)."""

    def test_encoded_header_parses(self):
        header = _script_header_for(FAKE_INSTANCE, FAKE_TOKEN)
        parsed = parse_env_headers(header)
        expected_b64 = base64.b64encode(
            f"{FAKE_INSTANCE}:{FAKE_TOKEN}".encode()
        ).decode()
        self.assertEqual(f"Basic {expected_b64}", parsed["authorization"])

    def test_unencoded_space_is_dropped(self):
        # Documents the original failure mode: a raw space violates the
        # baggage-octet value format, so the SDK discards the whole header
        # and the gateway answers "no credentials provided".
        parsed = parse_env_headers("Authorization=Basic dGVzdA==")
        self.assertNotIn("authorization", parsed)

    def test_exporter_receives_authorization(self):
        os.environ["OTEL_EXPORTER_OTLP_HEADERS"] = _script_header_for(
            FAKE_INSTANCE, FAKE_TOKEN
        )
        try:
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
                OTLPSpanExporter,
            )
            from opentelemetry.exporter.otlp.proto.http._log_exporter import (
                OTLPLogExporter,
            )

            for exporter in (OTLPSpanExporter(), OTLPLogExporter()):
                headers = dict(exporter._headers or {})
                self.assertIn("authorization", headers)
                self.assertTrue(headers["authorization"].startswith("Basic "))
        finally:
            del os.environ["OTEL_EXPORTER_OTLP_HEADERS"]


def _install_moomoo_stub():
    """Register a fake `moomoo` module so the bridge imports without OpenD."""
    from unittest.mock import MagicMock

    names = [
        "OpenSecTradeContext",
        "OpenQuoteContext",
        "TrdEnv",
        "TrdSide",
        "TrdMarket",
        "OrderType",
        "SecurityFirm",
        "SubType",
        "KLType",
    ]
    mod = types.ModuleType("moomoo")
    for name in names:
        setattr(mod, name, MagicMock(name=name))
    mod.RET_OK = 0
    sys.modules["moomoo"] = mod


def _bridge_importable():
    try:
        import flask  # noqa: F401
        import opentelemetry.sdk._logs  # noqa: F401
        import opentelemetry.instrumentation.flask  # noqa: F401
        import opentelemetry.exporter.otlp.proto.http  # noqa: F401
        return True
    except ImportError:
        return False


@unittest.skipUnless(_bridge_importable(), "bridge deps not installed")
class BridgeModuleTests(unittest.TestCase):
    """Import the real bridge with a stubbed moomoo SDK (no OpenD needed)."""

    @classmethod
    def setUpClass(cls):
        _install_moomoo_stub()
        for var in (
            "PYROSCOPE_SERVER_ADDRESS",
            "PYROSCOPE_BASIC_AUTH_USER",
            "PYROSCOPE_BASIC_AUTH_PASSWORD",
        ):
            os.environ.pop(var, None)
        sys.path.insert(0, str(REPO_ROOT / "bridge"))
        import moomoo_bridge

        cls.bridge = moomoo_bridge

    def test_pyzroscope_disabled_does_not_crash(self):
        # No PYROSCOPE_* env — module must still import and serve.
        self.assertIsNotNone(self.bridge.app)

    def test_dual_timezone_formatter(self):
        import logging
        from unittest import mock

        from opentelemetry.sdk._logs import LoggingHandler

        record = logging.LogRecord(
            "moomoo-bridge", logging.INFO, __file__, 1, "hello", (), None
        )
        handler = self.bridge._DualTimezoneLoggingHandler(level=logging.NOTSET)
        # Spy on the SDK base emit() to capture the rewritten OTLP record.
        with mock.patch.object(LoggingHandler, "emit", autospec=True) as m:
            handler.emit(record)
        otel_record = m.call_args[0][1]
        self.assertIn("(JST)", otel_record.msg)
        self.assertIn("(ET)", otel_record.msg)
        self.assertIn("hello", otel_record.msg)

    def test_health_endpoint(self):
        client = self.bridge.app.test_client()
        resp = client.get("/health")
        self.assertEqual(200, resp.status_code)
        body = resp.get_json()
        self.assertEqual("ok", body["status"])
        self.assertEqual("moomoo-bridge", body["service"])


if __name__ == "__main__":
    unittest.main()
