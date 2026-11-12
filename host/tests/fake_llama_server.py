#!/usr/bin/env python3
"""Stand-in for llama-server in tests.

Reads --port, -c and --alias from argv like llama-server. Environment:
FAKE_BOOT_SECONDS  answer 503 on /health until this many seconds passed
FAKE_EXIT_AFTER    print a line, wait this many seconds, exit 1
FAKE_NCTX          n_ctx served in /props (default: the -c value)
FAKE_NO_PROPS      /props answers 500
FAKE_TOOL_AS_TEXT  tool calls come back as text markup, not tool_calls
FAKE_THINK_TOKENS  a tool call needs max_tokens >= this + 50 (thinking models)
FAKE_ARGS_AS_OBJECT  tool-call arguments come back as an object, not a string
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
            if os.environ.get("FAKE_NO_PROPS"):
                self._json(500, {"error": "no props"})
            else:
                self._json(200, {"default_generation_settings": {"n_ctx": ctx}, "total_slots": 1})
        else:
            self._json(404, {})

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/v1/chat/completions":
            think = int(os.environ.get("FAKE_THINK_TOKENS", "0"))
            if body.get("tools") and body.get("max_tokens", 10**6) < think + 50:
                msg = {"role": "assistant", "content": "", "reasoning_content": "hmm " * 20}
            elif body.get("tools"):
                args = ({"city": "Paris"} if os.environ.get("FAKE_ARGS_AS_OBJECT")
                        else '{"city": "Paris"}')
                call = {"name": "get_weather", "arguments": args}
                if os.environ.get("FAKE_TOOL_AS_TEXT"):
                    msg = {"role": "assistant",
                           "content": '<tool_call>{"name": "get_weather"}</tool_call>'}
                else:
                    msg = {"role": "assistant", "content": "",
                           "tool_calls": [{"id": "c1", "type": "function", "function": call}]}
            else:
                msg = {"role": "assistant", "content": "1 2 3 4 5"}
            self._json(200, {"choices": [{"index": 0, "message": msg}],
                             "timings": {"predicted_per_second": 42.5, "prompt_per_second": 600.0}})
        elif self.path == "/v1/messages":
            self._json(200, {"type": "message", "role": "assistant",
                             "content": [{"type": "text", "text": "ok"}]})
        else:
            self._json(404, {})


class Server(http.server.HTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls socket.getfqdn(), a reverse DNS lookup
        # that stalls for seconds on macOS runners: the fake then answers so
        # late that every test times out. The name is never used.
        import socketserver

        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


Server(("127.0.0.1", port), H).serve_forever()
