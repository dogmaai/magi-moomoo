#!/usr/bin/env python3
"""ollama-auth-proxy.py — Bearer-token gate in front of the local Ollama API.

Exposes Ollama to the Cloudflare Named Tunnel (ollama.khaos.company) without
exposing the unauthenticated Ollama REST API itself. Ollama has no native
authentication, so this proxy is the enforcement point: every request except
`GET /` (liveness) requires `Authorization: Bearer <OLLAMA_AUTH_TOKEN>`.

Run behind cloudflared by pointing the tunnel ingress at this port instead of
the Ollama port:

    ingress:
      - hostname: ollama.khaos.company
        service: http://127.0.0.1:${OLLAMA_PROXY_PORT}

Environment:
    OLLAMA_AUTH_TOKEN    Bearer token required on all paths except GET /
                         (required — refuses to start when unset)
    OLLAMA_PROXY_BIND    Listen address (default 127.0.0.1)
    OLLAMA_PROXY_PORT    Listen port (default 11437)
    OLLAMA_TARGET        Upstream base URL (default http://127.0.0.1:11434)

The TIALA LaunchAgent loads the token from ~/.config/magi-moomoo/ollama.env
(source of truth: GCP Secret Manager `OLLAMA_AUTH_TOKEN`). magi-core sends the
header automatically when OLLAMA_AUTH_TOKEN is set (src/llm.js).
"""

import hmac
import http.server
import itertools
import json
import os
import socketserver
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

AUTH_TOKEN = os.environ.get("OLLAMA_AUTH_TOKEN", "")
BIND = os.environ.get("OLLAMA_PROXY_BIND", "127.0.0.1")
PORT = int(os.environ.get("OLLAMA_PROXY_PORT", "11437"))
TARGET = os.environ.get("OLLAMA_TARGET", "http://127.0.0.1:11434").rstrip("/")

# Hop-by-hop headers must not be forwarded (RFC 7230 §6.1), plus headers we
# deliberately override when talking to Ollama.
DROP_REQUEST_HEADERS = {
    "host", "connection", "keep-alive", "proxy-authenticate",
    "proxy-authorization", "te", "trailer", "trailers", "transfer-encoding",
    "upgrade", "origin", "referer",
}
DROP_RESPONSE_HEADERS = {
    "connection", "keep-alive", "transfer-encoding", "upgrade",
}

UPSTREAM_TIMEOUT_SEC = 600  # local inference can take minutes
CHUNK = 64 * 1024

_req_counter = itertools.count(1)


def _log(msg):
    sys.stderr.write("[ollama-auth-proxy] %s %s\n"
                     % (datetime.now(timezone.utc).isoformat(timespec="milliseconds"), msg))


def _bearer_token(headers):
    auth = headers.get("Authorization", "")
    scheme, _, token = auth.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        return None
    return token.strip()


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _authorized(self):
        token = _bearer_token(self.headers)
        return token is not None and hmac.compare_digest(token, AUTH_TOKEN)

    def _reject(self, req_no=None):
        # Drain any request body so it cannot poison the next request on a
        # keep-alive connection (an unconsumed POST body would be parsed as
        # the start of the next request line), then close — a rejected
        # connection is done either way.
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        self.close_connection = True
        if req_no is not None:
            _log("req=%d %s %s -> 401 rejected" % (req_no, self.command, self.path))
        body = json.dumps({"error": "unauthorized"}).encode()
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.send_header("WWW-Authenticate", 'Bearer realm="ollama"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _proxy(self):
        req_no = next(_req_counter)
        t0 = time.monotonic()
        # Responses are close-delimited: upstream Transfer-Encoding is
        # stripped and streamed (SSE) bodies carry no Content-Length, so
        # closing the connection is the only correct HTTP/1.1 way to mark
        # the end of the response. Keep-alive used to leave every streamed
        # response open — cloudflared could not complete the tunnel stream,
        # and the edge killed it ~100s after the last byte, surfacing to
        # magi-core as "Premature close" on 100% of Ollama calls.
        self.close_connection = True
        # Liveness: Ollama's own "Ollama is running" banner stays public so
        # tunnel/health checks work without a token. Everything else is gated.
        if not (self.command == "GET" and self.path == "/"):
            if not self._authorized():
                self._reject(req_no)
                return

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        _log("req=%d %s %s body_bytes=%d" % (req_no, self.command, self.path, length))

        req = urllib.request.Request(
            TARGET + self.path, data=body, method=self.command,
        )
        for k, v in self.headers.items():
            if k.lower() not in DROP_REQUEST_HEADERS:
                req.add_header(k, v)
        req.add_header("Host", "127.0.0.1:11434")
        req.add_header("Origin", "http://127.0.0.1:11434")

        try:
            resp = urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT_SEC)
        except urllib.error.HTTPError as e:
            payload = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type",
                             e.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            _log("req=%d upstream_status=%d bytes=%d elapsed_s=%.3f"
                 % (req_no, e.code, len(payload), time.monotonic() - t0))
            return
        except Exception as e:
            payload = json.dumps({"error": f"upstream unreachable: {e}"}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            _log("req=%d result=upstream_error error=%s elapsed_s=%.3f"
                 % (req_no, type(e).__name__, time.monotonic() - t0))
            return

        ttfb = time.monotonic() - t0
        _log("req=%d upstream_status=%d ttfb_s=%.3f"
             % (req_no, resp.status, ttfb))
        try:
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() not in DROP_RESPONSE_HEADERS:
                    self.send_header(k, v)
            self.send_header("Connection", "close")
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            resp.close()
            _log("req=%d result=downstream_disconnect bytes=0 elapsed_s=%.3f"
                 % (req_no, time.monotonic() - t0))
            return
        # Stream the body — Ollama SSE/NDJSON responses must reach the client
        # incrementally so Cloudflare's ~100 s proxy timeout never trips and
        # magi-core's readOllamaStream sees tokens as they are produced.
        nbytes = 0
        outcome = "completed"
        try:
            while True:
                chunk = resp.read(CHUNK)
                if not chunk:
                    break
                nbytes += len(chunk)
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            outcome = "downstream_disconnect"
        finally:
            resp.close()
        _log("req=%d result=%s bytes=%d elapsed_s=%.3f"
             % (req_no, outcome, nbytes, time.monotonic() - t0))

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _proxy

    def log_message(self, fmt, *args):
        # Method+path only — never log headers (would leak the bearer token).
        _log("%s %s -> %s" % (self.command, self.path, args[0] if args else ""))


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if not AUTH_TOKEN:
    sys.stderr.write(
        "[ollama-auth-proxy] FATAL: OLLAMA_AUTH_TOKEN unset — refusing to "
        "start an unauthenticated proxy\n")
    sys.exit(1)

print(f"[ollama-auth-proxy] listening on {BIND}:{PORT} -> {TARGET} "
      "(bearer auth required)")
ThreadingHTTPServer((BIND, PORT), ProxyHandler).serve_forever()
