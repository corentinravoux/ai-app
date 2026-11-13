# Local agents round 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** On model hosts, add a full Claude Code profile, a Qwen Code profile, and Brave web search for the local agents (next-steps § D 1, 2, 4).

**Architecture:** Same as local-hosts: profiles from `localProfiles`, config written per tab by `writeLocalConfig` into `local/<host>/<agent>/`, environment built by `buildLocalLaunch`. A new `LocalAgent` value (pi, opencode, claude, claudeFull, qwen) replaces `AgentKind` for local profiles, because two local profiles now share the `claude` executable. Web search is a stdlib script, `tools/websearch`, beside `webread`.

**Spec:** user decisions of 2026-11-13 (next-steps § D): "1) Fourth model yes 2) only qwen code 4) add brave"; measured facts in [local-wire-notes.md](local-wire-notes.md).

## Global Constraints

- Branch `local-agents` from `main`; merge into `main` and push at the end (as before).
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Real configs (`~/.claude*`, `~/.pi`, `~/.config/opencode`, `~/.qwen`, `~/.codex`) are never written; `~/.qwen` joins the guarded roots and the hash guard.
- Projects cannot redirect a local agent: Claude `--setting-sources user`, OpenCode `OPENCODE_DISABLE_PROJECT_CONFIG`, Qwen Code `security.folderTrust.enabled` with a private trusted-folders file.
- Python tests with `/usr/bin/python3`; never touch `~/Software/claude_env`.

## Facts measured on the PC (2026-11-13, Qwen Code 0.27.3)

- Qwen Code reads its whole global config from `QWEN_HOME` (`settings.json`, memories, skills…); nothing is written to `~/.qwen`.
- Working provider block: `modelProviders.openai[{id, name, envKey, baseUrl, generationConfig{contextWindowSize, samplingParams{max_tokens}}}]`, `env{<envKey>: "local"}`, `security.auth.selectedType: "openai"`, `model.name`.
- A project `.qwen/settings.json` redirects Qwen Code; with `security.folderTrust.enabled: true` and `QWEN_CODE_TRUSTED_FOLDERS_PATH` pointing at an empty private file, it is ignored.
- First prompt about 10,400 tokens.
- Full Claude: first prompt 18,503 tokens; needs `apiKeyHelper` in `settings.json` (not `ANTHROPIC_API_KEY`); onboarding state is `hasCompletedOnboarding` in `<config dir>/.claude.json`.

## Review Focus

1. A project folder with `.qwen/settings.json` or `.claude/settings.json`: the local tab still talks to the host.
2. Full Claude's links to `CLAUDE.md`, `commands`, `skills`, `agents`: the app creates links in its own folder, never writes through them, and a missing source is skipped.
3. `websearch` without a key: one clear line saying where to put it, exit 2.
4. Brave API errors (401, 429, network): one line, exit 2; the key never printed.

---

### Task 1: Local agent kinds (refactor)
- `enum LocalAgent { pi, opencode, claude, claudeFull, qwen }` with `exe`, `label` (`Pi`, `OpenCode`, `Claude`, `Claude (full)`, `Qwen Code`), `minCtx` (16384, 24576, 32768, 65536, 24576), `dirName`.
- `Profile.localAgent`; `localProfiles` builds one per host and agent; ids `local-<dirName>-<host>`; existing ids unchanged (`local-pi-…`, `local-opencode-…`, `local-claude-…`).
- `AgentKind` gains `qwen` (`exe: 'qwen'`) for executable lookup; ALCF/native code paths untouched.
- Tests: ids and labels for five agents; readiness uses `minCtx` (Claude full blocked at 32768, shown at 65536).

### Task 2: Full Claude profile
- Config dir `local/<host>/claude-full/`: `settings.json` `{"apiKeyHelper": "echo local"}` (keys the user adds are kept), `.claude.json` with `hasCompletedOnboarding: true` when missing, links `CLAUDE.md`, `commands`, `skills`, `agents` to the user's main Claude folder (first of `claudeDirs`) when present.
- Env: as local Claude but without `ANTHROPIC_API_KEY` and `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT`; args `--setting-sources user --append-system-prompt <web line>` (no `--bare`, no `--tools`).
- Tests: files written, links point at the right sources, missing sources skipped, a symlinked `settings.json` replaced not followed, env and args exact.

### Task 3: Qwen Code profile
- Env `QWEN_HOME=<dir>`, `QWEN_CODE_TRUSTED_FOLDERS_PATH=<dir>/trustedFolders.json`, `LOCAL_API_KEY` set through settings `env`; strip inherited `OPENAI_*`, `QWEN_*`, `GEMINI_*`.
- `settings.json` as measured, with `contextWindowSize = ctx`, `max_tokens = maxOutput`, `context.autoCompactThreshold 0.75`, telemetry and usage statistics off, folder trust on; user-added keys kept.
- `~/.qwen` guarded and hashed.
- Tests: settings content, env exact, inherited OpenAI/Qwen variables dropped, guard paths.

### Task 4: Brave web search
- `tools/websearch QUERY... [--count N=5]`: key from `BRAVE_API_KEY` or `<config home>/ai-app/brave-api-key`; `GET https://api.search.brave.com/res/v1/web/search?q=…&count=N` with `X-Subscription-Token`; prints numbered `title`, `url`, `description`; tags stripped; errors one line, exit 2. Endpoint overridable by `AI_APP_BRAVE_ENDPOINT` (tests).
- Pi extension gains `web_search`; Claude's appended prompt gains `To search the web, run: websearch <query>`; Qwen and OpenCode told through their instructions file where supported, else documented.
- Install scripts install `websearch` (+ `websearch.cmd`) next to `webread`.
- Tests: fake Brave server (results, 401, 429), missing key, key not echoed, count cap.

### Task 5: Close
- README (model hosts table, web search key), next-steps § D updated, ideas linked; review; merge; push; reinstall.
