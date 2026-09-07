"""Minimal webhook sink used by the tests.

Accepts a POST, rejects anything that is not a JSON object carrying an
``attachments`` array, and appends each accepted body to the file named by the
first argument so a test can assert on what the action actually sent.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            payload = json.loads(body)
            assert isinstance(payload, dict), "payload is not a JSON object"
            assert isinstance(payload["attachments"], list), "attachments is not a list"
        except Exception as exc:  # noqa: BLE001 - the test wants the reason
            self.send_response(400)
            self.end_headers()
            self.wfile.write(str(exc).encode())
            return
        with open(sys.argv[2], "a", encoding="utf-8") as handle:
            handle.write(body.decode() + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
