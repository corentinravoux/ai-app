#!/usr/bin/env python3
"""llm-host: owns the llama-server of one model host.

Runs on every machine that serves a local model (the PC, later a mini PC).
AI App calls it directly on the local machine and through ssh on a remote
one; it is also usable by hand. Standard library only.

    llm-host list   [--json]          recipes in ~/.config/llm-host/recipes
    llm-host status [--json]          what runs on the port
    llm-host start <recipe> [--replace] [--wait S=600] [--json]
    llm-host stop   [--json]
    llm-host log    [-n LINES]
    llm-host probe  [--json]          check the running model: tool call, Anthropic API, speed

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
    "-hfr",  # alias of --hf-repo
    "-hfd",  # draft model repo
    "-hfrd",
    "--spec-draft-hf",
    "--hf-repo-draft",
    "-hft",  # a token has no place in a recipe file
    "--hf-token",
    "-mmu",  # projector download
    "--mmproj-url",
    "--api-prefix",  # moves /health: llm-host would see a foreign server
    "-mu",
    "--model-url",
    "-dr",
    "--docker-repo",
    "--mmproj",
    "-mm",  # short --mmproj: llm-host passes the projector itself
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
    # Recipe args first: llama.cpp keeps the last value of a repeated flag,
    # so the model, alias, window, host and port set here always win.
    cmd = [cfg.server_bin, *r.args, "-m", f"{cfg.models_dir}/{r.model}"]
    if r.mmproj:
        cmd += ["--mmproj", f"{cfg.models_dir}/{r.mmproj}"]
    cmd += ["--alias", r.name, "-c", str(r.ctx)]
    return cmd + ["--host", "127.0.0.1", "--port", str(cfg.port)]


# ------------------------------------------------------------- lifecycle

EXIT_OK, EXIT_FAILED, EXIT_RUNNING, EXIT_FOREIGN, EXIT_UNKNOWN = 0, 3, 4, 5, 6


class State:
    """Files under state_dir: server.pid, state.json, server.log."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.dir = pathlib.Path(cfg.state_dir)
        self.pidfile = self.dir / "server.pid"
        self.jsonfile = self.dir / "state.json"
        self.log = self.dir / "server.log"

    def pid(self) -> int | None:
        try:
            return int(self.pidfile.read_text().strip())
        except (OSError, ValueError):
            return None

    def info(self) -> dict:
        try:
            v = json.loads(self.jsonfile.read_text())
            return v if isinstance(v, dict) else {}
        except (OSError, ValueError):
            return {}

    def write_info(self, info: dict) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        tmp = self.jsonfile.with_suffix(".tmp")
        tmp.write_text(json.dumps(info))
        os.replace(tmp, self.jsonfile)

    def tail(self, n: int) -> str:
        try:
            lines = self.log.read_text(errors="replace").splitlines()
        except OSError:
            return ""
        return "\n".join(lines[-n:])


def _use_proc() -> bool:
    return os.path.isdir("/proc/self") and not os.environ.get("LLM_HOST_NO_PROC")


UNKNOWN = "?"  # process_state() when `ps` failed but the pid is alive


def _alive(pid: int) -> bool | None:
    """True alive (ours to signal), False gone, None alive but not ours."""
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return None


def _ps(pid: int, field: str) -> str | None:
    """`ps -o <field>= -p pid` output, or None when ps itself failed."""
    import subprocess

    try:
        r = subprocess.run(["ps", "-ww", "-o", f"{field}=", "-p", str(pid)],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    out = r.stdout.strip()
    return out if r.returncode == 0 and out else None


def process_command(pid: int) -> str | None:
    """Full command line of a live process (spaces included), or None."""
    if _use_proc():
        argv = process_argv(pid)
        return " ".join(argv) if argv else None
    return _ps(pid, "command")


def process_argv(pid: int) -> list[str] | None:
    """argv of a live process: /proc on Linux, `ps` elsewhere (macOS). With
    `ps` the arguments are split on whitespace: use [process_command] to
    match paths that contain spaces."""
    if _use_proc():
        try:
            raw = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
        except OSError:
            return None
        return [a.decode(errors="replace") for a in raw.split(b"\0") if a]
    cmd = _ps(pid, "command")
    return cmd.split() if cmd else None


def process_state(pid: int) -> str | None:
    """One-letter state (R, S, Z…), None if gone, [UNKNOWN] if `ps` failed
    while the process is alive (a transient failure must not orphan it)."""
    if _use_proc():
        try:
            stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
            return stat.rsplit(") ", 1)[1].split()[0]
        except (OSError, IndexError):
            return None
    s = _ps(pid, "stat")
    if s:
        return s[:1]
    return UNKNOWN if _alive(pid) else None


def is_ours(cfg: Config, pid: int | None) -> bool:
    """A live process whose command line runs server_bin: directly, as the
    script of an interpreter, or through `/usr/bin/env interpreter script`
    (a shebang, while env has not yet exec'd). Zombies and reused pids do
    not count."""
    if not pid:
        return False
    state = process_state(pid)
    if state in (None, "Z"):
        return False
    if state == UNKNOWN:
        return True  # alive, ps failed: keep trusting our own pidfile
    real = os.path.realpath(cfg.server_bin)
    cmd = process_command(pid)
    if cmd is None:
        return bool(_alive(pid)) and not _use_proc()
    # The binary itself, or its script after an interpreter / `env interp`
    # (fakes in tests); prefix match so a path with spaces still counts.
    rest = cmd
    for _ in range(3):
        if rest.startswith((real, cfg.server_bin)):
            return True
        rest = rest.split(" ", 1)[1] if " " in rest else ""
    return False


def _http(port: int, path: str, timeout: float = 2.0) -> tuple[int, bytes] | None:
    """(status, body), or None when nothing answers on the port."""
    import http.client

    try:
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        c.request("GET", path)
        r = c.getresponse()
        body = r.read()
        c.close()
        return r.status, body
    except (OSError, http.client.HTTPException):
        return None


def _props_ctx(port: int) -> int | None:
    r = _http(port, "/props")
    if not r or r[0] != 200:
        return None
    try:
        n = json.loads(r[1])["default_generation_settings"]["n_ctx"]
        return n if isinstance(n, int) and n > 0 else None
    except (ValueError, KeyError, TypeError):
        return None


def gpu_info() -> dict | None:
    import shutil
    import subprocess

    exe = shutil.which("nvidia-smi")
    if not exe:
        return None
    try:
        r = subprocess.run(
            [exe, "--query-gpu=name,memory.used,memory.total", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )
        name, used, total = [x.strip() for x in r.stdout.splitlines()[0].split(",")]
        return {"name": name, "used_mib": int(used), "total_mib": int(total)}
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        return None


def compute_status(cfg: Config, gpu: bool = True) -> dict:
    import socket

    st = State(cfg)
    info = st.info()
    pid = st.pid()
    ours = is_ours(cfg, pid)
    health = _http(cfg.port, "/health")
    out = {
        "schema": SCHEMA,
        "host": socket.gethostname().split(".")[0],
        "state": "stopped",
        "recipe": None,
        "label": None,
        "alias": None,
        "ctx": None,
        "max_output": None,
        "vision": False,
        "port": cfg.port,
        "pid": None,
        "started": None,
        "gpu": gpu_info() if gpu else None,
        "error": None,
    }
    recipe_fields = {
        "recipe": info.get("recipe"),
        "label": info.get("label"),
        "alias": info.get("recipe"),
        "ctx": info.get("ctx"),
        "max_output": info.get("max_output"),
        "vision": bool(info.get("vision")),
        "started": info.get("started"),
    }
    if ours:
        out.update(recipe_fields, pid=pid)
        if health and health[0] == 200:
            out["state"] = "ready"
            # Only the server knows its per-slot window; the recipe's -c is
            # too big with -np 2, so no fallback to it.
            out["ctx"] = _props_ctx(cfg.port)
        else:
            out["state"] = "loading"
        return out
    if pid is not None:
        # Stale: process gone or not ours. Re-read under the lock: a start
        # may have written a new pid since our read (app polling during a
        # model switch deleted the new server's pidfile otherwise).
        with _locked(cfg):
            if st.pid() == pid:
                st.pidfile.unlink(missing_ok=True)
    if health is not None:
        out["state"] = "foreign"
        out["error"] = f"a llama-server not started by llm-host is using port {cfg.port}"
        return out
    if info.get("recipe") and not info.get("stopped"):
        out.update(recipe_fields, state="error")
        out["error"] = info.get("error") or st.tail(20) or "the server exited"
    return out


def _terminate(pid: int) -> None:
    import signal
    import time

    for sig, wait in ((signal.SIGTERM, 15.0), (signal.SIGKILL, 5.0)):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            return
        except PermissionError:
            os.kill(pid, sig)
        end = time.monotonic() + wait
        while time.monotonic() < end:
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
                if done:
                    return
            except ChildProcessError:
                if process_state(pid) in (None, "Z"):
                    return
            time.sleep(0.1)


import contextlib


_lock_depth = 0


@contextlib.contextmanager
def _locked(cfg: Config):
    """Serialises start, stop and pidfile cleanup between llm-host processes
    on this host. Re-entrant within one process."""
    import fcntl

    global _lock_depth
    if _lock_depth:
        _lock_depth += 1
        try:
            yield
        finally:
            _lock_depth -= 1
        return
    d = pathlib.Path(cfg.state_dir)
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        _lock_depth = 1
        try:
            yield
        finally:
            _lock_depth = 0
            fcntl.flock(f, fcntl.LOCK_UN)


def stop_server(cfg: Config) -> None:
    st = State(cfg)
    pid = st.pid()
    if is_ours(cfg, pid):
        _terminate(pid)
    st.pidfile.unlink(missing_ok=True)
    info = st.info()
    if info:
        info["stopped"] = True
        info.pop("error", None)
        st.write_info(info)


def _status_text(s: dict) -> str:
    if s["state"] == "ready":
        return f"ready: {s['label']} ({s['recipe']}), {s['ctx']} tokens, port {s['port']}"
    if s["state"] == "loading":
        return f"loading {s['label']} ({s['recipe']})"
    if s["state"] in ("error", "foreign"):
        return f"{s['state']}: {s['error']}"
    return f"stopped (port {s['port']})"


def cmd_status(cfg: Config, a: argparse.Namespace) -> int:
    s = compute_status(cfg)
    _print(s, a.json, _status_text(s))
    return EXIT_OK


def cmd_stop(cfg: Config, a: argparse.Namespace) -> int:
    with _locked(cfg):
        s = compute_status(cfg)
        if s["state"] == "foreign":
            _print(s, a.json, _status_text(s))
            return EXIT_FOREIGN
        stop_server(cfg)
    s = compute_status(cfg)
    _print(s, a.json, _status_text(s))
    return EXIT_OK


def cmd_start(cfg: Config, a: argparse.Namespace) -> int:
    import datetime
    import subprocess
    import time

    def fail(code: int, msg: str) -> int:
        s = compute_status(cfg)
        if code == EXIT_UNKNOWN:
            s["error"] = msg
        _print(s, a.json, msg)
        return code

    recipes, invalid = load_recipes(cfg)
    r = next((x for x in recipes if x.name == a.recipe), None)
    if r is None:
        bad = next((e for e in invalid if e.name == a.recipe), None)
        return fail(EXIT_UNKNOWN, f"invalid recipe {a.recipe}: {bad.reason}" if bad
                    else f"unknown recipe {a.recipe}")
    if not r.model_present:
        return fail(EXIT_UNKNOWN, f"model file missing for {r.name}: {cfg.models_dir}/{r.model}")
    st = State(cfg)
    with _locked(cfg):
        # Check, stop and spawn under the lock: a second start (another app,
        # the laptop) waits here and then sees this one as running.
        s = compute_status(cfg)
        if s["state"] == "foreign":
            return fail(EXIT_FOREIGN, s["error"])
        if s["state"] in ("ready", "loading"):
            if not a.replace:
                return fail(EXIT_RUNNING, f"{s['recipe']} is already running: use --replace")
            stop_server(cfg)
        started = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        with open(st.log, "wb") as log:
            p = subprocess.Popen(
                build_command(cfg, r), stdout=log, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, start_new_session=True, close_fds=True,
            )
        st.pidfile.write_text(str(p.pid))
        st.write_info({
            "recipe": r.name, "label": r.label, "ctx": r.ctx, "max_output": r.max_output,
            "vision": r.vision, "started": started, "stopped": False,
        })

    def finish(code: int) -> int:
        s = compute_status(cfg)
        _print(s, a.json, _status_text(s))
        return code

    def still_ours() -> bool:
        """This start still owns the state files. A missing pidfile with
        state.json naming this very start was deleted by mistake: put it
        back. Another pid, or a stop, means a later start or stop won."""
        with _locked(cfg):
            cur = st.pid()
            if cur == p.pid:
                return True
            info = st.info()
            if (cur is None and info.get("started") == started
                    and info.get("recipe") == r.name and not info.get("stopped")):
                st.pidfile.write_text(str(p.pid))
                return True
            return False

    end = time.monotonic() + max(a.wait, 0)
    while True:
        if st.pid() != p.pid and not still_ours():
            # Replaced by a later start (or stopped): its outcome is not ours
            # to report as a failure, and its files are not ours to touch.
            if p.poll() is None:
                _terminate(p.pid)
            return finish(EXIT_OK)
        if p.poll() is not None:
            with _locked(cfg):
                if not still_ours():
                    return finish(EXIT_OK)
                st.pidfile.unlink(missing_ok=True)
                info = st.info()
                info["error"] = st.tail(20) or f"llama-server exited with code {p.returncode}"
                st.write_info(info)
            return finish(EXIT_FAILED)
        s = compute_status(cfg, gpu=False)
        if s["state"] == "ready" or a.wait <= 0:
            _print(s, a.json, _status_text(s))
            return EXIT_OK
        if time.monotonic() >= end:
            with _locked(cfg):
                if not still_ours():
                    return finish(EXIT_OK)
                _terminate(p.pid)
                st.pidfile.unlink(missing_ok=True)
                info = st.info()
                info["error"] = (f"llama-server did not become ready within {a.wait:g} s\n"
                                 + st.tail(20))
                st.write_info(info)
            return finish(EXIT_FAILED)
        time.sleep(0.25)


LEAK_MARKERS = ("<tool_call>", "<function=", "</tool_call>", "<|tool_call", "<|channel|>")

PROBE_TOOL = {
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city.",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string", "description": "City name"}},
            "required": ["city"],
        },
    },
}


def _post(port: int, path: str, body: dict, timeout: float = 120.0) -> tuple[int, dict]:
    import http.client

    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    c.request("POST", path, json.dumps(body), {"Content-Type": "application/json",
                                                "x-api-key": "local"})
    r = c.getresponse()
    raw = r.read()
    c.close()
    try:
        return r.status, json.loads(raw or b"{}")
    except ValueError:
        return r.status, {}


def run_probe(cfg: Config, alias: str) -> list[dict]:
    """Checks a ready server the way agents use it. Each check is
    {name, ok, detail}; network errors become failed checks."""
    checks = []

    def check(name, fn):
        try:
            ok, detail = fn()
        except Exception as e:  # one line per check, never a traceback
            ok, detail = False, f"{type(e).__name__}: {e}"
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    def tool_call():
        code, r = _post(cfg.port, "/v1/chat/completions", {
            # Room for a thinking model to reason before it calls the tool.
            "model": alias, "max_tokens": 2048, "temperature": 0,
            "tools": [PROBE_TOOL],
            "messages": [{"role": "user", "content": "What is the weather in Paris? Use the tool."}],
        }, timeout=300)  # 2048 tokens at ~10 tok/s on a CPU-offloaded host
        if code != 200:
            return False, f"HTTP {code}"
        msg = (r.get("choices") or [{}])[0].get("message", {})
        text = msg.get("content") or ""
        calls = msg.get("tool_calls") or []
        if not calls:
            leak = any(m in text for m in LEAK_MARKERS)
            return False, ("the tool call came back as text: chat template or parser problem"
                           if leak else "no tool call in the answer")
        fn = calls[0].get("function", {})
        raw = fn.get("arguments")
        try:
            args = raw if isinstance(raw, dict) else json.loads(raw or "{}")
        except (ValueError, TypeError):
            return False, f"invalid JSON arguments: {fn.get('arguments')!r}"
        if any(m in text for m in LEAK_MARKERS):
            return False, "tool markup also leaked into the text"
        return True, f"{fn.get('name')}({json.dumps(args)})"

    def anthropic():
        code, r = _post(cfg.port, "/v1/messages", {
            "model": alias, "max_tokens": 16,
            "messages": [{"role": "user", "content": "Say ok."}],
        })
        ok = code == 200 and isinstance(r.get("content"), list)
        return ok, "/v1/messages answers (Claude Code)" if ok else f"/v1/messages: HTTP {code}"

    def generation():
        code, r = _post(cfg.port, "/v1/chat/completions", {
            "model": alias, "max_tokens": 64, "temperature": 0,
            "messages": [{"role": "user", "content": "Count from 1 to 30, separated by spaces."}],
        })
        if code != 200:
            return False, f"HTTP {code}"
        tps = (r.get("timings") or {}).get("predicted_per_second")
        return True, f"{tps:.1f} tok/s" if isinstance(tps, (int, float)) else "speed not reported"

    check("tool_call", tool_call)
    check("anthropic", anthropic)
    check("generation", generation)
    return checks


def cmd_probe(cfg: Config, a: argparse.Namespace) -> int:
    s = compute_status(cfg, gpu=False)
    if s["state"] != "ready":
        msg = ("No model is running: start one first" if s["state"] == "stopped"
               else f"The server is {s['state']}: probe needs a ready model")
        _print({"schema": SCHEMA, "ok": False, "checks": [], "error": msg}, a.json, msg)
        return 1
    checks = run_probe(cfg, s["alias"] or s["recipe"] or "local")
    ok = all(c["ok"] for c in checks)
    text = "\n".join(f"{'PASS' if c['ok'] else 'FAIL'}  {c['name']:<10} {c['detail']}" for c in checks)
    _print({"schema": SCHEMA, "ok": ok, "checks": checks, "error": None}, a.json, text)
    return EXIT_OK if ok else EXIT_FAILED


def cmd_log(cfg: Config, a: argparse.Namespace) -> int:
    text = State(cfg).tail(max(a.n, 1))
    if text:
        print(text)
    return EXIT_OK


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
    s = sub.add_parser("status", help="state of the server on the port")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_status)
    s = sub.add_parser("start", help="start a recipe")
    s.add_argument("recipe")
    s.add_argument("--replace", action="store_true", help="stop the running server first")
    s.add_argument("--wait", type=float, default=600.0, help="seconds to wait for ready (0: return at once; default 600)")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_start)
    s = sub.add_parser("stop", help="stop the server llm-host started")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_stop)
    s = sub.add_parser("probe", help="check the running model: tool call, Anthropic API, speed")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_probe)
    s = sub.add_parser("log", help="tail of the server log")
    s.add_argument("-n", type=int, default=80)
    s.set_defaults(func=cmd_log)
    a = p.parse_args(argv)
    cfg = load_config(a.config, os.environ)
    return a.func(cfg, a)


if __name__ == "__main__":
    sys.exit(main())
