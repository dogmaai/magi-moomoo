#!/usr/bin/env python3
"""Unit tests for scripts/ollama-auth-proxy.py.

Verifies:
- Unauthenticated GET / and GET /health pass through (Ollama & llama-server liveness).
- Unauthenticated POST /v1/chat/completions and GET /v1/models return 401.
- Authenticated requests forward dynamic Host/Origin derived from OLLAMA_TARGET
  and stream SSE responses cleanly.
"""

import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROXY_SCRIPT = os.path.join(REPO_ROOT, "scripts", "ollama-auth-proxy.py")


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _FakeUpstreamHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        if self.path == "/":
            body = b"Ollama is running"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/health":
            body = json.dumps({"status": "ok"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/v1/models":
            body = json.dumps({
                "host_seen": self.headers.get("Host"),
                "origin_seen": self.headers.get("Origin"),
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        _ = self.rfile.read(length) if length else b""
        if self.path == "/v1/chat/completions":
            payload = (
                b'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'
                b"data: [DONE]\n\n"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


class OllamaAuthProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream_port = _free_port()
        cls.proxy_port = _free_port()
        cls.token = "test-bearer-token-123"
        cls.tmpdir = tempfile.TemporaryDirectory()
        cls.log_file = os.path.join(cls.tmpdir.name, "proxy.log")

        cls.upstream = http.server.ThreadingHTTPServer(
            ("127.0.0.1", cls.upstream_port), _FakeUpstreamHandler
        )
        cls.upstream_thread = threading.Thread(
            target=cls.upstream.serve_forever, daemon=True
        )
        cls.upstream_thread.start()

        env = os.environ.copy()
        env.update({
            "OLLAMA_AUTH_TOKEN": cls.token,
            "OLLAMA_PROXY_BIND": "127.0.0.1",
            "OLLAMA_PROXY_PORT": str(cls.proxy_port),
            "OLLAMA_TARGET": f"http://127.0.0.1:{cls.upstream_port}",
            "OLLAMA_PROXY_LOG_FILE": cls.log_file,
        })
        cls.proc = subprocess.Popen(
            [sys.executable, PROXY_SCRIPT],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # Wait for proxy to listen.
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{cls.proxy_port}/health", timeout=1
                ) as resp:
                    if resp.status == 200:
                        return
            except Exception:
                time.sleep(0.05)
        raise RuntimeError("ollama-auth-proxy did not start in time")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        try:
            cls.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
        cls.upstream.shutdown()
        cls.upstream.server_close()
        cls.tmpdir.cleanup()

    def test_unauthenticated_root_liveness_allowed(self):
        with urllib.request.urlopen(
            f"http://127.0.0.1:{self.proxy_port}/", timeout=2
        ) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(resp.read(), b"Ollama is running")

    def test_unauthenticated_health_liveness_allowed(self):
        with urllib.request.urlopen(
            f"http://127.0.0.1:{self.proxy_port}/health", timeout=2
        ) as resp:
            self.assertEqual(resp.status, 200)
            self.assertEqual(json.loads(resp.read()), {"status": "ok"})

    def test_unauthenticated_api_endpoints_rejected(self):
        for method, path in [("GET", "/v1/models"), ("POST", "/v1/chat/completions")]:
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.proxy_port}{path}",
                data=(b"{}" if method == "POST" else None),
                method=method,
            )
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                urllib.request.urlopen(req, timeout=2)
            self.assertEqual(ctx.exception.code, 401)

    def test_authenticated_request_forwards_dynamic_host_and_origin(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.proxy_port}/v1/models",
            headers={"Authorization": f"Bearer {self.token}"},
        )
        with urllib.request.urlopen(req, timeout=2) as resp:
            self.assertEqual(resp.status, 200)
            data = json.loads(resp.read())
            self.assertEqual(data["host_seen"], f"127.0.0.1:{self.upstream_port}")
            self.assertEqual(
                data["origin_seen"], f"http://127.0.0.1:{self.upstream_port}"
            )

    def test_authenticated_sse_stream_passthrough(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.proxy_port}/v1/chat/completions",
            data=b'{"model":"bonsai","stream":true}',
            method="POST",
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=2) as resp:
            self.assertEqual(resp.status, 200)
            self.assertIn("text/event-stream", resp.headers.get("Content-Type", ""))
            body = resp.read().decode("utf-8")
            self.assertIn('"content":"hi"', body)
            self.assertIn("data: [DONE]", body)


if __name__ == "__main__":
    unittest.main()
