#!/usr/bin/env python3
"""Loopback-only synthetic HTTP fixture for the offline test suite."""
import http.server
import pathlib
import sys
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        pages = {
            "/healthy": (200, "OWN-SITE safe content"),
            "/missing": (200, "generic content"),
            "/leak": (200, "OWN-SITE FOREIGN-TENANT content"),
            "/wrong-status": (503, "OWN-SITE unavailable"),
        }
        if self.path == "/slow":
            time.sleep(0.15)
            status, body = 200, "OWN-SITE slow content"
        else:
            status, body = pages.get(self.path, (404, "not found"))
        encoded = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _format, *_args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
