# ai-app Local Model Hosts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `alcfai-app` into `ai-app`: the same tabbed agent launcher, now also driving llama-server on model hosts the user owns (the PC today, a mini PC later), from the host itself or from the laptop over Tailscale + SSH.

**Architecture:** A stdlib-Python script, `llm-host`, runs on every model host and owns the llama-server process through tested per-model recipes (`list`, `status`, `start`, `stop`, `log`, JSON out). The Flutter app keeps a host registry, calls `llm-host` directly or through `ssh`, keeps one `ssh -N -L` forward per remote host, and at every tab launch generates the agent's sandboxed config from the host's live status. Agents always run on the app's machine and always talk to `127.0.0.1`.

**Tech Stack:** Flutter 3.47.7 / Dart 3.13.5 (Linux), existing deps (`xterm`, `flutter_pty`, `crypto`, `path`, `uuid`); Python ≥ 3.11 standard library only (`tomllib`, `http.server`, `unittest`); llama.cpp b12190; OpenSSH; Tailscale; Node ≥ 22.19 for Pi and OpenCode.

**Spec:** [local-hosts-design.md](local-hosts-design.md).

## Global Constraints

- App repo: `~/Software/alcfai-app` until Task 6, then `~/Software/ai-app`. Dart package `ai_app`, window title `AI App`. Commit locally; **never push** (user pushes).
- Flutter binary: `~/Software/flutter/bin/flutter` (not on PATH); written `flutter` below.
- Interfaces named "existing" come from the 2026-10-27 plan (`AgentKind`, `Sandbox`, `Profile`, `Backend`, `LaunchSpec`, `buildLaunch`, `Runner`, `RunResult`, `RealConfigGuard`, `AppState`, `PtyStarter`). The repo has moved since (Codex/OpenCode wiring `3378096`; on 2026-11-10 the Tara cluster became the default and `lib/core/claude_slots.dart` maps Claude's `/model` slots for ALCF): **read the current file before editing it** and keep its conventions. Nothing here changes ALCF behaviour.
- llama-server listens on `127.0.0.1` only. No `--host 0.0.0.0`, no `--api-key`, anywhere.
- The app must never write under `~/.claude`, `~/.claude-alt`, `~/Software/claude_config/claude`, `~/.codex`, `~/.pi`, `~/.config/opencode`.
- App data: `~/.local/share/ai-app/` (local sandboxes in `local/<hostId>/<agent>/`, SSH control sockets in `ssh/`, tools in `bin/`). App config: `~/.config/ai-app/hosts.json`. The ALCF sandbox stays at `~/.local/share/alcfai/home`.
- Host side: `~/.local/bin/llm-host`, config `~/.config/llm-host/config.toml`, recipes `~/.config/llm-host/recipes/<name>.toml`, state `~/.local/state/llm-host/` (`server.pid`, `state.json`, `server.log`).
- Default ports: llama-server `9931`; first remote forward `19931`.
- Minimum context per agent: Pi `16384`, OpenCode `24576`, Claude Code `32768`.
- Weights ≥ 4-bit, KV cache `q8_0` at most, `-np 1` unless a recipe is made for Claude Code, thinking off for agent recipes, speculative decoding off.
- PC: nothing installed on `/` (19 GB) that can go under `$HOME`; no new Python env; models are downloaded only on explicit request.
- Steps marked **[sudo: user]** are run by the user; stop and ask.
- Each task names its machine: **[PC]**, **[laptop]**, or **[any]** (pure code and unit tests).
- Dart tests never touch the real home (`Directory.systemTemp.createTempSync()`). Python tests never start a real llama-server (fake server script).
- Commit trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`.

## Review Focus

1. **The link drops mid-session** (lid closed, Wi-Fi change, train tunnel). Expected: the host tile turns "unreachable" within ~20 s, the forward reconnects by itself with backoff, an agent request fails fast instead of hanging. Tests: `tunnel restarts after the process exits`, `backoff is 1,2,4,8,15,15` (Task 9); `ssh exit 255 maps to HostUnreachable` (Task 8).
2. **A local Claude tab reaching Anthropic, or the real configs being written.** Expected: `ANTHROPIC_BASE_URL` is always `http://127.0.0.1:<port>`, inherited `ANTHROPIC_*` and `CLAUDE_CONFIG_DIR` are stripped, the guard hashes are unchanged. Tests: `local claude env never contains an inherited ANTHROPIC key`, `writeLocalConfig refuses a dir under a guarded root` (Tasks 10, 11).
3. **The declared window is larger than the real one** (`-np 2` halves it; a recipe edited by hand). Expected: `status` reports the per-slot `n_ctx` read from `/props`, and configs use that number. Tests: `status ctx comes from /props, not the recipe` (Task 4); `open is refused below the agent minimum` (Task 11).
4. **A llama-server the app did not start is on the port** (started from a shell, ComfyUI helper, a crashed pidfile). Expected: state `foreign`, Stop disabled, `start` refuses, nothing is killed. Tests: `status reports foreign when the port answers without our pidfile`, `stop never kills a foreign server` (Task 4).
5. **Start fails or is slow** (model file missing, out of memory, bad flag, 18 GB cold read from a SATA SSD). Expected: `start` waits up to 300 s for `/health`, and on failure returns the last 20 log lines; the UI shows them. Tests: `start returns the log tail when the server exits early`, `start times out with state error` (Task 4); `start failure shows the log tail` (Task 12).

---

## Phase 0 — The engine on the PC, by hand

No app code. Its outputs (measured recipes and wire notes) are inputs to every later task.

### Task 1: Measure the model and fix two recipes **[PC]**

**Files:**
- Modify: `~/Software/claude_config/dotfiles/local-llm/machines/corentin-MS-7B86.md` (section "Measurements")
- Create: `<scratchpad>/recipes-draft.md` (the two chosen flag sets, consumed by Task 5)

- [ ] **Step 1:** `powerprofilesctl set performance`; close ComfyUI; note `nvidia-smi --query-gpu=memory.used,memory.total --format=csv` and `free -g`.
- [ ] **Step 2: Offload sweep at 32K.** Start `llama-server -m ~/Software/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf --alias local -c 32768 -ngl 99 --n-cpu-moe N -t 6 -fa on -ctk q8_0 -ctv q8_0 -np 1 --chat-template-kwargs '{"enable_thinking":false}' --host 127.0.0.1 --port 9931`, beginning with all experts on CPU (`--cpu-moe`), then lowering `N` until VRAM is 0.5–1 GB from full. For each `N` that loads, run `python3 -I ~/.claude/skills/local-llm/scripts/llm_probe.py --url http://127.0.0.1:9931` and record prefill tok/s, generation tok/s, VRAM, RAM, swap use.
  Expected: every probe check PASS (health, tool_call, cache, anthropic) for the chosen `N`. A FAIL is fixed here (troubleshooting.md), not later.
- [ ] **Step 3: Same at 49152** (`-c 49152`), to learn whether a second, larger recipe is worth having. If it swaps or generation falls under ~5 tok/s, drop it and say so.
- [ ] **Step 4: Claude Code variant.** With the best 32K flags, test `-np 2 -c 65536` (two 32K slots) only if Step 3 showed memory for it; otherwise record "Claude Code: single slot only".
- [ ] **Step 5:** Same sweep, shorter, for `gpt-oss-20b-MXFP4.gguf` (no `enable_thinking` kwarg; probe must show a structured tool call) and `Qwen3.5-9B-UD-Q4_K_XL.gguf` fully on GPU (`-ngl 99`, no `--n-cpu-moe`).
- [ ] **Step 6:** Write every run into the machine file as `date · build · model+quant · exact command · numbers`, and the chosen flag sets into `recipes-draft.md` under the names `qwen36-35b-32k`, `qwen36-35b-48k` (if kept), `gptoss-20b-32k`, `qwen35-9b-32k`.
- [ ] **Step 7:** Commit and push `claude_config`: `docs(local-llm): first measurements on corentin-MS-7B86`.

### Task 2: Node, Pi, OpenCode, and one hand-wired session each **[PC]**

**Files:**
- Create: `<scratchpad>/local-wire-notes.md` (moved to `docs/local-wire-notes.md` in Task 6)
- Modify: the machine file (section "Software")

- [ ] **Step 1:** Install Node under `$HOME`, not on `/`: unpack the official Linux x64 tarball of the current LTS (≥ 22.19) to `~/opt/node`, add `~/opt/node/bin` to `PATH` in `~/.bashrc` **[user edits `.bashrc`]**. Expected: `node --version` ≥ v22.19.
- [ ] **Step 2:** `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`; install OpenCode with its official installer (lands in `~/.opencode/bin`). Expected: `pi --version`, `opencode --version` print versions.
- [ ] **Step 3: Pi by hand.** With the `qwen36-35b-32k` server running, set `PI_CODING_AGENT_DIR=<scratchpad>/pi-agent`, write `models.json` and `settings.json` exactly as in `local-llm/references/harness-configs.md` § Pi (single-model form), run `pi` in a scratch git checkout, and ask it to create a file and run a command.
  Record in the notes: (a) whether the generic provider is accepted as written, (b) **how the default model is selected** (a `settings.json` key, a CLI flag, or `/model` once), (c) the first-turn `prompt_n` from the server log (Pi's scaffolding size), (d) the exact `pi.registerTool` signature and file location for extensions, from the Pi docs shipped in the package.
- [ ] **Step 4: OpenCode by hand.** `OPENCODE_CONFIG=<scratchpad>/opencode.jsonc` with the config from harness-configs.md § OpenCode. Same task. Record: accepted keys (fix any rejected key in the notes), first-turn `prompt_n`, whether the built-in web fetch works and how long its output is.
- [ ] **Step 5: Claude Code by hand.** `CLAUDE_CONFIG_DIR=<scratchpad>/claude-local` plus the env block of `harnesses.md` § Claude Code, `claude --bare --tools "Bash,Read,Edit"`. Same task. Record: first-turn `prompt_n`, any HTTP 400 and the variable that fixed it, whether `--append-system-prompt` is accepted together with `--bare`, whether one slot survives its background requests.
  Expected: `~/.claude/settings.json` hash identical before and after (`sha256sum`).
- [ ] **Step 6:** For each agent, note whether a tab keeps working after the server is restarted with a different `--alias` (decides how strict Task 12's "switch" warning must be).
- [ ] **Step 7:** Update the machine file ("Not installed yet" line, versions). Commit and push `claude_config`.

**Gate:** if no agent completes the small task at 32K, stop and report; the rest of the plan assumes at least Pi works.

---

## Phase 1 — `llm-host`

### Task 3: Config, recipes, `list` **[any]**

**Files:**
- Create: `host/llm_host.py`, `host/tests/test_recipes.py`, `host/tests/__init__.py`, `host/recipes.example/qwen36-35b-32k.toml`

**Interfaces:**
- Produces:
  - `FORBIDDEN_ARGS = ('--host', '--port', '--api-key', '--api-key-file', '-m', '--model', '-c', '--ctx-size', '-a', '--alias', '-hf', '--hf-repo', '-hff', '--hf-file', '--mmproj')`
  - `@dataclass Config: server_bin: str; models_dir: str; port: int = 9931; recipes_dir: str; state_dir: str`
  - `load_config(path: str | None, env: Mapping[str, str]) -> Config` — default path `$XDG_CONFIG_HOME/llm-host/config.toml` (fallback `~/.config`), `state_dir` `$XDG_STATE_HOME/llm-host` (fallback `~/.local/state`); `~` expanded in every path.
  - `@dataclass Recipe: name: str; label: str; model: str; mmproj: str | None; ctx: int; max_output: int; args: list[str]; notes: str; model_present: bool; vision: bool` (`vision = mmproj is not None`)
  - `load_recipes(cfg: Config) -> list[Recipe]` (sorted by name; invalid files raise `RecipeError(name, reason)`)
  - `build_command(cfg: Config, r: Recipe) -> list[str]`
  - CLI: `llm-host [--config PATH] list [--json]` → `{"schema": 1, "recipes": [{name,label,model,ctx,max_output,vision,notes,model_present}], "invalid": [{name,reason}]}`

Recipe file format (the example file, with values replaced in Task 5):

```toml
label = "Qwen3.6 35B-A3B · 32K"
model = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"   # relative to models_dir
mmproj = "unsloth/Qwen3.6-35B-A3B-MTP-GGUF/mmproj-F16.gguf"                 # optional
ctx = 32768          # passed as -c; with -np 2 each slot gets half
max_output = 4096    # the output cap agents are told to use
args = ["-ngl", "99", "--n-cpu-moe", "22", "-t", "6", "-fa", "on",
        "-ctk", "q8_0", "-ctv", "q8_0", "-np", "1",
        "--chat-template-kwargs", "{\"enable_thinking\":false}"]
notes = "measured 2026-11-xx, b12190: see machines/corentin-MS-7B86.md"
```

- [ ] **Step 1: Failing tests** (`python3 -m unittest discover host/tests -v`):
  - `test_load_config_defaults`: missing file → `SystemExit` with message containing `config.toml`; a file with only `server_bin` and `models_dir` → `port == 9931`, `recipes_dir` ends with `llm-host/recipes`.
  - `test_recipe_name_is_file_stem`; names must match `^[a-z0-9][a-z0-9._-]{0,63}$`, else `RecipeError`.
  - `test_recipe_rejects_forbidden_args`: `args = ["--host", "0.0.0.0"]` → `RecipeError` naming `--host`; same for each entry of `FORBIDDEN_ARGS`, also in `--flag=value` form.
  - `test_recipe_requires_ctx_and_max_output`: missing or non-positive → `RecipeError`; `max_output >= ctx` → `RecipeError`.
  - `test_model_present_false_when_file_missing`; `list --json` still lists the recipe.
  - `test_invalid_recipe_does_not_hide_the_others`: one bad file, one good → good in `recipes`, bad in `invalid`.
  - `test_build_command`: equals `[server_bin, '-m', '<models_dir>/<model>', '--mmproj', '<models_dir>/<mmproj>', '--alias', name, '-c', '32768', '--host', '127.0.0.1', '--port', '9931', *args]`; no `--mmproj` pair when `mmproj` is absent.
  - `test_model_path_cannot_escape_models_dir`: `model = "../../etc/passwd"` or an absolute path → `RecipeError`.
- [ ] **Step 2:** Run. Expected: FAIL (module missing).
- [ ] **Step 3:** Implement in the single file `host/llm_host.py` (`#!/usr/bin/env python3`, `argparse`, `tomllib`, `json`; no third-party import).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(host): llm-host config, recipes and list`.

### Task 4: Server lifecycle: `status`, `start`, `stop`, `log` **[any]**

**Files:**
- Modify: `host/llm_host.py`
- Create: `host/tests/fake_llama_server.py`, `host/tests/test_lifecycle.py`

**Interfaces:**
- Consumes: `Config`, `Recipe`, `load_recipes`, `build_command` (Task 3).
- Produces (CLI, all print one JSON object with `--json`):
  - `status` → `{"schema":1,"host":<hostname -s>,"state":"stopped"|"loading"|"ready"|"foreign"|"error","recipe":str|null,"label":str|null,"alias":str|null,"ctx":int|null,"max_output":int|null,"vision":bool,"port":int,"pid":int|null,"started":<ISO 8601>|null,"gpu":{"name":str,"used_mib":int,"total_mib":int}|null,"error":str|null}`. Exit 0 for every state.
  - `start <recipe> [--replace] [--wait SECONDS=300]` → same object. Exit `0` ready, `3` failed or timed out (`state: error`, `error` = last 20 log lines), `4` a server we started is already up and `--replace` is absent, `5` a foreign server holds the port, `6` unknown recipe or model file missing.
  - `stop` → same object. Exit `0` stopped (also when nothing ran), `5` foreign.
  - `log [-n LINES=80]` → raw text of the log tail.
- State rules:
  - `ready`: our pidfile's process is alive and `GET /health` returns 200. `ctx` is `default_generation_settings.n_ctx` from `GET /props` (the per-slot size); fall back to the recipe's `ctx` only if `/props` lacks it.
  - `loading`: our process is alive, `/health` is not yet 200.
  - `foreign`: no live process of ours, yet the port answers `/health`.
  - `error`: `state.json` names a recipe, the process is gone, and the last start did not end with `stop`.
  - `stopped`: otherwise. A stale pidfile is removed.
  - A pid counts as ours only if `/proc/<pid>/cmdline` starts with `server_bin`.
- `start` launches with `subprocess.Popen(cmd, stdout=log, stderr=STDOUT, stdin=DEVNULL, start_new_session=True)`, truncating the log first, so the server survives the SSH session that started it. `stop` sends SIGTERM, waits 15 s, then SIGKILL.
- `gpu`: first line of `nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader,nounits`; `null` if the command is missing or fails.

`fake_llama_server.py`: accepts the same argv shape, reads `--port`, `-c`, `--alias`; env `FAKE_BOOT_SECONDS` (answer 503 on `/health` until then), `FAKE_EXIT_AFTER` (print a line, exit 1), `FAKE_NCTX` (value served in `/props`); serves `/health` and `/props` with `http.server`.

- [ ] **Step 1: Failing tests** (each uses a temp config whose `server_bin` is the fake, and a free port):
  - `test_status_stopped_when_nothing_runs`: `state == 'stopped'`, `pid is None`.
  - `test_start_reaches_ready_and_status_agrees`: exit 0; `recipe`, `alias` equal the recipe name; `port` matches.
  - `test_status_ctx_comes_from_props_not_the_recipe`: recipe `ctx = 65536`, `FAKE_NCTX=32768` → `ctx == 32768`.
  - `test_status_loading_before_health`: `FAKE_BOOT_SECONDS=3`, `start --wait 0` returns `loading`.
  - `test_start_returns_the_log_tail_when_the_server_exits_early`: `FAKE_EXIT_AFTER=1` → exit 3, `state == 'error'`, the fake's line is in `error`.
  - `test_start_times_out_with_state_error`: `FAKE_BOOT_SECONDS=60`, `--wait 1` → exit 3, and the process is killed.
  - `test_start_twice_needs_replace`: second start exit 4; with `--replace` exit 0 and a new pid.
  - `test_status_reports_foreign_when_the_port_answers_without_our_pidfile`: fake started directly by the test → `foreign`.
  - `test_stop_never_kills_a_foreign_server`: exit 5, the fake is still alive.
  - `test_start_refuses_when_foreign`: exit 5.
  - `test_stop_is_idempotent`: exit 0 twice; pidfile gone.
  - `test_server_survives_the_caller`: start through a child `python3 llm_host.py start`, child exits, `status` still `ready`.
  - `test_unknown_recipe_and_missing_model`: exit 6 for both.
  - `test_log_tail`: `log -n 2` prints the last two lines.
  - `test_gpu_null_without_nvidia_smi`: `PATH` without it → `"gpu": null`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Write `state.json` atomically (temp file + `os.replace`).
- [ ] **Step 4:** Run. Expected: PASS. Run the whole suite twice in a row to catch leaked fakes (`pgrep -f fake_llama_server` empty afterwards).
- [ ] **Step 5:** Commit `feat(host): llama-server lifecycle with foreign-server protection`.

### Task 5: Host install script and the PC's real recipes **[PC]**

**Files:**
- Create: `scripts/install-host.sh`, `docs/hosts.md`
- Create on the PC (not in git): `~/.config/llm-host/config.toml`, `~/.config/llm-host/recipes/*.toml`

- [ ] **Step 1:** `scripts/install-host.sh`: copy `host/llm_host.py` to `~/.local/bin/llm-host` (mode 755); if `~/.config/llm-host/config.toml` is absent, write it from the arguments `--server-bin PATH --models-dir PATH [--port N]` and copy `host/recipes.example/` to `~/.config/llm-host/recipes.example/`; never overwrite an existing config or recipe. Ends by running `llm-host list`.
- [ ] **Step 2:** Run it on the PC: `scripts/install-host.sh --server-bin ~/Software/llama.cpp/build/bin/llama-server --models-dir ~/Software/models`.
- [ ] **Step 3:** Write the recipes from `recipes-draft.md` (Task 1) into `~/.config/llm-host/recipes/`, one file per name, each `notes` citing its measurement date.
- [ ] **Step 4: Verify with the real server:**
  - `llm-host list --json` → every recipe `model_present: true`, `invalid: []`.
  - `llm-host start qwen36-35b-32k` → exit 0, `state: ready`, `ctx: 32768`, `gpu.used_mib` plausible.
  - `python3 -I ~/.claude/skills/local-llm/scripts/llm_probe.py --url http://127.0.0.1:9931` → all PASS.
  - `ss -ltnp | grep 9931` → bound to `127.0.0.1` only.
  - `llm-host start gptoss-20b-32k --replace` → ready with the other alias; `llm-host stop` → `stopped`, VRAM freed in `nvidia-smi`.
  - Start a server by hand in another shell, then `llm-host status` → `foreign`; `llm-host stop` → exit 5.
- [ ] **Step 5:** `docs/hosts.md`, "Adding a model host" checklist: llama.cpp build, models folder, measure (link to the local-llm skill workflow), `install-host.sh`, recipes, sshd + Tailscale (Task 15), then "Add host" in the app. This is the mini-PC procedure.
- [ ] **Step 6:** Commit `feat(host): install script and host setup guide`. Record in the machine file that `llm-host` now owns the server on this PC; commit and push `claude_config`.

---

## Phase 2 — Rename

### Task 6: `alcfai-app` → `ai-app` **[laptop, then PC]**

**Files:**
- Modify: `pubspec.yaml` (`name: ai_app`), every `package:alcfai_app/` import, `linux/CMakeLists.txt` (`BINARY_NAME`, `APPLICATION_ID` → `dev.ravoux.ai_app`), `linux/runner/my_application.cc` (window title `AI App`), `scripts/install-linux.sh`, `README.md`, `docs/*`
- Move: `assets/icon/alcfai.png` → `assets/icon/ai-app.png`
- Create: `docs/local-hosts-design.md`, `docs/local-hosts-plan.md`, `docs/local-wire-notes.md` (from this folder and Task 2)
- Modify in `claude_config`: `install.sh` (comment only: app path), `dotfiles/bash/claude.sh` (the guard's message names "the AI App"), `memory/-home-ravoux-Documents-Python/project_alcfai_app.md`

- [ ] **Step 1:** `git status` clean and `flutter test` green before touching anything. Note the test count.
- [ ] **Step 2:** Rename the package and the identifiers listed above. Unchanged on purpose: the ALCF sandbox path `~/.local/share/alcfai/home`, profile labels `… · ALCF`, `install.sh --alcf`, env var `ALCF_SESSION_ID`.
- [ ] **Step 3:** `grep -rn -i alcfai . --include='*.dart' --include='*.yaml' --include='*.sh' --include='*.cc' --include='CMakeLists.txt'`. Expected: only the sandbox path constant and comments about ALCF.
- [ ] **Step 4:** `scripts/install-linux.sh`: install to `~/.local/opt/ai-app`, desktop file `ai-app.desktop` (`Name=AI App`); if `~/.local/opt/alcfai-app` or `alcfai-app.desktop` exists, remove them after the new install succeeds.
- [ ] **Step 5:** `flutter test` (same count, all pass), `flutter build linux --release`, run the install script. Expected: "AI App" in the launcher; an existing `Claude · ALCF` profile still shows as configured and opens.
- [ ] **Step 6:** Move the directory: `mv ~/Software/alcfai-app ~/Software/ai-app`. **[user]** renames the GitHub repository to `ai-app`; then `git remote set-url origin git@github.com:corentinravoux/ai-app.git`.
- [ ] **Step 7:** Commit `refactor: rename to ai-app`. In `claude_config`: update the three files, rename the memory file's `name`/`description` to `ai-app`, commit and push.
- [ ] **Step 8 [PC]:** clone the repo to `~/Software/ai-app` (needed from Task 16 on; earlier host tasks can run from any checkout).

---

## Phase 3 — App core (pure Dart)

### Task 7: Host registry **[any]**

**Files:**
- Create: `lib/core/hosts.dart`
- Test: `test/core/hosts_test.dart`

**Interfaces:**
- Produces:
  - `enum HostKind { local, ssh }`
  - `class ModelHost { final String id; final String label; final HostKind kind; final String? sshTarget; final int serverPort; final int? localPort; final String llmHostCmd; int get agentPort; String get baseUrl; Map<String, dynamic> toJson(); factory ModelHost.fromJson(Map<String, dynamic>); }` — `agentPort` is `serverPort` for `local`, `localPort` for `ssh`; `baseUrl` is `'http://127.0.0.1:$agentPort'`; `llmHostCmd` defaults to `'llm-host'`.
  - `class HostRegistry { HostRegistry(String path); Future<List<ModelHost>> load(); Future<void> save(List<ModelHost> hosts); }`
  - `List<String> validateHost(ModelHost h, List<ModelHost> others)` → human-readable problems, empty when valid.
  - `int nextLocalPort(List<ModelHost> hosts)` → `19931`, then the lowest free number above it.
  - `ModelHost? defaultLocalHost(Which which)` → `ModelHost(id: 'local', label: 'This machine', kind: local, serverPort: 9931)` when `llm-host` is on `PATH`, else `null`.

- [ ] **Step 1: Failing tests:**
  - `load returns [] when the file is missing`; `save then load round-trips`; save is atomic (temp file + rename) and creates the parent dir.
  - `load skips entries it cannot parse and keeps the rest`.
  - `baseUrl is always a 127.0.0.1 address` for both kinds.
  - `validateHost`: id must match `^[a-z0-9][a-z0-9-]{0,31}$` and be unique; `ssh` needs a non-empty `sshTarget` without spaces and not starting with `-`; `ssh` needs `localPort` in 1024–65535, unique among hosts and different from every `local` host's `serverPort`; `local` must have no `sshTarget`.
  - `nextLocalPort skips ports in use by other hosts`.
  - `defaultLocalHost is null when llm-host is not installed`.
- [ ] **Step 2:** `flutter test test/core/hosts_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): model host registry`.

### Task 8: Host client **[any]**

**Files:**
- Create: `lib/core/host_client.dart`
- Test: `test/core/host_client_test.dart` (uses the existing `test/support/fake_runner.dart`)

**Interfaces:**
- Consumes: `ModelHost` (Task 7); existing `Runner`, `RunResult`. If `Runner.run` has no timeout parameter, add `Duration? timeout` (kill the process and return exit code `-1` on expiry) and update `IoRunner` and `FakeRunner`.
- Produces:
  - `enum ServerState { stopped, loading, ready, foreign, error }`
  - `class HostStatus { final ServerState state; final String? recipe; final String? label; final String? alias; final int? ctx; final int? maxOutput; final bool vision; final int port; final int? pid; final int? gpuUsedMib; final int? gpuTotalMib; final String? error; }`
  - `class Recipe { final String name; final String label; final int ctx; final int maxOutput; final bool vision; final String notes; final bool modelPresent; }`
  - `sealed class HostResult<T>`: `HostOk<T>(T value)`, `HostUnreachable<T>(String message)`, `HostFailed<T>(String message)`.
  - `class HostClient { HostClient({required Runner runner, required String sshExe, required String controlDir}); List<String> commandFor(ModelHost h, List<String> args); Future<HostResult<HostStatus>> status(ModelHost h); Future<HostResult<List<Recipe>>> recipes(ModelHost h); Future<HostResult<HostStatus>> start(ModelHost h, String recipe, {bool replace = false}); Future<HostResult<HostStatus>> stop(ModelHost h); Future<HostResult<String>> logTail(ModelHost h, {int lines = 80}); }`
  - `const kSshOptions = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=120'];`
- `commandFor`: `local` → `[h.llmHostCmd, ...args]`; `ssh` → `[sshExe, ...kSshOptions, '-o', 'ControlPath=$controlDir/%C', h.sshTarget!, '--', h.llmHostCmd, ...args]`. Recipe names are validated against `^[a-z0-9][a-z0-9._-]{0,63}$` before being placed on a command line.
- Timeouts: `status`, `recipes`, `logTail`, `stop` 25 s; `start` 330 s.
- Mapping: ssh exit 255 or timeout → `HostUnreachable` (message: last stderr line, or `no answer from <label>`); `llm-host` exit 127 / "command not found" → `HostFailed('llm-host is not installed on <label>: see docs/hosts.md')`; `start` exit 3 → `HostOk` with `state == error` (the log tail travels in `error`); exits 4, 5, 6 → `HostFailed` with `already running`, `a llama-server not started by llm-host is using port N`, `unknown recipe or missing model file`; non-JSON stdout or `schema != 1` → `HostFailed('llm-host on <label> answered in an unknown format: update it')`.

- [ ] **Step 1: Failing tests:**
  - `commandFor local has no ssh`; `commandFor ssh puts options before the target and -- before the command`.
  - `status parses every field`, including `gpu: null` → both gpu fields null.
  - `ssh exit 255 maps to HostUnreachable`; `timeout maps to HostUnreachable`.
  - `missing llm-host maps to HostFailed with the docs hint`.
  - `start exit 3 returns HostOk with state error and the log tail`.
  - `start exits 4, 5, 6 map to their messages`; `start passes --replace only when asked`.
  - `recipes parses the list and ignores the invalid array`.
  - `a recipe name with a space or a semicolon is rejected before any process runs` (`FakeRunner` records zero calls).
  - `unknown schema maps to HostFailed`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): host client over local exec and ssh`.

### Task 9: SSH forward supervisor **[any]**

**Files:**
- Create: `lib/core/tunnel.dart`
- Test: `test/core/tunnel_test.dart`

**Interfaces:**
- Consumes: `ModelHost` (Task 7).
- Produces:
  - `abstract class Proc { Future<int> get exitCode; Stream<String> get stderrLines; void kill(); }`, `typedef ProcStarter = Future<Proc> Function(String exe, List<String> args);`, `Future<Proc> startIoProc(String exe, List<String> args)`.
  - `typedef PortProbe = Future<bool> Function(int port);` (true when a TCP connect to `127.0.0.1:port` succeeds), `Future<bool> tcpProbe(int port)`.
  - `enum TunnelPhase { down, connecting, up }`, `class TunnelState { final TunnelPhase phase; final String? error; }`
  - `const kTunnelBackoff = [1, 2, 4, 8, 15];` (seconds; the last value repeats)
  - `class TunnelManager { TunnelManager({required ProcStarter start, required PortProbe probe, required String sshExe, Duration Function(int attempt)? delay}); List<String> argsFor(ModelHost h); TunnelState stateOf(String hostId); Stream<String> get changes; Future<void> ensure(ModelHost h); Future<void> close(String hostId); Future<void> dispose(); }`
- `argsFor`: `['-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', '-o', 'ControlPath=none', '-L', '127.0.0.1:${h.localPort}:127.0.0.1:${h.serverPort}', h.sshTarget!]`.
- `ensure` on a `local` host does nothing and reports `up`. On an `ssh` host: if the phase is `up` or `connecting`, return; else start the process, poll `probe(localPort)` every 250 ms for up to 10 s → `up`. When the process exits, the phase becomes `down` and a restart is scheduled after `kTunnelBackoff[min(attempt, 4)]` seconds; the attempt counter resets after the tunnel has been `up` for 30 s. `close` stops restarts and kills the process.
- Errors: a stderr line containing `Address already in use` → `error: 'port <localPort> is already in use on this machine'` and **no** restart; `Permission denied` → `error: 'SSH key not accepted by <sshTarget>'`, no restart; anything else → last stderr line, restarts continue.

- [ ] **Step 1: Failing tests** (fake `Proc`, fake probe, `delay` injected so no real waiting):
  - `ensure on a local host starts nothing`.
  - `argsFor binds 127.0.0.1 on both sides`.
  - `phase goes connecting then up once the probe succeeds`.
  - `ensure twice starts one process`.
  - `tunnel restarts after the process exits`.
  - `backoff is 1,2,4,8,15,15` (recorded delays over six consecutive failures).
  - `attempt counter resets after 30 s up`.
  - `port in use stops retrying and names the port`.
  - `permission denied stops retrying`.
  - `close kills the process and cancels the pending restart`; `dispose closes all`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): supervised ssh forward per remote host`.

### Task 10: Local config writers **[any]**

**Files:**
- Create: `lib/core/local_config.dart`
- Test: `test/core/local_config_test.dart`

**Interfaces:**
- Consumes: existing `AgentKind`, `RealConfigGuard`; `docs/local-wire-notes.md` (Task 2) for any key the notes corrected — **the notes win over the values below where they differ**, and the test is updated to match.
- Produces:
  - `class LocalTarget { final String baseUrl; final String alias; final String hostLabel; final int ctx; final int maxOutput; final bool vision; }`
  - `const kMinCtx = {AgentKind.pi: 16384, AgentKind.opencode: 24576, AgentKind.claude: 32768};`
  - `const kLocalAgents = [AgentKind.pi, AgentKind.opencode, AgentKind.claude];`
  - `String localDir(String dataRoot, String hostId, AgentKind k)` → `'$dataRoot/local/$hostId/${k.name}'`
  - `Map<String, dynamic> piModels(LocalTarget t)`, `Map<String, dynamic> piSettings(LocalTarget t)`, `Map<String, dynamic> opencodeConfig(LocalTarget t)`, `Map<String, String> claudeLocalEnv(LocalTarget t, String dir)`, `List<String> claudeLocalArgs()`
  - `Map<String, String> overrideEnv(AgentKind k, String dir)` → pi `{PI_CODING_AGENT_DIR: dir}`, opencode `{OPENCODE_CONFIG: '$dir/opencode.jsonc'}`, claude `{CLAUDE_CONFIG_DIR: dir}`
  - `Future<void> writeLocalConfig(AgentKind k, LocalTarget t, String dir, {required List<String> guardedRoots})`
- Values:
  - `piModels`: provider key `local`, `name: t.hostLabel`, `baseUrl: '${t.baseUrl}/v1'`, `api: 'openai-completions'`, `apiKey: 'local'`, one model `{id: t.alias, reasoning: false, input: ['text'] (+ 'image' when vision), contextWindow: t.ctx, maxTokens: t.maxOutput, cost: all zero}`.
  - `piSettings`: `compaction: {enabled: true, reserveTokens: t.maxOutput + 2048, keepRecentTokens: t.ctx ~/ 4}`, plus the default-model key found in Task 2 (Step 3 b).
  - `opencodeConfig`: as in `harness-configs.md` § OpenCode with `model: 'local/${t.alias}'`, `settings.baseURL: '${t.baseUrl}/v1'`, `headerTimeout: 600000`, `limit: {context: t.ctx, output: t.maxOutput}`, `compaction: {auto: true, buffer: '25%', keep: {tokens: t.ctx * 3 ~/ 16}}`, `tool_output: {max_lines: 400, max_bytes: 16384}`; no `permissions` block.
  - `claudeLocalEnv`: `CLAUDE_CONFIG_DIR: dir`, `ANTHROPIC_BASE_URL: t.baseUrl` (no `/v1`), `ANTHROPIC_API_KEY: 'local'`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL` all `t.alias`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS: '${t.ctx}'`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS: '${t.maxOutput}'`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1'`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: '1'`, `CLAUDE_CODE_ATTRIBUTION_HEADER: '0'`, `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT: '1'`, `NO_PROXY: '127.0.0.1,localhost'`, plus any `DISABLE` variable Task 2 found necessary.
  - `claudeLocalArgs`: `['--bare', '--tools', 'Bash,Read,Edit']`.
  - `writeLocalConfig`: pi writes `models.json` and `settings.json` (preserving keys the user added that the app does not own); opencode writes `opencode.jsonc`; claude only creates the directory. Every write is temp file + rename; a symlink at the target is deleted, never followed.

- [ ] **Step 1: Failing tests:**
  - `pi models at 32768/4096`: `contextWindow == 32768`, `maxTokens == 4096`, `baseUrl == 'http://127.0.0.1:9931/v1'`, model id equals the alias; `input` contains `image` only when `vision`.
  - `pi compaction at 32768/4096`: `reserveTokens == 6144`, `keepRecentTokens == 8192`.
  - `opencode limits and caps`: `limit.context == 32768`, `limit.output == 4096`, `compaction.keep.tokens == 6144`, `tool_output.max_bytes == 16384`, `model == 'local/qwen36-35b-32k'`.
  - `claude env points at the target and nowhere else`: `ANTHROPIC_BASE_URL == 'http://127.0.0.1:19931'`; no `ANTHROPIC_AUTH_TOKEN`; the five model variables equal the alias.
  - `writeLocalConfig refuses a dir under a guarded root`: `dir` inside `<fakeHome>/.claude`, `.pi`, or `.config/opencode` → `StateError`, nothing written.
  - `writeLocalConfig replaces a symlinked models.json without touching its target`.
  - `rewriting pi settings keeps a user-added key and updates compaction`.
  - `two hosts get two directories` (`localDir` differs by `hostId`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): generated agent configs for local model hosts`.

### Task 11: Local profiles and launch **[any]**

**Files:**
- Modify: `lib/core/profiles.dart`, `lib/core/launch.dart`, `lib/core/guard.dart`
- Test: `test/core/launch_local_test.dart`; extend `test/core/guard_test.dart`

**Interfaces:**
- Consumes: `ModelHost` (7), `HostStatus`, `ServerState` (8), `LocalTarget`, `kMinCtx`, `kLocalAgents`, `localDir`, `overrideEnv`, `claudeLocalEnv`, `claudeLocalArgs`, `writeLocalConfig` (10); existing `Profile`, `Backend`, `LaunchSpec`, `buildLaunch`, `kStrippedEnvKeys`.
- Produces:
  - `Backend.local` added to the enum; `Profile` gains `final String? hostId;`.
  - `List<Profile> localProfiles(List<ModelHost> hosts)` → for each host and each of `kLocalAgents`: id `'${kind.name}-${host.id}'`, label `'Pi · ${host.label}'` / `'OpenCode · …'` / `'Claude · …'`.
  - `sealed class LocalReadiness`: `LocalReady(LocalTarget target)`, `LocalBlocked(String reason)`.
  - `LocalReadiness localReadiness(AgentKind k, ModelHost h, HostStatus? s)` — reasons, exact text: `null` status → `'<label> is unreachable'`; `stopped` → `'No model is running on <label>: start one'`; `loading` → `'<label> is loading <recipe label>…'`; `foreign` → `'A llama-server not started by AI App is running on <label>'`; `error` → `'The model failed to start on <label>: open the log'`; ready but `ctx < kMinCtx[k]` → `'<Agent> needs a <min>-token window; <recipe label> has <ctx>'`.
  - `Future<LaunchSpec> buildLocalLaunch(Profile p, {required ModelHost host, required LocalTarget target, required String dataRoot, required Map<String, String> parentEnv, required String exePath, required String cwd, required String toolsBinDir, required List<String> guardedRoots})` — writes the config (`writeLocalConfig`), then returns the spec: parent env minus `kStrippedEnvKeys` and every `ANTHROPIC_*`, plus `overrideEnv`, plus `claudeLocalEnv` for Claude, `PATH` prefixed with `toolsBinDir`; args `claudeLocalArgs()` for Claude, empty otherwise. No `ALCF_SESSION_ID`.
  - `RealConfigGuard.defaultPaths` gains `'$h/.pi/agent/settings.json'`.

- [ ] **Step 1: Failing tests:**
  - `localProfiles builds three profiles per host with stable ids`.
  - `localReadiness` returns each blocked reason verbatim, and `LocalReady` with `ctx`, `maxOutput`, `alias`, `baseUrl` taken from status and host.
  - `open is refused below the agent minimum`: ready at `ctx 24576` → Pi and OpenCode ready, Claude blocked.
  - `local claude env never contains an inherited ANTHROPIC key`: parent env has `ANTHROPIC_API_KEY=real`, `ANTHROPIC_BASE_URL=https://api.anthropic.com`, `CLAUDE_CONFIG_DIR=/h/.claude-alt`, `CLAUDE_CODE_OAUTH_TOKEN=t` → spec has `ANTHROPIC_API_KEY == 'local'`, base URL `http://127.0.0.1:…`, `CLAUDE_CONFIG_DIR` under `dataRoot`, no OAuth token.
  - `pi and opencode specs carry only their own override`, never `ANTHROPIC_*`.
  - `PATH starts with toolsBinDir and keeps the parent PATH`; `HOME` unchanged.
  - `buildLocalLaunch writes the config before returning` (file exists with the target's `ctx`).
  - `ALCF and native profiles build exactly as before` (existing launch tests still pass unchanged).
  - `defaultPaths lists the seven guarded files`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `flutter test`. Expected: PASS, including every pre-existing test.
- [ ] **Step 5:** Commit `feat(core): local profiles, readiness and launch`.

---

## Phase 4 — UI

### Task 12: Host tiles and model control **[any]**

**Files:**
- Modify: `lib/app/app_state.dart`, `lib/ui/sidebar.dart`, `lib/ui/home_page.dart`, `lib/main.dart`
- Create: `lib/ui/host_tile.dart`, `lib/ui/log_dialog.dart`
- Test: `test/ui/host_tile_test.dart`; extend `test/ui/home_page_test.dart`

**Interfaces:**
- Consumes: Tasks 7–11.
- Produces: `AppState` gains `List<ModelHost> hosts`, `HostStatus? statusOf(String hostId)`, `String? unreachableReason(String hostId)`, `List<Recipe> recipesOf(String hostId)`, `TunnelState tunnelOf(String hostId)`, `Future<void> refreshHost(String hostId)`, `Future<String?> startModel(String hostId, String recipe)` (returns an error text or null), `Future<String?> stopModel(String hostId)`, `int openTabsOn(String hostId)`, `Future<String?> openLocal(Profile p, String cwd)`; constructor takes `HostRegistry`, `HostClient`, `TunnelManager`, `String dataRoot`.
- Polling: each host every 5 s, every 2 s while `loading`; `ssh` hosts get `tunnel.ensure` first. Polling stops when the window is disposed.
- `openLocal`: `refreshHost` → `localReadiness` → blocked: return the reason; ready: guard snapshot → `buildLocalLaunch` → guard `changedSince` (non-empty → return `'A real config file changed: <paths>'` and do not open) → open the tab.

Sidebar layout: section `ALCF` (existing), one section per host, section `Native` (existing). A host section is a `HostTile` followed by its three profile rows.

`HostTile` content: status dot (grey unreachable or stopped, amber loading, green ready, red error or foreign); label; second line the recipe label when ready, the blocked reason otherwise; third line `<ctx/1024>K window · VRAM 9.8 / 12.0 GB` when ready (the VRAM part only when known); a recipe menu (`Start` when stopped, `Switch model` when ready; recipes with `modelPresent == false` disabled with tooltip `model file missing on <label>`); `Stop`; `Log`. Stop and the menu are disabled for `foreign` and unreachable.

- [ ] **Step 1: Failing widget tests:**
  - `ready host shows model, context and VRAM`: finds `Qwen3.6 35B-A3B · 32K` (the recipe label) and `32K window · VRAM 9.8 / 12.0 GB`; with `gpu` null, finds `32K window` alone.
  - `unreachable host greys its three profiles and shows the reason`.
  - `stopped host offers Start with the recipe list`; choosing one calls `startModel(hostId, name)`.
  - `recipe with a missing model file is disabled`.
  - `switching with open tabs asks first`: `openTabsOn == 2` → dialog `2 open tabs use <label>. They will lose their model.` with Cancel / Switch; Cancel calls nothing.
  - `start failure shows the log tail`: `startModel` returns text → a dialog with that text in a monospace, selectable box.
  - `foreign server disables Stop and the menu` and shows the foreign reason.
  - `Log opens the tail` from `logTail`.
  - `a blocked profile shows its reason as a tooltip and does not open a tab`; a ready one opens a tab titled `Pi · <label>`.
  - `Claude profile is blocked at a 24576 window while Pi is not`.
  - `existing ALCF and Native sections are unchanged` (existing home-page tests pass).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. `main.dart`: `dataRoot = '$realHome/.local/share/ai-app'`, registry at `'$realHome/.config/ai-app/hosts.json'`; on first run with an empty registry, add `defaultLocalHost(which)` if non-null and save; `controlDir = '$dataRoot/ssh'` created with mode 700; `sshExe` from `whichOnPath('ssh')`, and when it is missing `ssh` hosts show `ssh is not installed`.
- [ ] **Step 4:** `flutter test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(ui): model host tiles with start, switch, stop and log`.

### Task 13: Add / edit / remove a host **[any]**

**Files:**
- Create: `lib/ui/host_dialog.dart`
- Modify: `lib/ui/sidebar.dart` (an `Add host` button under the last host section; an edit icon on each tile), `lib/app/app_state.dart`
- Test: `test/ui/host_dialog_test.dart`

**Interfaces:**
- Consumes: `validateHost`, `nextLocalPort`, `HostRegistry` (7), `HostClient.status` (8), `TunnelManager` (9).
- Produces: `AppState.saveHost(ModelHost h, {String? replacingId})`, `AppState.removeHost(String id)` (closes its tunnel; refuses while `openTabsOn(id) > 0`, returning `'Close the <n> tabs using <label> first'`); `Future<String> testHost(ModelHost h)` → one line: `ready: <recipe label>`, `reachable, no model running`, or the unreachable / failed message.

Dialog fields: Label; Kind (`This machine` / `Over SSH`); SSH target (shown for SSH; hint `user@pc or an ~/.ssh/config name`); Server port (default `9931`); Local port (SSH only, prefilled with `nextLocalPort`); `Test` button; Save disabled while `validateHost` returns problems (listed under the fields). The id is derived from the label (lowercase, non-alphanumerics → `-`) on creation and never changes on edit.

- [ ] **Step 1: Failing widget tests:**
  - `SSH fields appear only for Over SSH`.
  - `local port is prefilled with the next free port`.
  - `Save is disabled and the problem is listed for a duplicate label, an empty SSH target, a target starting with -`.
  - `Test shows the one-line result` for each of the three outcomes.
  - `saving a new host adds its section with three profiles`.
  - `editing keeps the id and its sandbox directory`.
  - `remove is refused while tabs are open, with the message`; otherwise the section disappears and the registry file no longer lists it.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `flutter test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(ui): add, edit and remove model hosts`.

---

## Phase 5 — Web reading

### Task 14: `webread`, wired into Pi and Claude Code **[any]**

**Files:**
- Create: `tools/webread` (Python, stdlib), `tools/tests/test_webread.py`, `assets/pi/web_read.ts`
- Modify: `scripts/install-linux.sh` (copy `tools/webread` to `~/.local/share/ai-app/bin/`, mode 755), `lib/core/local_config.dart` (`claudeLocalArgs`), `pubspec.yaml` (asset)
- Test: extend `test/core/local_config_test.dart`

**Interfaces:**
- Produces:
  - CLI `webread URL [--max-chars N=12000]`: `http`/`https` only; 20 s timeout; at most 5 redirects; reads at most 2 MB; `text/html` → title line, blank line, visible text (script, style, nav, svg dropped; block elements become line breaks; runs of blank lines collapsed); `text/*` and `application/json` → as is; other types → `webread: cannot read <content-type>` and exit 2. Output longer than `N` → first `N*2/3` characters, a line `[... <k> characters omitted ...]`, last `N/3` characters. Fetch failure → one line `webread: <reason>` on stderr, exit 2. User-Agent `ai-app-webread/1`.
  - `claudeLocalArgs()` becomes `['--bare', '--tools', 'Bash,Read,Edit', '--append-system-prompt', 'To read a web page, run: webread <url>']` — **only if** Task 2 recorded that `--append-system-prompt` works with `--bare`; otherwise leave the args unchanged and document `webread` in the README for Claude Code.
  - `assets/pi/web_read.ts`: registers a Pi tool `web_read` with one string parameter `url`, which runs `webread <url>` and returns its stdout (stderr on failure), using the `registerTool` signature recorded in Task 2. `writeLocalConfig` copies it to `<dir>/extensions/web_read.ts`.
  - OpenCode: nothing; its built-in fetch stays, bounded by `tool_output`.

- [ ] **Step 1: Failing tests** (`python3 -m unittest discover tools/tests -v`; pages served by a local `http.server` on a free port):
  - `test_html_becomes_text_with_title`: script and style content absent, paragraph text present, first line is the title.
  - `test_long_page_is_capped`: output length ≤ `max_chars` + 60, contains `characters omitted`, starts with the page's start and ends with its end.
  - `test_non_http_scheme_is_refused`: `file:///etc/passwd` → exit 2.
  - `test_binary_content_is_refused`: `image/png` → exit 2, message names the type.
  - `test_http_error_is_one_line`: 404 → exit 2, single stderr line.
  - `test_redirect_loop_stops`: exit 2.
  - `test_charset_from_header_and_meta`: an ISO-8859-1 page prints `é` correctly.
- [ ] **Step 2:** Dart: `pi config contains the web_read extension` (file exists under `extensions/` after `writeLocalConfig`); `claude args` match the form chosen above.
- [ ] **Step 3:** Run both suites. Expected: FAIL.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run. Expected: PASS.
- [ ] **Step 6:** Commit `feat(tools): webread, shared page reader for local agents`.

---

## Phase 6 — Network and end-to-end

### Task 15: SSH and Tailscale between laptop and PC **[PC + laptop]**

**Files:**
- Modify (laptop, not in git): `~/.ssh/config`
- Modify: `docs/hosts.md` (network section), the machine file

- [ ] **Step 1 [PC, sudo: user]:** `sudo apt install openssh-server`; in `/etc/ssh/sshd_config.d/10-ai-app.conf`: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`; `sudo systemctl enable --now ssh`.
- [ ] **Step 2 [PC + laptop, sudo: user]:** install Tailscale from its official apt repository on both, `sudo tailscale up` (the user signs in; same account on both). Expected: `tailscale status` lists both machines. Note the PC's Tailscale name.
- [ ] **Step 3 [laptop]:** create a dedicated key `ssh-keygen -t ed25519 -f ~/.ssh/id_ai_app -C ai-app` **[user chooses the passphrase; with one, it must be in the ssh-agent, since the app uses `BatchMode`]**; append the public key to `~/.ssh/authorized_keys` on the PC.
- [ ] **Step 4 [laptop]:** `~/.ssh/config` entry:

  ```
  Host pc
      HostName <PC Tailscale name>
      User corentin
      IdentityFile ~/.ssh/id_ai_app
      IdentitiesOnly yes
  ```

  Connect once by hand to accept the host key: `ssh pc hostname`. Expected: `corentin-MS-7B86`.
- [ ] **Step 5: Verify:**
  - `ssh -o BatchMode=yes pc -- llm-host status --json` → valid JSON. If `llm-host` is not found, the non-interactive `PATH` lacks `~/.local/bin`: set the host's `llmHostCmd` to `/home/corentin/.local/bin/llm-host` and say so in `docs/hosts.md`.
  - `ssh -N -L 127.0.0.1:19931:127.0.0.1:9931 pc &` then, with a model running, `python3 -I <skill>/scripts/llm_probe.py --url http://127.0.0.1:19931` → all PASS; compare prefill and generation tok/s with Task 1 (expect within a few percent). Kill the forward.
  - From the PC: `ss -ltnp | grep -E ':(22|9931)\b'` → sshd on all interfaces, llama-server on `127.0.0.1` only.
  - From a phone hotspot (laptop off the home network): repeat the first check. Expected: same answer; `tailscale status` shows `direct` or `relay`.
- [ ] **Step 6:** Record in `docs/hosts.md` and in the machine file (SSH + Tailscale installed, date). Commit both repos; push `claude_config`.

### Task 16: End-to-end on the PC (host `local`) **[PC]**

**Files:**
- Create: `docs/e2e-local-<date>.md`
- Modify: the machine file

- [ ] **Step 1 [sudo: user for apt]:** Flutter on the PC: clone the stable channel at 3.47.7 into `~/Software/flutter`; build dependencies `clang cmake ninja-build pkg-config libgtk-3-dev` (check free space on `/` first with `df -h /`; stop if under 3 GB). `flutter doctor` → Linux toolchain OK.
- [ ] **Step 2:** In `~/Software/ai-app`: `flutter test` (all pass), `python3 -m unittest discover host/tests`, `python3 -m unittest discover tools/tests`, then `scripts/install-linux.sh`.
- [ ] **Step 3: Record hashes:** `sha256sum ~/Software/claude_config/claude/settings.json` and, if they exist, `~/.pi/agent/models.json`, `~/.pi/agent/settings.json`, `~/.config/opencode/opencode.jsonc`.
- [ ] **Step 4: Manual run**, results in the e2e file:
  1. Launch AI App. Expected: a section "This machine", state stopped, recipes listed.
  2. Start `qwen36-35b-32k`. Expected: amber then green, `32K window`, VRAM line; note the load time.
  3. Open `Pi · This machine` in a scratch checkout; ask it to add a function and run the tests. Expected: structured tool calls, no `<tool_call>` text. Note first-turn `prompt_n` and second-turn `cache_n` from `llm-host log`.
  4. Same with `OpenCode · This machine`, then `Claude · This machine`.
  5. In Pi: "read https://example.com and tell me the title". Expected: the `web_read` tool is called.
  6. Switch to `gptoss-20b-32k` with a tab open. Expected: the warning; after confirming, a new Pi tab shows the new model name.
  7. Stop the model; start a llama-server by hand. Expected: tile shows the foreign reason, Stop disabled. Kill it by hand.
  8. Unplug the network. Expected: everything above still works (offline use).
  9. Repeat Step 3's hashes. Expected: identical.
- [ ] **Step 5:** Append the numbers to the machine file's Measurements. Commit the e2e file; commit and push `claude_config`.

### Task 17: End-to-end from the laptop (host `pc`), failure drills, docs **[laptop]**

**Files:**
- Create: `docs/e2e-remote-<date>.md`
- Modify: `README.md`, `docs/hosts.md`
- Modify in `claude_config`: `memory/-home-ravoux-Documents-Python/project_alcfai_app.md`, `dotfiles/local-llm/profile.md`, `dotfiles/local-llm/notes.md`

- [ ] **Step 1:** Install the new build on the laptop (`scripts/install-linux.sh`); install Pi and OpenCode there if missing. Record the hashes of the six guarded files plus `~/.pi/agent/settings.json`.
- [ ] **Step 2:** `Add host`: label `PC`, Over SSH, target `pc`, ports `9931` / `19931`. `Test` → `ready: …` or `reachable, no model running`.
- [ ] **Step 3: Manual run**, results in the e2e file:
  1. Start a model from the laptop. Expected: same tile behaviour as on the PC.
  2. Open `Pi · PC` in `~/Documents/Python/<a project>`: the agent edits **laptop** files. Run `ss -ltn | grep 19931` → bound to `127.0.0.1`.
  3. Open `Claude · PC` and `Claude · Pro` side by side. Expected: the first reports the local model, the second the Anthropic login; neither changes the other.
  4. Open `Claude · ALCF`. Expected: works as before the rename.
  5. **Drill — link drop:** turn Wi-Fi off for 30 s during a Pi turn. Expected: the tile turns unreachable in under ~25 s; the agent shows a connection error, not a hang; after Wi-Fi returns the tile is green within ~20 s and a retried prompt works in the same tab.
  6. **Drill — server stopped under a tab:** stop the model from the tile. Expected: the next agent request fails at once; the profile rows show `No model is running on PC: start one`.
  7. **Drill — port taken:** `python3 -m http.server 19931 --bind 127.0.0.1`, restart the app. Expected: `port 19931 is already in use on this machine`, no retry storm (`pgrep -fc 'ssh -N'` stays 0).
  8. **Drill — away from home:** repeat item 2 from a phone hotspot. Note generation tok/s seen in the tab against the PC's own number.
  9. Repeat Step 1's hashes. Expected: identical.
- [ ] **Step 4:** README: what the app is now (three backends), the diagram from the design, install on a client, install on a host (link `docs/hosts.md`), the "offline means at the host" note, the web-plus-shell caution.
- [ ] **Step 5:** `claude_config`: rewrite the app memory (name, local hosts, `llm-host`, where recipes and sandboxes live, "never run local agents against `~/.claude`"); in the local-llm layer, note in `profile.md` that the server on a model host is owned by `llm-host` and agents are launched through AI App, and in `notes.md` under `## harness-configs#…` any config key Task 2 corrected. Commit and push.
- [ ] **Step 6:** Commit the app repo: `docs: remote e2e record and host guide`. Tell the user the branch is ready to push.

---

## Later (not in this plan)

- Remote wake-up (needs an always-on device at home).
- Qwen Code and mini-swe-agent profiles; a web search tool.
- Tool-result shortening for Pi (the Lewis policy through the `context` extension hook), once the baseline is measured.
- A per-host "Probe" button running `llm_probe.py`.
- Sharing a trimmed `CLAUDE.md` with local Claude Code if a larger window becomes available (mini PC).
