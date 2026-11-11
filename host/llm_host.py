#!/usr/bin/env python3
"""llm-host: owns the llama-server of one model host.

Runs on every machine that serves a local model (the PC, later a mini PC).
AI App calls it directly on the local machine and through ssh on a remote
one; it is also usable by hand. Standard library only.

    llm-host list   [--json]          recipes in ~/.config/llm-host/recipes
    llm-host status [--json]          what runs on the port
    llm-host start <recipe> [--replace] [--wait S] [--json]
    llm-host stop   [--json]
    llm-host log    [-n LINES]

A recipe is one tested launch of one model (TOML):

    label = "Qwen3.6 35B-A3B · 64K"
    model = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"
    mmproj = "..."          # optional, relative to models_dir
    ctx = 65536             # -c
    max_output = 8192       # output cap agents are told to use
    args = ["-ngl", "99", "--n-cpu-moe", "20", ...]
    notes = "measured 2026-11-11"

llm-host adds -m, --mmproj, --alias <recipe name>, -c, --host 127.0.0.1 and
--port itself; recipes may not set them. The server never listens on
anything but 127.0.0.1.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import pathlib
import re
import sys
import tomllib
from collections.abc import Mapping

SCHEMA = 1

FORBIDDEN_ARGS = (
    "--host",
    "--port",
    "--api-key",
    "--api-key-file",
    "-m",
    "--model",
    "-c",
    "--ctx-size",
    "-a",
    "--alias",
    "-hf",
    "--hf-repo",
    "-hff",
    "--hf-file",
    "--mmproj",
)

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


class RecipeError(Exception):
    def __init__(self, name: str, reason: str):
        super().__init__(f"{name}: {reason}")
        self.name = name
        self.reason = reason


@dataclasses.dataclass
class Config:
    server_bin: str
    models_dir: str
    recipes_dir: str
    state_dir: str
    port: int = 9931


@dataclasses.dataclass
class Recipe:
    name: str
    label: str
    model: str
    mmproj: str | None
    ctx: int
    max_output: int
    args: list[str]
    notes: str
    model_present: bool

    @property
    def vision(self) -> bool:
        return self.mmproj is not None

    def summary(self) -> dict:
        return {
            "name": self.name,
            "label": self.label,
            "model": self.model,
            "ctx": self.ctx,
            "max_output": self.max_output,
            "vision": self.vision,
            "notes": self.notes,
            "model_present": self.model_present,
        }


# --------------------------------------------------------------- config


def _expand(path: str, home: str) -> str:
    if path == "~" or path.startswith("~/"):
        return home + path[1:]
    return path


def load_config(path: str | None, env: Mapping[str, str]) -> Config:
    home = env.get("HOME") or str(pathlib.Path.home())
    config_home = env.get("XDG_CONFIG_HOME") or f"{home}/.config"
    state_home = env.get("XDG_STATE_HOME") or f"{home}/.local/state"
    cfg_path = path or f"{config_home}/llm-host/config.toml"
    try:
        with open(cfg_path, "rb") as f:
            raw = tomllib.load(f)
    except FileNotFoundError:
        raise SystemExit(
            f"llm-host: no config at {cfg_path}: create config.toml "
            "(see scripts/install-host.sh)"
        )
    except tomllib.TOMLDecodeError as e:
        raise SystemExit(f"llm-host: {cfg_path} is not valid TOML: {e}")
    for key in ("server_bin", "models_dir"):
        if not isinstance(raw.get(key), str) or not raw[key]:
            raise SystemExit(f"llm-host: {cfg_path} needs a string `{key}`")
    port = raw.get("port", 9931)
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise SystemExit(f"llm-host: {cfg_path}: bad port {port!r}")
    cfg_dir = os.path.dirname(os.path.abspath(cfg_path))
    return Config(
        server_bin=_expand(raw["server_bin"], home),
        models_dir=_expand(raw["models_dir"], home).rstrip("/"),
        recipes_dir=_expand(raw.get("recipes_dir", f"{cfg_dir}/recipes"), home),
        state_dir=_expand(raw.get("state_dir", f"{state_home}/llm-host"), home),
        port=port,
    )


# -------------------------------------------------------------- recipes


def _inside(models_dir: str, rel: object, name: str, key: str) -> str:
    if not isinstance(rel, str) or not rel:
        raise RecipeError(name, f"`{key}` must be a path relative to models_dir")
    if rel.startswith("/") or rel.startswith("~"):
        raise RecipeError(name, f"`{key}` must be relative to models_dir")
    root = os.path.realpath(models_dir)
    full = os.path.realpath(os.path.join(root, rel))
    if full != root and not full.startswith(root + os.sep):
        raise RecipeError(name, f"`{key}` points outside models_dir")
    return rel


def _positive_int(v: object, name: str, key: str) -> int:
    if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
        raise RecipeError(name, f"`{key}` must be a positive integer")
    return v


def load_recipe(cfg: Config, path: os.PathLike | str) -> Recipe:
    path = pathlib.Path(path)
    name = path.stem
    if not NAME_RE.match(name):
        raise RecipeError(name, "file name must match [a-z0-9][a-z0-9._-]*")
    try:
        with open(path, "rb") as f:
            raw = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise RecipeError(name, f"not valid TOML: {e}")
    model = _inside(cfg.models_dir, raw.get("model"), name, "model")
    mmproj = raw.get("mmproj")
    if mmproj is not None:
        mmproj = _inside(cfg.models_dir, mmproj, name, "mmproj")
    ctx = _positive_int(raw.get("ctx"), name, "ctx")
    max_output = _positive_int(raw.get("max_output"), name, "max_output")
    if max_output >= ctx:
        raise RecipeError(name, "`max_output` must be smaller than `ctx`")
    args = raw.get("args", [])
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise RecipeError(name, "`args` must be a list of strings")
    for a in args:
        flag = a.split("=", 1)[0]
        if flag in FORBIDDEN_ARGS:
            raise RecipeError(name, f"`{flag}` is set by llm-host, not by recipes")
    label = raw.get("label", name)
    notes = raw.get("notes", "")
    if not isinstance(label, str) or not isinstance(notes, str):
        raise RecipeError(name, "`label` and `notes` must be strings")
    present = os.path.isfile(os.path.join(cfg.models_dir, model)) and (
        mmproj is None or os.path.isfile(os.path.join(cfg.models_dir, mmproj))
    )
    return Recipe(name, label, model, mmproj, ctx, max_output, args, notes, present)


def load_recipes(cfg: Config) -> tuple[list[Recipe], list[RecipeError]]:
    recipes: list[Recipe] = []
    invalid: list[RecipeError] = []
    d = pathlib.Path(cfg.recipes_dir)
    files = sorted(d.glob("*.toml")) if d.is_dir() else []
    for f in files:
        try:
            recipes.append(load_recipe(cfg, f))
        except RecipeError as e:
            invalid.append(e)
    return recipes, invalid


def build_command(cfg: Config, r: Recipe) -> list[str]:
    cmd = [cfg.server_bin, "-m", f"{cfg.models_dir}/{r.model}"]
    if r.mmproj:
        cmd += ["--mmproj", f"{cfg.models_dir}/{r.mmproj}"]
    cmd += ["--alias", r.name, "-c", str(r.ctx)]
    cmd += ["--host", "127.0.0.1", "--port", str(cfg.port)]
    return cmd + list(r.args)


# ------------------------------------------------------------------ CLI


def _print(obj: dict, as_json: bool, text: str) -> None:
    print(json.dumps(obj) if as_json else text)


def cmd_list(cfg: Config, a: argparse.Namespace) -> int:
    recipes, invalid = load_recipes(cfg)
    out = {
        "schema": SCHEMA,
        "recipes": [r.summary() for r in recipes],
        "invalid": [{"name": e.name, "reason": e.reason} for e in invalid],
    }
    lines = [
        f"{r.name:<24} {r.ctx // 1024:>4}K  {r.label}"
        + ("" if r.model_present else "  (model file missing)")
        for r in recipes
    ] + [f"{e.name:<24} INVALID: {e.reason}" for e in invalid]
    _print(out, a.json, "\n".join(lines) or f"no recipes in {cfg.recipes_dir}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="llm-host", description=__doc__.split("\n")[0])
    p.add_argument("--config", help="config.toml (default ~/.config/llm-host/config.toml)")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("list", help="list recipes")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_list)
    _add_lifecycle(sub)
    a = p.parse_args(argv)
    cfg = load_config(a.config, os.environ)
    return a.func(cfg, a)


def _add_lifecycle(sub) -> None:
    """Hook for the server commands (status, start, stop, log)."""


if __name__ == "__main__":
    sys.exit(main())
