"""Shared helpers: import llm_host from host/ and build temp configs."""
import importlib.util
import os
import pathlib
import sys
import tempfile

HOST_DIR = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = HOST_DIR / "llm_host.py"


def load_module():
    spec = importlib.util.spec_from_file_location("llm_host", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["llm_host"] = mod
    spec.loader.exec_module(mod)
    return mod


class TempHost:
    """A fake home with config.toml, a recipes dir and a models dir."""

    def __init__(self, server_bin="/usr/bin/false", port=9931, extra=""):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.home = self.root / "home"
        self.models = self.root / "models"
        self.cfg_dir = self.home / ".config" / "llm-host"
        self.recipes = self.cfg_dir / "recipes"
        for d in (self.home, self.models, self.recipes):
            d.mkdir(parents=True)
        self.config = self.cfg_dir / "config.toml"
        self.config.write_text(
            f'server_bin = "{server_bin}"\nmodels_dir = "{self.models}"\n'
            f"port = {port}\n{extra}"
        )
        self.env = {"HOME": str(self.home), "PATH": os.environ.get("PATH", "")}

    def model(self, rel="org/m/model.gguf"):
        p = self.models / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"GGUF")
        return rel

    def recipe(self, name, body):
        (self.recipes / f"{name}.toml").write_text(body)

    def cleanup(self):
        self.tmp.cleanup()


def good_recipe(model="org/m/model.gguf", mmproj=None, ctx=32768, max_output=4096, args=None):
    lines = [
        'label = "Test model · 32K"',
        f'model = "{model}"',
        f"ctx = {ctx}",
        f"max_output = {max_output}",
        "args = " + _toml_list(args if args is not None else ["-ngl", "99", "-np", "1"]),
        'notes = "test"',
    ]
    if mmproj:
        lines.append(f'mmproj = "{mmproj}"')
    return "\n".join(lines) + "\n"


def _toml_list(items):
    return "[" + ", ".join('"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"' for s in items) + "]"
