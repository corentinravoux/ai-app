# Round 2 review minors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the minor findings the round 2 review left deferred (ledger `.superpowers/sdd/improvements-plan/progress.md`, lines `Final: minor (deferred)`).

**Architecture:** Unchanged. Changes stay inside `host/llm_host.py`, `lib/core/hosts.dart`, `lib/core/local_launch.dart`, `lib/core/pi_extension.dart`, `tools/webread.cmd`, `lib/main.dart`.

**Spec:** [improvements-design.md](improvements-design.md) (anti-goals still apply) and the review findings quoted per task.

## Global Constraints

- Branch `review-minors` from `main` (f3a0370); merge into `main` and push at the end (the user asked for main to be updated directly).
- Linux behaviour unchanged except as stated; all suites stay green.
- Windows-only changes cannot run here: they are checked by reading, and stay marked untested.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Do not touch `~/Software/claude_env` (user rule); run Python tests with `/usr/bin/python3`.

## Review Focus

1. A recipe that sets a download or token flag under a spelling the installed llama-server accepts: rejected. Test in Task 1.
2. A model that thinks for a while before calling the tool: probe still passes. Test in Task 1.
3. A user who edits `hosts.json` by hand and makes one entry invalid: the entry survives in a backup and the app says so. Test in Task 2.

---

### Task 1: llm-host forbidden flags and probe robustness

Findings: `-hfr` is an alias of `--hf-repo` (not the draft); draft repo `-hfd`/`-hfrd`/`--spec-draft-hf`, projector URL `-mmu`/`--mmproj-url` are missing. Probe `max_tokens: 256` false-fails thinking models; dict-valued `arguments` raises TypeError.

Spellings from `llama-server --help`, build b12190 (no vocoder flags in this build). Also forbid `-hft`/`--hf-token` (a secret in a recipe file) and `--api-prefix` (moves `/health`, so llm-host would see the server as foreign).

- [ ] Failing tests (`host/tests/test_recipes.py`, `host/tests/test_probe.py`, fake server):
  - `test_download_and_token_flags_are_forbidden`: each of `-hfd -hfrd --spec-draft-hf -mmu --mmproj-url -hft --hf-token --api-prefix` rejected, also in `=value` form.
  - `test_probe_allows_long_thinking` (`FAKE_THINK_TOKENS=600`: the fake returns no tool call when `max_tokens` < 600+50) → PASS.
  - `test_probe_accepts_object_arguments` (`FAKE_ARGS_AS_OBJECT=1`) → PASS with the arguments shown.
- [ ] Implement: extend `FORBIDDEN_ARGS`; probe tool-call `max_tokens` 2048; `arguments` accepted as a dict or a JSON string.
- [ ] Commit `fix(host): forbid more download/token flags; probe tolerates thinking and object arguments`.

### Task 2: hosts dropped on load are backed up and announced

Finding: entries dropped by `validateHost` on load are erased at the next save with no backup.

- [ ] Failing tests (`test/core/hosts_test.dart`): `load backs up a file whose entries were dropped` (one invalid + one valid entry → `hosts.json.dropped-<ms>` holds the original bytes, `lastLoadDropped == 1`, `recoveredNotice` mentions the count and the backup); a clean file makes no backup.
- [ ] Implement in `HostRegistry.load` and `recoveredNotice`.
- [ ] Commit `fix(core): keep a backup when invalid hosts are dropped`.

### Task 3: OpenCode environment overrides

Finding: `OPENCODE_CONFIG_CONTENT` / `OPENCODE_CONFIG_DIR` from the parent environment merge over the local OpenCode config.

- [ ] Failing test (`test/core/local_launch_test.dart`): both absent from every local spec when set in the parent; kept in native/ALCF specs.
- [ ] Implement: add them to `kLocalStrippedEnvKeys`.
- [ ] Commit `fix(core): local OpenCode ignores config injected from the parent environment`.

### Task 4: Windows webread calls (untested, read-checked)

Findings: `webread.cmd` runs `python` again when webread itself fails (`a && b || c`); the Pi extension's `cmd /c webread <url>` lets cmd.exe split a URL at `&`.

- [ ] Failing tests (`test/core/local_config_test.dart`): the extension never runs `cmd`; on win32 it finds the `webread` script on PATH and runs it with `py -3` (else `python`), passing the URL as its own argument. `tools/webread.cmd` picks the interpreter with `where` and an `if`, so a failing webread is not run twice (text test on the file).
- [ ] Implement.
- [ ] Commit `fix(windows): webread is run once, and URLs with & reach it whole`.

### Task 5: Close

- [ ] All suites, analyzer, Linux build; reinstall app and llm-host.
- [ ] Ledger, merge `review-minors` into `main`, push `main`.
