#!/usr/bin/env python3
"""eiermann-bd8 — a fake OIDC provider, so the rule suite can complete a REAL
OAuth2 sign-in.

PocketBase's code exchange needs two endpoints: a token endpoint it POSTs the
authorization code to, and a userinfo endpoint it GETs with the access token it
got back. Nothing else of OIDC is reached by `auth-with-oauth2` — the browser
half (the authorize redirect, the login form) produces the code, and a test can
simply invent one.

So the code IS the identity. The token endpoint hands the posted `code` back as
the access token, and the userinfo endpoint base64url-decodes the bearer token
into the claims JSON. A test signs in as whoever it likes by encoding that
person's claims into the code; see `fake_oidc_code` below.

This is a test double with no secrets and no checks, which is the point: what is
under test is what the SERVER does with the claims (and with the client's
`createData`), not whether a provider authenticates anybody.

Usage:  fake_oidc.py <port>      (run.sh starts and stops it)
"""
import base64
import json
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs


def fake_oidc_code(claims):
    """The authorization code that makes this provider answer with [claims]."""
    return base64.urlsafe_b64encode(json.dumps(claims).encode()).decode()


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        # Silent: the suite's own output is the record, and a request log
        # interleaved with it would only make a failure harder to read.
        pass

    def _send(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        # The token endpoint. PocketBase posts a form; only `code` matters.
        length = int(self.headers.get("Content-Length", 0))
        form = parse_qs(self.rfile.read(length).decode())
        code = form.get("code", [""])[0]
        self._send(
            200,
            {"access_token": code, "token_type": "Bearer", "expires_in": 3600},
        )

    def do_GET(self):
        # The userinfo endpoint — and, without a token, a readiness probe for
        # run.sh, which must not start the suite before this is listening.
        token = self.headers.get("Authorization", "").split(" ", 1)[-1]
        if not token:
            self._send(200, {"ok": True})
            return
        try:
            claims = json.loads(base64.urlsafe_b64decode(token.encode()))
        except Exception:
            self._send(401, {"error": "invalid_token"})
            return
        self._send(200, claims)


class _Server(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind resolves its own fully qualified name with a
        # reverse DNS lookup BEFORE it starts listening. In a sandbox without a
        # resolver that lookup hangs, and run.sh's readiness probe gives up on
        # a server that never got as far as listen(). The name is only used in
        # CGI environments; this one does not need it.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "fake-oidc"
        self.server_port = self.server_address[1]


if __name__ == "__main__":
    # 0.0.0.0, not loopback: the server calling in sits in a container, and
    # reaches the host through the container gateway, not through 127.0.0.1.
    _Server(("0.0.0.0", int(sys.argv[1])), _Handler).serve_forever()
