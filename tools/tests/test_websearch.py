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


class _Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        # No socket.getfqdn() (slow reverse DNS on macOS runners).
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


class Searx(http.server.BaseHTTPRequestHandler):
    """Fake SearXNG: the path prefix (/ok, /nojson, /empty, /html) selects
    the answer; the real one is /search?q=…&format=json."""

    seen = []

    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        Searx.seen.append((u.path, q))
        if u.path.startswith("/nojson"):
            return self._send(403, b"Forbidden", "text/html")
        if u.path.startswith("/html"):
            return self._send(200, b"<html>not json</html>", "text/html")
        results = [] if u.path.startswith("/empty") else [
            {"title": f"Result <b>{i}</b>", "url": f"https://example.org/{i}",
             "content": f"About {q['q'][0]} &amp; more {i}"}
            for i in range(1, 31)
        ]
        self._send(200, json.dumps({"query": q["q"][0], "results": results}).encode(),
                   "application/json")

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def settings_dir(home: pathlib.Path) -> pathlib.Path:
    """AI App's settings folder, as websearch looks for it on this OS."""
    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "ai-app"
    if sys.platform == "win32":
        return home / "AppData" / "Roaming" / "ai-app"
    return home / ".config" / "ai-app"


class WebsearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = _Server(("127.0.0.1", 0), Searx)
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.tmp.name)
        Searx.seen.clear()

    def tearDown(self):
        self.tmp.cleanup()

    def run_ws(self, *args, prefix="/ok", url=None, env=None):
        e = {"HOME": str(self.home), "PATH": os.environ.get("PATH", ""),
             "APPDATA": str(self.home / "AppData" / "Roaming")}
        if url is not False:
            e["AI_APP_SEARXNG_URL"] = url or (self.base + prefix)
        e.update(env or {})
        return subprocess.run([sys.executable, "-I", str(WEBSEARCH), *args],
                              env=e, capture_output=True, text=True, timeout=60)

    def test_results_are_numbered_with_url_and_snippet(self):
        r = self.run_ws("flutter", "pty")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1. Result 1", r.stdout)
        self.assertIn("https://example.org/1", r.stdout)
        self.assertIn("About flutter pty & more 1", r.stdout)
        self.assertNotIn("<b>", r.stdout)
        path, q = Searx.seen[-1]
        self.assertEqual(path, "/ok/search")
        self.assertEqual(q["q"], ["flutter pty"])
        self.assertEqual(q["format"], ["json"])

    def test_count_default_and_cap(self):
        r = self.run_ws("x")
        self.assertEqual(r.stdout.count("https://example.org/"), 5)
        r = self.run_ws("x", "--count", "50")
        self.assertEqual(r.stdout.count("https://example.org/"), 20)

    def test_address_from_the_settings_file(self):
        d = settings_dir(self.home)
        d.mkdir(parents=True)
        (d / "searxng-url").write_text(self.base + "/ok/\n")
        r = self.run_ws("x", url=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Searx.seen[-1][0], "/ok/search")

    def test_default_address_and_not_running(self):
        # Default http://127.0.0.1:8899: nothing listens there in tests.
        r = self.run_ws("x", url=False)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1, r.stderr)
        self.assertIn("SearXNG is not running at http://127.0.0.1:8899", r.stderr)
        self.assertIn("docs/searxng.md", r.stderr)

    def test_json_turned_off_says_how_to_fix(self):
        r = self.run_ws("x", prefix="/nojson")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)
        self.assertIn("json", r.stderr)
        self.assertIn("formats", r.stderr)

    def test_not_json_is_one_line(self):
        r = self.run_ws("x", prefix="/html")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)

    def test_no_results_says_so(self):
        r = self.run_ws("x", prefix="/empty")
        self.assertEqual(r.returncode, 0)
        self.assertIn("No results", r.stdout)

    def test_a_query_starting_with_a_dash_is_a_query(self):
        r = self.run_ws("-site:example.org", "flutter")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Searx.seen[-1][1]["q"], ["-site:example.org flutter"])

    def test_bad_option_value_is_one_line(self):
        r = self.run_ws("x", "--count", "many")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)

    def test_only_http_addresses(self):
        r = self.run_ws("x", url="file:///etc/passwd")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(Searx.seen, [])

    def test_empty_query_is_refused(self):
        r = self.run_ws()
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
