import http.server
import json
import os
import pathlib
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

WEBSEARCH = pathlib.Path(__file__).resolve().parents[1] / "websearch"
KEY = "test-key-123"


class _Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # No socket.getfqdn() (slow reverse DNS on macOS runners).
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


class Brave(http.server.BaseHTTPRequestHandler):
    """Fake Brave Search API: /ok, /401, /429 prefixes select the answer."""

    seen = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        Brave.seen.append((u.path, q, self.headers.get("X-Subscription-Token")))
        if u.path.startswith("/401"):
            return self._send(401, {"error": {"code": "SUBSCRIPTION_TOKEN_INVALID"}})
        if u.path.startswith("/422"):
            return self._send(422, {"error": {"code": "VALIDATION"}})
        if u.path.startswith("/empty"):
            return self._send(200, {"web": {"results": []}})
        if u.path.startswith("/429"):
            return self._send(429, {"error": {"code": "RATE_LIMITED"}})
        n = int(q.get("count", ["10"])[0])
        results = [
            {"title": f"Result <strong>{i}</strong>", "url": f"https://example.org/{i}",
             "description": f"About <strong>{q['q'][0]}</strong> &amp; more {i}"}
            for i in range(1, 21)
        ][:n]
        self._send(200, {"web": {"results": results}})

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class WebsearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = _Server(("127.0.0.1", 0), Brave)
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        Brave.seen.clear()

    def tearDown(self):
        self.tmp.cleanup()

    def run_ws(self, *args, path="/ok", key=KEY, env=None):
        e = {"HOME": self.home, "PATH": os.environ.get("PATH", ""),
             "AI_APP_BRAVE_ENDPOINT": self.base + path}
        if key is not None:
            e["BRAVE_API_KEY"] = key
        e.update(env or {})
        return subprocess.run([sys.executable, "-I", str(WEBSEARCH), *args],
                              env=e, capture_output=True, text=True, timeout=60)

    def test_results_are_numbered_with_url_and_snippet(self):
        r = self.run_ws("flutter", "pty")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1. Result 1", r.stdout)
        self.assertIn("https://example.org/1", r.stdout)
        self.assertIn("About flutter pty & more 1", r.stdout)
        self.assertNotIn("<strong>", r.stdout)
        path, q, token = Brave.seen[-1]
        self.assertEqual(q["q"], ["flutter pty"])
        self.assertEqual(token, KEY)

    def test_count_default_and_cap(self):
        self.run_ws("x")
        self.assertEqual(Brave.seen[-1][1]["count"], ["5"])
        r = self.run_ws("x", "--count", "50")
        self.assertEqual(Brave.seen[-1][1]["count"], ["20"])
        self.assertEqual(r.stdout.count("https://example.org/"), 20)

    def test_key_from_the_config_file(self):
        # The settings folder websearch reads on this platform.
        home = pathlib.Path(self.home)
        if sys.platform == "darwin":
            d = home / "Library" / "Application Support" / "ai-app"
        elif sys.platform == "win32":
            d = home / "AppData" / "Roaming" / "ai-app"
        else:
            d = home / ".config" / "ai-app"
        d.mkdir(parents=True)
        (d / "brave-api-key").write_text("file-key\n")
        r = self.run_ws("x", key=None)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Brave.seen[-1][2], "file-key")

    def test_missing_key_says_where_to_put_it(self):
        r = self.run_ws("x", key=None)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)
        self.assertIn("brave-api-key", r.stderr)
        self.assertEqual(Brave.seen, [])

    def test_bad_key_and_rate_limit_are_one_line_without_the_key(self):
        for path, word in (("/401", "key"), ("/429", "limit")):
            r = self.run_ws("x", path=path)
            self.assertEqual(r.returncode, 2)
            self.assertEqual(len(r.stderr.strip().splitlines()), 1, r.stderr)
            self.assertIn(word, r.stderr.lower())
            self.assertNotIn(KEY, r.stderr + r.stdout)

    def test_no_results(self):
        r = self.run_ws("x", "--count", "0")
        self.assertEqual(Brave.seen[-1][1]["count"], ["1"])

    def test_a_query_starting_with_a_dash_is_a_query(self):
        r = self.run_ws("-site:example.org", "flutter")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Brave.seen[-1][1]["q"], ["-site:example.org flutter"])

    def test_422_does_not_blame_the_key_alone(self):
        r = self.run_ws("x", path="/422")
        self.assertEqual(r.returncode, 2)
        self.assertIn("too long", r.stderr)

    def test_no_results_says_so(self):
        r = self.run_ws("x", path="/empty")
        self.assertEqual(r.returncode, 0)
        self.assertIn("No results", r.stdout)

    def test_unreachable_api_is_one_line(self):
        r = self.run_ws("x", env={"AI_APP_BRAVE_ENDPOINT": "http://127.0.0.1:9/none"})
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)
        self.assertNotIn(KEY, r.stderr)

    def test_bad_option_value_is_one_line(self):
        r = self.run_ws("x", "--count", "many")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)

    def test_empty_query_is_refused(self):
        r = self.run_ws()
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
