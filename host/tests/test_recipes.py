import json
import subprocess
import sys
import unittest

from .helpers import SCRIPT, TempHost, good_recipe, load_module

lh = load_module()


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.h = TempHost()

    def tearDown(self):
        self.h.cleanup()

    def test_load_config_defaults(self):
        with self.assertRaises(SystemExit) as cm:
            lh.load_config(str(self.h.root / "missing.toml"), self.h.env)
        self.assertIn("config.toml", str(cm.exception))
        self.h.config.write_text(
            f'server_bin = "/x/llama-server"\nmodels_dir = "{self.h.models}"\n'
        )
        cfg = lh.load_config(None, self.h.env)
        self.assertEqual(cfg.port, 9931)
        self.assertTrue(cfg.recipes_dir.endswith("llm-host/recipes"))
        self.assertTrue(cfg.state_dir.endswith(".local/state/llm-host"))

    def test_tilde_is_expanded(self):
        self.h.config.write_text('server_bin = "~/bin/llama-server"\nmodels_dir = "~/models"\n')
        cfg = lh.load_config(None, self.h.env)
        self.assertEqual(cfg.server_bin, f"{self.h.home}/bin/llama-server")
        self.assertEqual(cfg.models_dir, f"{self.h.home}/models")

    def test_xdg_dirs_are_used(self):
        env = dict(self.h.env, XDG_STATE_HOME=str(self.h.root / "st"))
        cfg = lh.load_config(None, env)
        self.assertEqual(cfg.state_dir, str(self.h.root / "st" / "llm-host"))


class RecipeTests(unittest.TestCase):
    def setUp(self):
        self.h = TempHost(server_bin="/x/llama-server")
        self.cfg = lh.load_config(None, self.h.env)

    def tearDown(self):
        self.h.cleanup()

    def _one(self, name, body):
        self.h.recipe(name, body)
        return lh.load_recipe(self.cfg, self.h.recipes / f"{name}.toml")

    def test_recipe_name_is_file_stem(self):
        self.h.model()
        r = self._one("qwen-32k", good_recipe())
        self.assertEqual(r.name, "qwen-32k")
        for bad in ("Qwen", "-x", "a b", "x;y"):
            with self.assertRaises(lh.RecipeError):
                self._one(bad, good_recipe())

    def test_recipe_rejects_forbidden_args(self):
        self.h.model()
        for flag in lh.FORBIDDEN_ARGS:
            for args in ([flag, "v"], [f"{flag}=v"]):
                with self.assertRaises(lh.RecipeError) as cm:
                    self._one("r", good_recipe(args=args))
                self.assertIn(flag, str(cm.exception))

    def test_recipe_requires_ctx_and_max_output(self):
        self.h.model()
        body = good_recipe().replace("ctx = 32768\n", "")
        with self.assertRaises(lh.RecipeError):
            self._one("r", body)
        for ctx, out in ((0, 10), (-5, 10), (1000, 0), (4096, 4096), (4096, 8192)):
            with self.assertRaises(lh.RecipeError):
                self._one("r", good_recipe(ctx=ctx, max_output=out))

    def test_model_present_false_when_file_missing(self):
        r = self._one("r", good_recipe(model="nope/missing.gguf"))
        self.assertFalse(r.model_present)
        out = self._list_json()
        self.assertEqual([x["name"] for x in out["recipes"]], ["r"])
        self.assertFalse(out["recipes"][0]["model_present"])

    def test_invalid_recipe_does_not_hide_the_others(self):
        self.h.model()
        self.h.recipe("good", good_recipe())
        self.h.recipe("bad", good_recipe(args=["--host", "0.0.0.0"]))
        recipes, invalid = lh.load_recipes(self.cfg)
        self.assertEqual([r.name for r in recipes], ["good"])
        self.assertEqual([e.name for e in invalid], ["bad"])
        out = self._list_json()
        self.assertEqual(out["schema"], 1)
        self.assertEqual([x["name"] for x in out["recipes"]], ["good"])
        self.assertEqual(out["invalid"][0]["name"], "bad")
        self.assertIn("--host", out["invalid"][0]["reason"])

    def test_build_command(self):
        m = self.h.model()
        p = self.h.model("org/m/mmproj.gguf")
        r = self._one("r", good_recipe(model=m, mmproj=p))
        self.assertTrue(r.vision)
        # Recipe args first, fixed flags last: llama.cpp keeps the last value.
        self.assertEqual(
            lh.build_command(self.cfg, r),
            ["/x/llama-server", "-ngl", "99", "-np", "1",
             "-m", f"{self.h.models}/{m}", "--mmproj", f"{self.h.models}/{p}",
             "--alias", "r", "-c", "32768", "--host", "127.0.0.1", "--port", "9931"],
        )
        r2 = self._one("r2", good_recipe(model=m))
        cmd = lh.build_command(self.cfg, r2)
        self.assertNotIn("--mmproj", cmd)
        self.assertFalse(r2.vision)

    def test_more_download_flags_are_forbidden(self):
        self.h.model()
        for flag in ("-hfr", "--hf-repo-draft", "-mu", "--model-url", "-dr", "--docker-repo"):
            self.assertIn(flag, lh.FORBIDDEN_ARGS)
            with self.assertRaises(lh.RecipeError):
                self._one("r", good_recipe(args=[flag, "x"]))

    def test_start_loop_skips_gpu_query(self):
        import os, tempfile
        d = tempfile.mkdtemp()
        smi = os.path.join(d, "nvidia-smi")
        with open(smi, "w") as f:
            f.write("#!/bin/sh\necho 'Fake GPU, 100, 200'\n")
        os.chmod(smi, 0o755)
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = d + os.pathsep + old
        try:
            self.assertEqual(lh.gpu_info()["used_mib"], 100)
            self.assertIsNone(lh.compute_status(self.cfg, gpu=False)["gpu"])
        finally:
            os.environ["PATH"] = old

    def test_server_bin_with_a_space_is_recognised_through_ps(self):
        import os, shutil, subprocess, sys, time
        from .test_lifecycle import FAKE, free_port, kill_leftovers
        d = self.h.root / "llama cpp"
        d.mkdir()
        fake = d / "llama-server"
        shutil.copy(FAKE, fake)
        fake.chmod(0o755)
        port = free_port()
        self.h.config.write_text(
            f'server_bin = "{fake}"\nmodels_dir = "{self.h.models}"\nport = {port}\n')
        self.h.model()
        self.h.recipe("r", good_recipe())
        env = dict(self.h.env, LLM_HOST_NO_PROC="1")
        try:
            r = subprocess.run([sys.executable, "-I", str(SCRIPT), "start", "r", "--wait", "20", "--json"],
                               env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        finally:
            subprocess.run([sys.executable, "-I", str(SCRIPT), "stop", "--json"],
                           env=env, capture_output=True, timeout=60)
            kill_leftovers(str(self.h.root))

    def test_ps_fallback_matches_proc(self):
        import os
        pid = os.getpid()
        with_proc = lh.process_argv(pid)
        os.environ["LLM_HOST_NO_PROC"] = "1"
        try:
            via_ps = lh.process_argv(pid)
            self.assertEqual(lh.process_state(pid)[:1] in ("R", "S"), True)
        finally:
            del os.environ["LLM_HOST_NO_PROC"]
        self.assertEqual(via_ps[:2], with_proc[:2])
        self.assertIsNone(lh.process_argv(999999999))

    def test_model_path_cannot_escape_models_dir(self):
        for bad in ("../../etc/passwd", "/etc/passwd", "a/../../x.gguf"):
            with self.assertRaises(lh.RecipeError):
                self._one("r", good_recipe(model=bad))
        with self.assertRaises(lh.RecipeError):
            self._one("r", good_recipe(mmproj="../x.gguf"))

    def test_list_json_fields(self):
        self.h.model()
        self.h.recipe("r", good_recipe())
        x = self._list_json()["recipes"][0]
        self.assertEqual(
            set(x), {"name", "label", "model", "ctx", "max_output", "vision", "notes", "model_present"}
        )
        self.assertEqual((x["ctx"], x["max_output"]), (32768, 4096))

    def _list_json(self):
        r = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "list", "--json"],
            env=self.h.env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)


if __name__ == "__main__":
    unittest.main()
