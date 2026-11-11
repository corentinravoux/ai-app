import json
import subprocess
import sys
import unittest

from .helpers import SCRIPT, TempHost, good_recipe
from .test_lifecycle import FAKE, free_port, kill_leftovers


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.port = free_port()
        self.h = TempHost(server_bin=str(FAKE), port=self.port)
        self.h.model()
        self.h.recipe("r", good_recipe())

    def tearDown(self):
        self.cli("stop")
        kill_leftovers(str(self.h.root))
        self.h.cleanup()

    def cli(self, *args, env=None):
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), *args, "--json"],
                           env=dict(self.h.env, **(env or {})),
                           capture_output=True, text=True, timeout=120)
        return r.returncode, json.loads(r.stdout)

    def checks(self, out):
        return {c["name"]: c for c in out["checks"]}

    def test_probe_passes_on_a_well_behaved_server(self):
        self.cli("start", "r")
        code, out = self.cli("probe")
        self.assertEqual(code, 0, out)
        self.assertEqual(out["schema"], 1)
        self.assertTrue(out["ok"])
        c = self.checks(out)
        self.assertEqual(set(c), {"tool_call", "anthropic", "generation"})
        self.assertIn("get_weather", c["tool_call"]["detail"])
        self.assertIn("42.5 tok/s", c["generation"]["detail"])

    def test_probe_fails_when_the_tool_call_leaks_as_text(self):
        self.cli("start", "r", env={"FAKE_TOOL_AS_TEXT": "1"})
        code, out = self.cli("probe")
        self.assertEqual(code, 3)
        self.assertFalse(out["ok"])
        c = self.checks(out)
        self.assertFalse(c["tool_call"]["ok"])
        self.assertIn("text", c["tool_call"]["detail"])
        self.assertTrue(c["anthropic"]["ok"])

    def test_probe_on_a_stopped_server_exits_1(self):
        code, out = self.cli("probe")
        self.assertEqual(code, 1)
        self.assertFalse(out["ok"])
        self.assertEqual(out["checks"], [])
        self.assertIn("No model is running", out["error"])


if __name__ == "__main__":
    unittest.main()
