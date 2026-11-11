import http.server
import pathlib
import subprocess
import sys
import threading
import unittest

WEBREAD = pathlib.Path(__file__).resolve().parents[1] / "webread"

LONG = "<p>" + "START " + ("word " * 6000) + " END</p>"

PAGES = {
    "/page": ("text/html; charset=utf-8",
              b"<html><head><title>Hello Page</title><style>.x{color:red}</style>"
              b"<script>var secret = 1;</script></head><body><nav>menu menu</nav>"
              b"<h1>Heading</h1><p>First paragraph.</p><p>Second   paragraph.</p>"
              b"<svg><text>svgtext</text></svg></body></html>"),
    "/long": ("text/html", ("<html><head><title>Long</title></head><body>" + LONG + "</body></html>").encode()),
    "/png": ("image/png", b"\x89PNG\r\n\x1a\n...."),
    "/latin": ("text/html; charset=iso-8859-1", "<html><body><p>café</p></body></html>".encode("latin-1")),
    "/nohead": ("text/html", b"<head><title>Example</title><meta charset=utf-8>"
                b"<script>var hidden = 1;</script><body><p>Visible text</p>"),
    "/nobody": ("text/html", b"<html><head><title>T</title><p>No body tag</p>"),
    "/meta": ("text/html", '<html><head><meta charset="iso-8859-1"></head><body><p>déjà</p></body></html>'.encode("latin-1")),
    "/json": ("application/json", b'{"a": 1}'),
}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/loop":
            self.send_response(302)
            self.send_header("Location", "/loop")
            self.end_headers()
            return
        if self.path not in PAGES:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"nope")
            return
        ctype, body = PAGES[self.path]
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class WebreadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def run_wr(self, *args):
        return subprocess.run([sys.executable, "-I", str(WEBREAD), *args],
                              capture_output=True, text=True, timeout=60)

    def test_html_becomes_text_with_title(self):
        r = self.run_wr(self.base + "/page")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(lines[0], "Hello Page")
        self.assertIn("First paragraph.", r.stdout)
        self.assertIn("Second paragraph.", r.stdout)
        self.assertIn("Heading", r.stdout)
        for gone in ("secret", "color:red", "menu menu", "svgtext"):
            self.assertNotIn(gone, r.stdout)

    def test_head_without_end_tag_keeps_the_body(self):
        r = self.run_wr(self.base + "/nohead")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines()[0], "Example")
        self.assertIn("Visible text", r.stdout)
        self.assertNotIn("hidden", r.stdout)
        r = self.run_wr(self.base + "/nobody")
        self.assertIn("No body tag", r.stdout)

    def test_long_page_is_capped(self):
        r = self.run_wr(self.base + "/long", "--max-chars", "3000")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLessEqual(len(r.stdout), 3000 + 60)
        self.assertIn("characters omitted", r.stdout)
        self.assertTrue(r.stdout.startswith("Long"))
        self.assertTrue(r.stdout.rstrip().endswith("END"))
        self.assertIn("START", r.stdout)

    def test_default_cap_is_12000(self):
        r = self.run_wr(self.base + "/long")
        self.assertLessEqual(len(r.stdout), 12000 + 60)

    def test_non_http_scheme_is_refused(self):
        r = self.run_wr("file:///etc/passwd")
        self.assertEqual(r.returncode, 2)
        self.assertNotIn("root:", r.stdout)

    def test_binary_content_is_refused(self):
        r = self.run_wr(self.base + "/png")
        self.assertEqual(r.returncode, 2)
        self.assertIn("image/png", r.stderr)

    def test_http_error_is_one_line(self):
        r = self.run_wr(self.base + "/missing")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)
        self.assertIn("404", r.stderr)

    def test_redirect_loop_stops(self):
        r = self.run_wr(self.base + "/loop")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(len(r.stderr.strip().splitlines()), 1)

    def test_charset_from_header_and_meta(self):
        r = self.run_wr(self.base + "/latin")
        self.assertIn("café", r.stdout)
        r = self.run_wr(self.base + "/meta")
        self.assertIn("déjà", r.stdout)

    def test_json_passes_through(self):
        r = self.run_wr(self.base + "/json")
        self.assertEqual(r.stdout.strip(), '{"a": 1}')

    def test_no_url_is_usage_error(self):
        r = self.run_wr()
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
