import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time
import unittest

from .helpers import HOST_DIR, SCRIPT, TempHost, good_recipe

FAKE = HOST_DIR / "tests" / "fake_llama_server.py"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    st = pathlib.Path(f"/proc/{pid}/stat").read_text().split(") ")[-1].split()[0]
    return st != "Z"


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.port = free_port()
        self.h = TempHost(server_bin=str(FAKE), port=self.port)
        self.h.model()
        self.h.recipe("r", good_recipe(ctx=65536))
        self.h.recipe("r2", good_recipe())
        self.extra = []

    def tearDown(self):
        self.cli("stop")
        for p in self.extra:
            if p.poll() is None:
                p.kill()
                p.wait()
        self.h.cleanup()

    def cli(self, *args, env=None, timeout=60):
        e = dict(self.h.env, **(env or {}))
        r = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args, "--json"]
            if args[0] != "log" else [sys.executable, "-I", str(SCRIPT), *args],
            env=e, capture_output=True, text=True, timeout=timeout,
        )
        out = r.stdout
        if args[0] != "log":
            try:
                out = json.loads(r.stdout)
            except json.JSONDecodeError:
                self.fail(f"not JSON: {r.stdout!r} {r.stderr!r}")
        return r.returncode, out

    def foreign(self):
        p = subprocess.Popen([sys.executable, str(FAKE), "--port", str(self.port), "-c", "4096"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.extra.append(p)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), 0.2).close()
                return p
            except OSError:
                time.sleep(0.05)
        self.fail("foreign fake never listened")

    def test_status_stopped_when_nothing_runs(self):
        code, s = self.cli("status")
        self.assertEqual(code, 0)
        self.assertEqual(s["schema"], 1)
        self.assertEqual(s["state"], "stopped")
        self.assertIsNone(s["pid"])
        self.assertEqual(s["port"], self.port)

    def test_start_reaches_ready_and_status_agrees(self):
        code, s = self.cli("start", "r")
        self.assertEqual(code, 0, s)
        self.assertEqual(s["state"], "ready")
        self.assertEqual((s["recipe"], s["alias"], s["port"]), ("r", "r", self.port))
        self.assertEqual(s["max_output"], 4096)
        self.assertIsNotNone(s["started"])
        _, st = self.cli("status")
        self.assertEqual((st["state"], st["recipe"], st["pid"]), ("ready", "r", s["pid"]))
        self.assertEqual(st["label"], "Test model · 32K")

    def test_status_ctx_comes_from_props_not_the_recipe(self):
        code, s = self.cli("start", "r", env={"FAKE_NCTX": "32768"})
        self.assertEqual(code, 0, s)
        self.assertEqual(s["ctx"], 32768)

    def test_status_loading_before_health(self):
        code, s = self.cli("start", "r", "--wait", "0", env={"FAKE_BOOT_SECONDS": "3"})
        self.assertEqual(code, 0)
        self.assertEqual(s["state"], "loading")
        _, st = self.cli("status")
        self.assertEqual(st["state"], "loading")

    def test_start_returns_the_log_tail_when_the_server_exits_early(self):
        code, s = self.cli("start", "r", env={"FAKE_EXIT_AFTER": "0.5"})
        self.assertEqual(code, 3)
        self.assertEqual(s["state"], "error")
        self.assertIn("out of memory", s["error"])
        _, st = self.cli("status")
        self.assertEqual(st["state"], "error")

    def test_start_times_out_with_state_error(self):
        code, s = self.cli("start", "r", "--wait", "1", env={"FAKE_BOOT_SECONDS": "60"})
        self.assertEqual(code, 3)
        self.assertEqual(s["state"], "error")
        self.assertIn("did not become ready", s["error"])
        _, st = self.cli("status")
        self.assertNotIn(st["state"], ("loading", "ready"))

    def test_start_twice_needs_replace(self):
        _, s1 = self.cli("start", "r")
        code, s = self.cli("start", "r2")
        self.assertEqual(code, 4)
        self.assertEqual(s["recipe"], "r")
        code, s = self.cli("start", "r2", "--replace")
        self.assertEqual(code, 0, s)
        self.assertEqual(s["recipe"], "r2")
        self.assertNotEqual(s["pid"], s1["pid"])
        self.assertFalse(alive(s1["pid"]))

    def _bg_start(self, recipe, *extra, env=None):
        e = dict(self.h.env, **(env or {}))
        p = subprocess.Popen(
            [sys.executable, "-I", str(SCRIPT), "start", recipe, *extra, "--json"],
            env=e, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.extra.append(p)
        return p

    def test_switch_while_loading_keeps_the_new_server_ours(self):
        first = self._bg_start("r", "--wait", "60", env={"FAKE_BOOT_SECONDS": "30"})
        time.sleep(1.5)
        code, s = self.cli("start", "r2", "--replace")
        self.assertEqual(code, 0, s)
        self.assertEqual((s["state"], s["recipe"]), ("ready", "r2"))
        out, _ = first.communicate(timeout=60)
        self.assertEqual(first.returncode, 0, out)
        self.assertEqual(json.loads(out)["recipe"], "r2")
        time.sleep(0.5)
        _, st = self.cli("status")
        self.assertEqual((st["state"], st["recipe"]), ("ready", "r2"))
        self.assertIsNone(st["error"])

    def test_two_starts_at_once_do_not_steal_each_other(self):
        first = self._bg_start("r", "--wait", "60", env={"FAKE_BOOT_SECONDS": "3"})
        time.sleep(0.8)
        code, s = self.cli("start", "r2")
        self.assertEqual(code, 4, s)
        out, _ = first.communicate(timeout=60)
        self.assertEqual(first.returncode, 0, out)
        _, st = self.cli("status")
        self.assertEqual((st["state"], st["recipe"]), ("ready", "r"))

    def test_status_reports_foreign_when_the_port_answers_without_our_pidfile(self):
        self.foreign()
        _, s = self.cli("status")
        self.assertEqual(s["state"], "foreign")
        self.assertIsNone(s["pid"])

    def test_stop_never_kills_a_foreign_server(self):
        p = self.foreign()
        code, s = self.cli("stop")
        self.assertEqual(code, 5)
        time.sleep(0.2)
        self.assertIsNone(p.poll())

    def test_start_refuses_when_foreign(self):
        self.foreign()
        code, s = self.cli("start", "r")
        self.assertEqual(code, 5)

    def test_stop_is_idempotent(self):
        _, s = self.cli("start", "r")
        self.assertEqual(self.cli("stop")[0], 0)
        self.assertFalse(alive(s["pid"]))
        code, st = self.cli("stop")
        self.assertEqual((code, st["state"]), (0, "stopped"))
        self.assertFalse((self.h.home / ".local/state/llm-host/server.pid").exists())

    def test_server_survives_the_caller(self):
        # The cli() helper already runs llm-host as a child that exits.
        _, s = self.cli("start", "r")
        time.sleep(0.5)
        _, st = self.cli("status")
        self.assertEqual(st["state"], "ready")
        self.assertTrue(alive(s["pid"]))

    def test_unknown_recipe_and_missing_model(self):
        self.assertEqual(self.cli("start", "nope")[0], 6)
        self.h.recipe("nomodel", good_recipe(model="x/missing.gguf"))
        code, s = self.cli("start", "nomodel")
        self.assertEqual(code, 6)
        self.assertIn("missing", s["error"])

    def test_log_tail(self):
        self.cli("start", "r")
        code, out = self.cli("log", "-n", "1")
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), f"fake llama-server alias=r port={self.port}")

    def test_gpu_null_without_nvidia_smi(self):
        _, s = self.cli("status", env={"PATH": "/nonexistent"})
        self.assertIsNone(s["gpu"])

    def test_pidfile_of_another_program_is_not_ours(self):
        state = self.h.home / ".local/state/llm-host"
        state.mkdir(parents=True)
        (state / "server.pid").write_text(str(os.getpid()))
        _, s = self.cli("status")
        self.assertEqual(s["state"], "stopped")
        self.assertEqual(self.cli("stop")[0], 0)  # and we are still alive


if __name__ == "__main__":
    unittest.main()
