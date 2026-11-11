# Local wire notes (plan Task 2)

Measured 2026-11-11 on corentin-MS-7B86, llama.cpp b12190, recipe
`qwen36-35b-64k` (Qwen3.6-35B-A3B UD-IQ4_XS, `-c 65536 -np 1 --n-cpu-moe 20`,
thinking off). Task for every agent, in a scratch git repo: "calc.py has a bug
in add. Fix it, then run `python3 -c 'import calc; print(calc.add(2,3))'` and
report the output." All three fixed it and reported 5.

| agent | version | wall time | first-turn prompt (scaffolding) |
|---|---|---|---|
| Pi | 1.5.2 (`@earendil-works/pi-coding-agent`) | 13 s | ~1,520 tokens |
| OpenCode | 1.19.5 (`opencode-ai`) | 37 s | ~12,800 tokens |
| Claude Code | 2.1.322 (`@anthropic-ai/claude-code`), `--bare --tools Bash,Read,Edit` | 14 s | ~1,240 tokens (corrected 2026-11-11, see below) |

The first request after a model load is slow (Pi's 1,520-token first prefill
took 76 s, 20 tok/s): the mmapped experts are still being read from disk.
Later prefills run at 300–600 tok/s.

## Install (no sudo)

- Node v26.13.0 LTS: official tarball, sha256-checked, in `~/opt/node-v26.13.0-linux-x64`,
  symlink `~/opt/node`. npm global prefix `~/.npm-global` (`~/.npmrc`).
- `npm install -g --ignore-scripts @earendil-works/pi-coding-agent opencode-ai`;
  OpenCode's postinstall (copies the platform binary from its optional
  dependency into `bin/`) was read, then run by hand.
- Claude Code CLI was only present inside the VS Code extension; installed
  `@anthropic-ai/claude-code` into the same prefix.
- `~/.npm-global/bin/{pi,claude}` are `#!/usr/bin/env node` scripts: **`~/opt/node/bin`
  must be on the agents' PATH**, which a desktop launch does not have.

## Pi

- The generic provider in `models.json` works as written in the local-llm skill
  (`api: openai-completions`, `apiKey`, one model with `contextWindow`,
  `maxTokens`, zero `cost`).
- **Default model:** `settings.json` keys `defaultProvider` and `defaultModel`
  (model id). No CLI flag needed.
- Compaction keys: `compaction.enabled`, `reserveTokens`, `keepRecentTokens`
  (docs/settings.md).
- **Without a terminal Pi reads stdin as part of the prompt**: `pi --print`
  from a non-tty shell hangs until stdin closes. Use `< /dev/null` in scripts.
  In the app's PTY this does not arise.
- Extensions: `<agentDir>/extensions/*.ts`, auto-discovered. Shape:

  ```ts
  import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
  import { Type } from "typebox";
  export default function (pi: ExtensionAPI) {
    pi.registerTool({ name, label, description,
      parameters: Type.Object({ url: Type.String({ description }) }),
      async execute(toolCallId, params, signal, onUpdate, ctx) {
        const r = await pi.exec("webread", [params.url], { signal, timeout: 30000 });
        // r.stdout, r.stderr, r.code
        return { content: [{ type: "text", text }], details: {} };
      } });
  }
  ```

## OpenCode

- **The skill's "V2" config (`providers` / `package` / `settings` /
  `capabilities`) is silently dropped by 1.19.5** (`opencode debug config`
  shows no provider). The working form is the v1 `provider` block:

  ```jsonc
  "model": "local/<alias>",
  "provider": { "local": {
    "npm": "@ai-sdk/openai-compatible", "name": "<host label>",
    "options": { "baseURL": "http://127.0.0.1:<port>/v1", "apiKey": "local", "headerTimeout": 600000 },
    "models": { "<alias>": { "name": "<alias>", "tool_call": true,
                             "limit": { "context": <ctx>, "output": <max_output> } } } } },
  "compaction": { "auto": true, "reserved": <tokens>, "keep": { "tokens": <tokens> } },
  "tool_output": { "max_lines": 400, "max_bytes": 16384 }
  ```

  `compaction.buffer` is dropped by 1.19.5; `reserved` is its v1 equivalent
  (`keep.tokens` is translated to `preserve_recent_tokens`).
- Built-in `WebFetch` works with the local model (example.com title, 13 s).
- `opencode run "<msg>"` is the non-interactive mode.

## Claude Code

- The env block of the local-llm skill works as is; no extra `DISABLE_*`
  variable was needed (no HTTP 400). A harmless stderr line
  `[claude-code:unrecognized_model]` appears.
- `--append-system-prompt` is accepted together with `--bare`.
- One slot (`-np 1`) handled it; prefix cache reused between turns.
- In `-p` mode, tools needing permission are denied (no prompt), and the first
  attempt looped on a ~22K-token prompt until the 600 s timeout. Interactive
  use in a terminal asks for permission as usual. For scripted tests use
  `--permission-mode acceptEdits --allowedTools 'Bash(python3:*)'`.
- `~/.claude/settings.json` hash unchanged across all runs.

## Model switch under an open tab

A single-model llama-server answers whatever `model` name it is sent (checked
on `/v1/chat/completions` and `/v1/messages`). A tab therefore keeps working
after a switch, but its config still declares the old window and output cap:
the switch warning stays, and reopening the tab regenerates the config.

## Round 2 measurements (2026-11-11, b12190)

- **Claude Code's real first-turn prompt** (fresh 128K server, `-p "reply
  with the single word: pong"`):
  - `--bare --setting-sources user --tools Bash,Read,Edit`: **1,240 tokens**.
    The 22,400 above came from the run that looped on permission denials
    (many turns), not from one turn.
  - **Full** (no `--bare`; `CLAUDE.md`, `commands/`, `skills/` linked into
    the config folder): **18,503 tokens**, 34 s of prefill on the first
    turn. It fits a 64K window with room to work.
  - Without `--bare`, `ANTHROPIC_API_KEY` alone gives "Not logged in": full
    mode needs `"apiKeyHelper": "echo local"` in the tab's `settings.json`.
  - The 32K minimum for Claude stays: Claude Code does not auto-compact
    below a 100K window (`CLAUDE_CODE_AUTO_COMPACT_WINDOW` is clamped), so a
    small window fills with no way out.
- **Project overrides.** Under `--bare`, a project's
  `.claude/settings.json` `env` still overrides `ANTHROPIC_BASE_URL` and
  the model (the model became "hijacked" and the requests went to the URL
  the project set). `--setting-sources user` stops it (checked live: the
  answer came from the local model). OpenCode merges a project's
  `opencode.json` over `OPENCODE_CONFIG` (its model became `evil/x`);
  `OPENCODE_DISABLE_PROJECT_CONFIG=1` stops it (checked live).
- **Vision**: recipe `qwen36-35b-64k-vision` (`--n-cpu-moe 22` + `mmproj-F16`)
  loads in 149 s, uses 11.7 of 12.3 GB VRAM (0.6 GB free: close the
  browser's GPU-heavy tabs), probe PASS, 29 tok/s, and described a test
  image (red circle, blue square, the text "AI 42") correctly in 3.8 s.
- **Switch race**: AI App's status polling deleted a switching server's
  pidfile once (the new server was then killed). Fixed in llm-host (lock-checked
  cleanup, the start restores its pidfile); live switches 9B → 64K → 128K
  with the app open then succeeded.
