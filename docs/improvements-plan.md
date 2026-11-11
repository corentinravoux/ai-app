# AI App Round 2 Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry the repo rename through, fix every deferred review finding, close the project-override hole, make the client portable to macOS and Windows with CI builds, add a server probe, and record two measurements, all without a user step.

**Architecture:** Same split as before: `host/llm_host.py` (stdlib Python) on model hosts, pure-Dart core in `lib/core`, Flutter UI in `lib/ui`. Portability goes through one new module, `lib/core/platform_paths.dart`, so no other file tests `Platform.isX`.

**Tech Stack:** Flutter 3.47.7 / Dart 3.13.5; Python ≥ 3.11 stdlib; GitHub Actions (`subosito/flutter-action@v2`).

**Spec:** [improvements-design.md](improvements-design.md)

## Global Constraints

- Branch `local-hosts` in `~/Software/ai-app`; commit locally, never push.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Linux behaviour unchanged except where a task says so; all existing tests keep passing.
- Tests never touch the real home; Python tests never start a real llama-server.
- macOS/Windows code is compiled by CI only: every such change keeps the Linux build and tests green and is marked untested in the README.
- llama-server binds 127.0.0.1 only; nothing new listens on the network.

## Review Focus

1. **A project folder that tries to redirect a local agent** (`.claude/settings.json` env, `opencode.json` provider): the tab must still talk to the host. Tests in Task 3.
2. **Windows PATH and executables** (`;` separator, `.cmd`/`.exe` via PATHEXT, no execute bits): `whichOnPath` finds `claude.cmd`; agent PATH joins with `;`. Tests in Task 5.
3. **A corrupt `hosts.json`**: the user's remote hosts must survive (backup), and "This machine" must not reappear after the user removed every host. Tests in Task 4.
4. **llm-host on macOS** (no `/proc`): ownership, zombie and stale-pidfile checks must work through `ps`. Tests in Task 2 force the `ps` path on Linux.
5. **Probe against a server that leaks tool markup as text**: probe reports the failure instead of passing. Test in Task 7.

---

### Task 1: Rename carried through, LICENSE, CI

**Files:** `.git/config` (remote), `LICENSE`, `.github/workflows/ci.yml`, `README.md` (links only here), claude_config `memory/-home-ravoux-Documents-Python/project_ai_app.md`.

- [ ] `git remote set-url origin git@github.com:corentinravoux/ai-app.git`; `git ls-remote origin HEAD` succeeds.
- [ ] `grep -rn 'alcfai-app' --exclude-dir=.git --exclude-dir=build --exclude-dir=.dart_tool .` → only historical docs (`docs/e2e-*`, `docs/local-hosts-*`) and the old-install cleanup in `install-linux.sh`.
- [ ] `LICENSE`: MIT, "Copyright (c) 2026 Corentin Ravoux".
- [ ] `ci.yml`, on push and pull_request:
  - `linux` (ubuntu-latest): apt `clang cmake ninja-build pkg-config libgtk-3-dev`; Flutter 3.47.7; `flutter analyze`, `flutter test`, `flutter build linux --release`; `python3 -m unittest discover -s host/tests -t .` and `-s tools/tests`.
  - `macos` (macos-latest): Flutter 3.47.7; `flutter build macos --release`; the two Python suites (exercises llm-host's `ps` path for real).
  - `windows` (windows-latest): Flutter 3.47.7; `flutter build windows --release`.
- [ ] Commit `chore: ai-app remote, MIT license, CI on Linux/macOS/Windows`.

### Task 2: llm-host fixes and macOS support

**Files:** `host/llm_host.py`, `host/tests/test_lifecycle.py`, `host/tests/test_recipes.py`, `host/tests/fake_llama_server.py`.

**Interfaces:** `process_argv(pid) -> list[str] | None` and `process_state(pid) -> str | None` (`/proc` when present, else `ps -o command= / -o stat= -p PID`); `compute_status(cfg, gpu=True)`.

- [ ] Failing tests:
  - `test_status_ctx_is_null_when_props_fails` (`FAKE_NO_PROPS=1` → `ctx is None`; Dart already blocks a null window).
  - `test_fixed_flags_come_last` (`build_command` ends with `--host 127.0.0.1 --port N`; `-m`, `--alias`, `-c` come after the recipe args too).
  - `test_more_download_flags_are_forbidden` (`-hfr`, `--hf-repo-draft`, `-mu`, `--model-url`, `-dr`, `--docker-repo` rejected).
  - `test_start_loop_skips_gpu_query` (`compute_status(cfg, gpu=False)["gpu"] is None` with a fake `nvidia-smi` on PATH that would answer).
  - `test_ps_fallback_matches_proc` (with `/proc` lookup disabled by `LLM_HOST_NO_PROC=1`, `process_argv` and `process_state` of the test process agree with `/proc`; ownership, foreign and stop tests rerun under the flag).
  - Test hygiene: `free_port()` retries on bind failure; tearDown also kills any process whose argv contains this test's temp dir.
- [ ] Implement; run the suite three times; commit `fix(host): props-less ctx, fixed flags last, no GPU query in the start loop, macOS ps path`.

### Task 3: Local tabs cannot be redirected by a project

**Files:** `lib/core/local_config.dart`, `lib/core/local_launch.dart`, tests.

- [ ] Failing tests:
  - `claude args include --setting-sources user` (exact list: `--bare`, `--setting-sources`, `user`, `--tools`, `Bash,Read,Edit`, `--append-system-prompt`, `To read a web page, run: webread <url>`).
  - `opencode env disables project config` (`OPENCODE_DISABLE_PROJECT_CONFIG=1`, `OPENCODE_DISABLE_AUTOUPDATE=1`, `OPENCODE_DISABLE_MODELS_FETCH=1` in the OpenCode spec only).
  - `local tabs drop cloud-provider switches` (parent env with `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`, `AWS_BEARER_TOKEN_BEDROCK` → absent in every local spec; still present in a native spec).
- [ ] Implement (`kLocalStrippedEnvKeys` in `local_launch.dart`); verify by hand with the hijacking project folder against a live model; commit `fix(core): projects cannot redirect local Claude or OpenCode`.

### Task 4: App robustness leftovers

**Files:** `lib/core/runner.dart`, `lib/core/hosts.dart`, `lib/core/local_config.dart`, `lib/core/tunnel.dart`, `lib/app/app_state.dart`, `lib/ui/host_dialog.dart`, `lib/main.dart`, tests.

- [ ] Failing tests:
  - Runner: `malformed output does not throw` (`printf '\377ok'` → stdout contains `ok`); `a background grandchild does not hold a finished command` (`sh -c 'sleep 3 & echo hi'`: the grandchild keeps stdout open; the result `hi` comes back in < 1.5 s).
  - Registry: `a corrupt file is moved aside` (`hosts.json` → `hosts.json.corrupt-<n>`, `load` returns `[]`, `lastLoadRecovered` true); `seedLocalHost only when the file never existed` (`HostRegistry.exists` false → seed; an existing empty list → no seed).
  - Registry: `load skips hosts that fail validation` (a host whose `sshTarget` starts with `-` is dropped).
  - Tunnel: `ssh target comes after --` (`argsFor` ends with `'--', 'me@pc'`; OpenSSH stops option parsing at `--`).
  - Config writes: `two writes of the same file at once both succeed` (parallel `writeLocalConfig` × 2 on one dir).
  - AppState: `reopenLast reports a local tab that cannot open` (notice set); `openLocal turns a FileSystemException into a sentence`.
  - AppState: `testHost uses its own tunnel id and reports the forward` (an edited host's live tunnel is untouched; a failed forward → `reachable, but the tunnel failed: …`).
  - Dialog: `Test is disabled while problems are listed`; `new ssh host defaults to ~/.local/bin/llm-host`.
- [ ] Implement; `main.dart` uses `XDG_DATA_HOME`/`XDG_CONFIG_HOME` when set (as `install-linux.sh` does) and seeds "This machine" only when `hosts.json` does not exist; `install-host.sh` escapes `"` and `\` in TOML strings.
- [ ] Commit `fix: robustness leftovers from the first review`.

### Task 5: Portable client core

**Files:** create `lib/core/platform_paths.dart`; modify `lib/core/launch.dart`, `lib/core/local_launch.dart`, `lib/core/host_client.dart`, `lib/core/tunnel.dart`, `lib/ui/terminal_tab.dart`, `lib/main.dart`, `lib/app/app_state.dart`; tests `test/core/platform_paths_test.dart`.

**Interfaces:**
- `enum HostOs { linux, macos, windows }`, `HostOs currentOs()`.
- `String homeDir(Map<String, String> env, HostOs os)` (`HOME`, else `USERPROFILE` on Windows).
- `String pathSep(HostOs os)` (`;` on Windows).
- `String? whichOn(String exe, Map<String, String> env, HostOs os)` (Windows: tries `PATHEXT` extensions, no mode check).
- `List<String> openUrlCommand(String url, HostOs os)` (`xdg-open`, `open`, `rundll32 url.dll,FileProtocolHandler`).
- `bool supportsSshControlMaster(HostOs os)` (false on Windows: OpenSSH for Windows has no ControlMaster).
- `String dataHome(Map<String,String> env, HostOs os)`, `String configHome(...)` (XDG on Linux; `~/Library/Application Support` on macOS; `%APPDATA%` on Windows).
- `whichOnPath`, `agentPath` and the local PATH join delegate to these with `currentOs()`; their signatures stay.

- [ ] Failing tests for each function on all three `HostOs` values (pure string logic; Windows lookup uses a temp dir with `claude.cmd`).
- [ ] Implement; ALCF profiles report `Needs alcf-ai` on Windows (disabled) via `AppState.alcfAvailable`; `HostClient` drops the ControlMaster options when unsupported.
- [ ] Commit `feat(core): portable paths, lookup and links for macOS and Windows`.

### Task 6: macOS and Windows runners and installers

**Files:** `macos/` and `windows/` (from `flutter create --platforms=macos,windows --org dev.ravoux --project-name ai_app .`), `macos/Runner/*.entitlements`, `macos/Runner/Configs/AppInfo.xcconfig`, `windows/runner/main.cpp`, `scripts/install-macos.sh`, `scripts/install-windows.ps1`, `tools/webread.cmd`.

- [ ] Generate the runners; product name `AI App`, bundle id `dev.ravoux.aiApp`; App Sandbox **off** in both entitlements (the app starts shells and reads the home folder); Windows window title `AI App`.
- [ ] `install-macos.sh`: `flutter build macos --release`, copy `AI App.app` to `~/Applications`, install `webread` into the data folder's `bin/`.
- [ ] `install-windows.ps1`: `flutter build windows --release`, copy the Release folder to `%LOCALAPPDATA%\Programs\ai-app`, Start-menu shortcut, `webread` + `webread.cmd` into the data `bin\`.
- [ ] Linux: `flutter test` and `flutter build linux --release` still pass; commit `feat: macOS and Windows runners and install scripts (built by CI, untested)`.

### Task 7: llm-host probe and the Probe button

**Files:** `host/llm_host.py` (`probe`), `host/tests/test_probe.py`, `host/tests/fake_llama_server.py` (chat + messages endpoints), `lib/core/host_client.dart` (`probe`), `lib/app/app_state.dart` (`probeHost`), `lib/ui/host_tile.dart` (button), tests.

**Interfaces:** CLI `llm-host probe [--json]` → `{"schema":1,"ok":bool,"checks":[{"name","ok","detail"}]}`, exit 0 all ok, 3 a check failed, 1 server not ready. Checks: `tool_call` (structured call, JSON arguments, no tool markup in text), `anthropic` (`/v1/messages` 200), `generation` (tok/s from `timings.predicted_per_second`, informational). Dart: `Future<HostResult<List<ProbeCheck>>> probe(ModelHost)`, `ProbeCheck {name, ok, detail}`; timeout 180 s.
- [ ] Failing tests: `probe passes on a well-behaved server`; `probe fails when the tool call leaks as text` (`FAKE_TOOL_AS_TEXT=1`); `probe on a stopped server exits 1`; Dart parse test; widget test `Probe shows each check`.
- [ ] Implement; commit `feat: llm-host probe and a Probe button`.

### Task 8: Measurements (vision recipe, full local Claude)

**Files:** `~/.config/llm-host/recipes/qwen36-35b-64k-vision.toml` (host-local), claude_config machine file, `docs/local-wire-notes.md`.

- [ ] Vision: Qwen3.6 + `mmproj-F16.gguf` at 64K, `--n-cpu-moe` 20/22; keep the setting that loads with ≥ 0.5 GB free; `llm-host probe` passes; an image prompt answers. Write the recipe if it works, else record why not.
- [ ] Full Claude prompt size: `claude -p` without `--bare`, with `CLAUDE.md`, commands and skills linked into a scratch config dir, against the 128K recipe; record first-turn `prompt_n`. Decision rule for next-steps: offer "full" when window ≥ 2 × that size.
- [ ] Restore the model that was running before (none: leave stopped). Commit docs.

### Task 9: README, docs, memory

- [ ] README rewritten for three audiences in this order: what it is (one screen), install per OS (Linux tested; macOS/Windows built by CI, untested), first use (ALCF, model hosts, accounts), model hosts in depth, safety model, files, troubleshooting, development (tests, CI, layout). Links to `docs/hosts.md`, `docs/local-wire-notes.md`.
- [ ] claude_config: memory and local-llm layer updated; push.
- [ ] Final whole-branch review; fix Critical/Important; ledger the rest.
