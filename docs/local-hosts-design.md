# ai-app — local and remote model hosts: design

Date: 2026-11-11. Status: awaiting approval. Extends `alcfai-app`
(`github.com/corentinravoux/alcfai-app`, design of 2026-10-27 in
`../2026-10-27_alcfai-app-plan/design.md`). Plan: [plan.md](plan.md).

## Intent

The app already opens coding agents in terminal tabs against the ALCF
inference service, each with a sandboxed config. This adds a second kind of
backend: **model hosts the user owns** — the personal PC today
(`corentin-MS-7B86`, RTX 3060 12 GB), a mini AI PC later. The same agents run
against a llama-server on such a host, whether the user sits at that machine or
at the laptop, at home, at the lab or travelling.

## Why

- The user wants a proper wrapper around the local model, not hand-edited
  configs and a server started from a shell.
- A local 35B model in a 32–64K window is far more sensitive to the harness and
  its settings than ALCF's 120B models (local-llm skill, `harnesses.md`). The
  configs must declare the real window and output cap every time, so they are
  generated from the running server, never typed.
- The ALCF incident (one `alcf-ai agent configure` rerouted both Claude
  accounts) must not repeat with a local model: nothing local is ever written
  to `~/.claude*`.

## What the user said (decisions)

| topic | decision |
|---|---|
| Rename | The app is no longer ALCF-only; rename it. User proposed `ai-app`. |
| Where it runs | Both: directly on the PC, and from the laptop controlling a PC model over the network. |
| From where | Home, lab and travelling. A mini AI PC will join later; control it from everywhere. |
| Power | Hosts are assumed switched on. No remote wake-up for now. |
| Whose files | Almost always the laptop's project folders: agents run on the machine where the app runs; only the model is remote. |
| Feel | Remote control should work like the ALCF flow: pick a host, pick a model, see its status. |
| Use | Mainly coding; sometimes offline; reading web pages. |
| Agents | Pi, OpenCode, Claude Code. |

## Architecture

```
 laptop (or the PC itself)                         model host (PC, later mini PC)
┌──────────────────────────────┐                  ┌───────────────────────────────┐
│ ai-app                       │   ssh (control)  │ llm-host  start/stop/status   │
│  ├ tab: Pi        ─┐         │ ───────────────► │   └ llama-server 127.0.0.1    │
│  ├ tab: OpenCode  ─┼► 127.0.0.1:19931 ══ssh -L══════► :9931  (one recipe)       │
│  └ tab: Claude    ─┘         │   over Tailscale │ recipes: ~/.config/llm-host/  │
│ project folders (laptop)     │                  │ models:  ~/Software/models/   │
└──────────────────────────────┘                  └───────────────────────────────┘
```

1. **Agents run where the app runs**, in the user's project folder there. Agent
   configs always point at a `127.0.0.1` address; agents never learn about
   networks.
2. **A host is one entry** in `~/.config/ai-app/hosts.json`: id, label, kind
   (`local` or `ssh`), SSH target, server port, local forward port. Adding the
   mini PC is one entry plus the host-side install, no new code.
3. **`llm-host`** is a single stdlib-Python script installed on every model
   host. It owns the llama-server process: `list`, `status`, `start <recipe>`,
   `stop`, `log`, all with JSON output. The app calls it directly on the local
   host and through `ssh` on a remote one. It is usable from a shell without
   the app.
4. **Recipes, not a flag form.** One tested launch recipe per model and context
   size, a TOML file on the host (`~/.config/llm-host/recipes/<name>.toml`),
   because on 12 GB VRAM the flags (`--n-cpu-moe`, KV quantisation, thinking
   off) decide whether tool calls work at all. Recipes are machine-specific and
   are written from measurements (local-llm workflow), not guessed.
5. **Network: Tailscale + SSH.** llama-server always binds `127.0.0.1`. The
   laptop reaches a host by its Tailscale name; the app keeps one `ssh -N -L`
   forward per remote host and runs `llm-host` over `ssh`. No open port, no API
   key, encryption included, works behind the home router and lab firewalls.
6. **Configs are generated at tab launch** from the host's live status (alias,
   real per-slot context from `/props`, output cap, vision), into a per-host,
   per-agent sandbox `~/.local/share/ai-app/local/<host>/<agent>/`.

| agent | sandbox override | what the app writes |
|---|---|---|
| Pi | `PI_CODING_AGENT_DIR` | `models.json` (provider, `contextWindow`, `maxTokens`), `settings.json` (compaction), `extensions/web_read.ts` |
| OpenCode | `OPENCODE_CONFIG` | `opencode.jsonc` (provider, `limit`, compaction, `tool_output` caps) |
| Claude Code | `CLAUDE_CONFIG_DIR` + env only | nothing in `settings.json`; `ANTHROPIC_BASE_URL` etc. are set in the tab's environment; launched `--bare --tools Bash,Read,Edit` |

7. **Web reading:** one small tool, `webread <url>`, that fetches a page and
   prints capped plain text. Pi gets it as a registered tool, Claude Code
   through Bash plus one appended prompt line; OpenCode keeps its built-in
   fetch, capped by `tool_output`.

## Goals

- Sidebar groups: ALCF, one group per model host, Native. Each host shows
  reachable / stopped / loading / ready, the loaded model, its context size and
  VRAM use, with Start, Switch model, Stop and Log.
- Open Pi, OpenCode or Claude Code against any host in two clicks; the config is
  always consistent with what the server actually runs.
- Same app and same behaviour on the PC (host `local`) and on the laptop (host
  `pc` over SSH).
- A dropped link shows as "host unreachable" within seconds and recovers by
  itself; an agent sees a refused connection, not a hang.
- A written checklist for adding a new model host (the mini PC).

## Non-goals

- No remote wake-up, no model downloads from the app (downloads stay on explicit
  request), no flag-editing form, no router mode.
- No agent running on the host with the laptop as a window.
- No Codex or Qwen Code against local hosts in this round (Codex needs the
  Responses API; Qwen Code has no verified config-dir override). No web search.
- Local Claude Code does not share `CLAUDE.md`, skills, plugins or memory: the
  window is too small.
- No move of the ALCF sandbox: `~/.local/share/alcfai/home` stays, so
  `install.sh --alcf` and the `alcf-ai` shell guard are untouched.

## Anti-goals (a failure even if it "works")

- Any byte changed in `~/.claude*`, `claude_config/claude/`, `~/.pi`,
  `~/.config/opencode`, `~/.codex` by the app.
- A local tab that silently talks to Anthropic or ALCF, or the reverse.
- llama-server listening on anything but `127.0.0.1`.
- An agent config that declares a context window larger than the server's.
- The app killing a llama-server it did not start.

## Constraints

- PC: Ubuntu 26.04, `/` is 19 GB (install under `$HOME`), 16 GB RAM, llama.cpp
  b12190 at `~/Software/llama.cpp`, models in `~/Software/models`, one Python
  env (`~/Software/claude_env/.venv`); `llm-host` therefore uses the standard
  library only. Not installed yet on the PC: Node.js, Pi, OpenCode, Flutter,
  openssh-server, Tailscale.
- Flutter 3.47.7 / Dart 3.13.5, Linux desktop only, existing layout
  (`lib/core`, `lib/ui`, injectable `Runner`).
- Steps needing `sudo` are run by the user.
- Commits are local; the user pushes the app repo.

## Calls made by Claude (check these)

1. **Name `ai-app`** as proposed by the user (Dart package `ai_app`, window
   title "AI App"). `agent-deck` remains my preference for searchability; it is
   a one-task change either way.
2. **Tailscale** for reachability. Fallback if the lab forbids it: a reverse SSH
   tunnel through a machine already reachable; the app only needs an SSH target,
   so nothing in the code depends on Tailscale.
3. **`llm-host` lives in the app repo** (`host/`), stdlib Python, pidfile-based
   (no systemd), recipes in TOML under `~/.config/llm-host/`.
4. **Single-model server per recipe**; switching = stop + start. `--alias` is
   the recipe name, so the agent shows which model it talks to.
5. **Minimum context per agent**: Pi 16 384, OpenCode 24 576, Claude Code
   32 768. Below it the profile is greyed with the reason.
6. **`webread`** as the shared web tool (page text capped at 12 000 characters);
   no search engine.
7. **Agents first tested by hand** (plan Phase 0) before any app code, with the
   findings recorded in `docs/local-wire-notes.md`: the harness configs in the
   local-llm skill are partly inferred from docs.
8. The ALCF sandbox keeps its path; only the app's own names change.

## Risks

- **Speed and window on the PC.** Unmeasured so far. If Qwen3.6-35B-A3B cannot
  hold 32K at a usable speed, Claude Code is out and Pi is the only comfortable
  agent. Phase 0 measures this before anything is built.
- **Web pages plus a shell.** Pi has no permission system; a page can carry
  instructions. Use scratch checkouts for web-heavy sessions.
- **Tailscale needs the internet to connect two devices** that are not on the
  same LAN. "Offline" therefore means working at the host itself.
