#!/usr/bin/env python3
"""Stand-in for llama-server in tests.

Reads --port, -c and --alias from argv like llama-server. Environment:
FAKE_BOOT_SECONDS  answer 503 on /health until this many seconds passed
FAKE_EXIT_AFTER    print a line, wait this many seconds, exit 1
FAKE_NCTX          n_ctx served in /props (default: the -c value)
"""
import http.server
import json
import os
import sys
import time


def arg(flag, default=None):
    a = sys.argv
    return a[a.index(flag) + 1] if flag in a else default


port = int(arg("--port", "9931"))
ctx = int(os.environ.get("FAKE_NCTX") or arg("-c", "4096"))
alias = arg("--alias", "fake")
boot = float(os.environ.get("FAKE_BOOT_SECONDS", "0"))
t0 = time.time()

print(f"fake llama-server alias={alias} port={port}", flush=True)
if "FAKE_EXIT_AFTER" in os.environ:
    print("fake: model loading failed: out of memory", flush=True)
    time.sleep(float(os.environ["FAKE_EXIT_AFTER"]))
    sys.exit(1)


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        ready = time.time() - t0 >= boot
        if self.path == "/health":
            self._json(200 if ready else 503, {"status": "ok" if ready else "loading"})
        elif self.path == "/props":
            self._json(200, {"default_generation_settings": {"n_ctx": ctx}, "total_slots": 1})
        else:
            self._json(404, {})


http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
